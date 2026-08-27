// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {FeeBreakdown, FeeKind, PxtFeeEvents, PxtFeeModel, AntiBotSellBlocked, ZeroAddress} from "./PxtFeeModel.sol";
import {IPxtSellControls, PxtSellAccess} from "./PxtSellAccess.sol";
import {ISellAttributor} from "../return-delta/ISellAttributor.sol";

// Fee-on-transfer ERC20. Wallet transfers take 2.7% unless the recipient is FeeExempt
// or NoPenalty. PoolManager *outbound* (buys / LP exits) is fee-free. User→PoolManager is
// fee-free only for attested DEX sells and LP mints, plus FeeCollector/owner seed (PTTB).
// Hook outbound (unfilled exact-in burn refund to the seller) is fee-free (RIFM).
//
// DEX sell settlement (user -> PoolManager) is authenticated by token custody:
// - Sell lock + anti-bot first seller are enforced here.
// - FeeExempt does NOT skip sell lock / anti-bot. Tax / USDC rebate only (via attributor).
// - FeeCollector -> PoolManager is LP settle (seed/recycle), not a user sell.
// - With sellAttributor set (ReturnDelta hook): notifies ISellAttributor for USDC fee
//   attribution / dump-window rebate, and PoolManager→user receipts (FBBP). Dump economics
//   live on the hook, not on-token.
//
// feeCollector and sellAttributor are configured once during bootstrap, verified by
// LockProtocolReturnDelta, then frozen when Ownable is renounced before go-live.
//
// Contract-recipient allowlist is gated by RECIPIENT_APPROVER_ROLE (intended for a
// multisig). Ownable admin setters can be renounced while that role remains on the Safe.
contract Pxt is ERC20, ERC20Permit, Ownable, AccessControl, PxtFeeEvents {
    bytes32 public constant RECIPIENT_APPROVER_ROLE = keccak256("RECIPIENT_APPROVER_ROLE");

    uint8 public constant TOKEN_DECIMALS = 6;

    /// 40.021 trillion whole tokens in base units (10^6 decimals).
    uint256 public constant TOTAL_SUPPLY = 40_021_000_000_000 * 10 ** TOKEN_DECIMALS;

    /// @notice When V4 sells unlock. Set at deploy (immutable).
    uint256 private immutable SELL_UNLOCK_TIMESTAMP;

    address public immutable DONATION_WALLET;
    address public immutable MARKETING_WALLET;

    /// @notice Uniswap v4 PoolManager. Outbound settlement skips the 2.7% fee; inbound
    ///         is fee-free only for attested DEX sells / LP mints (or collector/owner seed).
    address public poolManager;

    /// @notice First post-unlock seller; address(0) disables anti-bot.
    address public antiBotSeller;
    /// @notice True after antiBotSeller completes one post-unlock sell to the PoolManager.
    bool public sellProtectionCleared;

    /// @notice Protocol fee treasury / LP holder (skip transfer tax on its payouts; LP settle).
    address public feeCollector;
    /// @notice Sell attributor for USDC rebate / dump window (ReturnDelta hook).
    ISellAttributor public sellAttributor;

    /// @dev FeeExempt: recipient skips transfer tax; DEX sells get full USDC rebate via attributor.
    /// Does not skip sell lock or anti-bot.
    /// NoPenalty: recipient skips transfer tax; DEX sells always pay base 5.4% USDC (never dump penalty).
    enum WalletStatus {
        Normal,
        FeeExempt,
        NoPenalty
    }

    mapping(address => WalletStatus) public walletStatus;
    mapping(address => bool) public isApprovedContractRecipient;

    event WalletStatusSet(address indexed wallet, WalletStatus status);
    event PoolManagerSet(address indexed poolManager);
    event ApprovedContractRecipientSet(address indexed recipient, bool approved);
    event AntiBotSellerSet(address indexed seller);
    event SellProtectionCleared();
    event FeeCollectorSet(address indexed collector);
    event SellAttributorSet(address indexed attributor);

    error ContractRecipientNotApproved();
    error ProtectedRecipient();
    error InvalidSellUnlock();
    error AntiBotSellerAlreadySet();
    error SellProtectionAlreadyCleared();
    error FeeCollectorAlreadySet();
    error SellAttributorAlreadySet();

    constructor(address admin, address donation, address marketing, uint256 sellUnlockTimestamp_)
        ERC20("Phoenix Token", "PXT")
        ERC20Permit("Phoenix Token")
        Ownable(admin)
    {
        if (donation == address(0) || marketing == address(0)) {
            revert ZeroAddress();
        }
        if (sellUnlockTimestamp_ <= block.timestamp) revert InvalidSellUnlock();

        SELL_UNLOCK_TIMESTAMP = sellUnlockTimestamp_;

        DONATION_WALLET = donation;
        MARKETING_WALLET = marketing;

        walletStatus[admin] = WalletStatus.FeeExempt;
        walletStatus[donation] = WalletStatus.FeeExempt;
        walletStatus[marketing] = WalletStatus.FeeExempt;

        _setApprovedContractRecipient(donation, true);
        _setApprovedContractRecipient(marketing, true);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RECIPIENT_APPROVER_ROLE, admin);

        _mint(admin, TOTAL_SUPPLY);
    }

    function decimals() public pure override returns (uint8) {
        return TOKEN_DECIMALS;
    }

    function sellUnlockTimestamp() public view returns (uint256) {
        return SELL_UNLOCK_TIMESTAMP;
    }

    function setPoolManager(address poolManager_) external onlyOwner {
        if (poolManager_ == address(0)) revert ZeroAddress();
        if (poolManager != address(0)) {
            _setApprovedContractRecipient(poolManager, false);
        }
        poolManager = poolManager_;
        _setApprovedContractRecipient(poolManager_, true);
        emit PoolManagerSet(poolManager_);
    }

    /// @notice Designate the first post-unlock seller (e.g. `PhoenixAntiBotOpenSell`). One-shot; cannot
    ///         reconfigure after set or after public trading has opened via `clearSellProtection`.
    /// @dev Zero is rejected; public sells open via `clearSellProtection`, not by clearing the seller.
    function setAntiBotSeller(address seller) external onlyOwner {
        if (seller == address(0)) revert ZeroAddress();
        if (sellProtectionCleared) revert SellProtectionAlreadyCleared();
        if (antiBotSeller != address(0)) revert AntiBotSellerAlreadySet();
        antiBotSeller = seller;
        emit AntiBotSellerSet(seller);
    }

    /// @notice Opens *public* pool sells after unlock.
    /// @dev Required before any hook sell (ERC-20 or ERC-6909) while anti-bot is armed: hooks call
    /// `enforceTradingOpen`. Prefer `PhoenixAntiBotOpenSell` as `antiBotSeller` so clear + first
    /// sell are atomic via `openWithExactInSell` (if the sell reverts, this clear rolls back).
    function clearSellProtection() external {
        PxtSellAccess.enforceSellUnlocked(IPxtSellControls(address(this)));
        if (antiBotSeller == address(0) || sellProtectionCleared) return;
        if (msg.sender != antiBotSeller) revert AntiBotSellBlocked();
        sellProtectionCleared = true;
        emit SellProtectionCleared();
    }

    /// @notice Protocol fee treasury / LP holder. One-shot at bootstrap; Ownable is renounced
    ///         in `LockProtocolReturnDelta` before public trading — this address cannot be changed afterward.
    function setFeeCollector(address collector_) external onlyOwner {
        if (collector_ == address(0)) revert ZeroAddress();
        if (feeCollector != address(0)) revert FeeCollectorAlreadySet();
        feeCollector = collector_;
        _setApprovedContractRecipient(collector_, true);
        emit FeeCollectorSet(collector_);
    }

    /// @notice Sell attributor (ReturnDelta hook) for USDC attribution / dump window. One-shot at bootstrap;
    ///         renounce Ownable before go-live so a mis-set attributor cannot brick pool sells.
    function setSellAttributor(ISellAttributor attributor_) external onlyOwner {
        if (address(attributor_) == address(0)) revert ZeroAddress();
        if (address(sellAttributor) != address(0)) revert SellAttributorAlreadySet();
        sellAttributor = attributor_;
        _setApprovedContractRecipient(address(attributor_), true);
        emit SellAttributorSet(address(attributor_));
    }

    /// @notice Allow/deny PXT transfers to a contract. Intended for a multisig with
    /// `RECIPIENT_APPROVER_ROLE` after Ownable is renounced.
    /// @dev PoolManager, FeeCollector, and sell attributor cannot be revoked (DEX sell / LP settle).
    function setApprovedContractRecipient(address recipient, bool approved) external onlyRole(RECIPIENT_APPROVER_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        if (!approved && _isProtectedRecipient(recipient)) revert ProtectedRecipient();
        _setApprovedContractRecipient(recipient, approved);
    }

    function setWalletStatus(address wallet, WalletStatus status) external onlyOwner {
        walletStatus[wallet] = status;
        emit WalletStatusSet(wallet, status);
    }

    function quoteTransfer(address from, address to, uint256 amount)
        external
        view
        returns (FeeBreakdown memory breakdown)
    {
        _enforceContractRecipient(from, to);
        return _quoteTransfer(from, to, amount);
    }

    function burnBalance(uint256 amount) external {
        _update(msg.sender, address(0), amount);
    }

    function _setApprovedContractRecipient(address recipient, bool approved) internal {
        isApprovedContractRecipient[recipient] = approved;
        emit ApprovedContractRecipientSet(recipient, approved);
    }

    /// @dev Settlement / protocol contracts that must remain valid transfer destinations.
    function _isProtectedRecipient(address recipient) internal view returns (bool) {
        if (poolManager != address(0) && recipient == poolManager) return true;
        if (feeCollector != address(0) && recipient == feeCollector) return true;
        if (address(sellAttributor) != address(0) && recipient == address(sellAttributor)) return true;
        return false;
    }

    /// @dev EOAs have no code. EIP-7702 delegated accounts carry 23-byte designation bytecode
    ///      indistinguishable from a deployed contract with the same bytes (CCIB); they are not
    ///      treated as wallets here. PoolManager→user payouts skip the allowlist separately.
    function _isWallet(address account) internal view returns (bool) {
        return account.code.length == 0;
    }

    function _enforceContractRecipient(address from, address to) internal view {
        if (poolManager != address(0) && from == poolManager) return;
        // One-shot seed LP may return unused tokens to FeeCollector's owner (pre-renounce deployer).
        if (feeCollector != address(0) && from == feeCollector) {
            address collectorOwner = Ownable(feeCollector).owner();
            if (collectorOwner != address(0) && to == collectorOwner) return;
        }
        // DEX sells / LP settle / attributor always allowed regardless of allowlist bit.
        if (_isProtectedRecipient(to)) return;
        if (_isWallet(to)) return;
        if (isApprovedContractRecipient[to]) return;
        revert ContractRecipientNotApproved();
    }

    function _enforceSellAccess(address seller) internal view {
        PxtSellAccess.enforceSellAccess(IPxtSellControls(address(this)), seller);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        _enforceContractRecipient(from, to);

        // DEX sell / LP settle: authentic sender = `from`. Naked hops pay the 2.7% tax (PTTB).
        if (poolManager != address(0) && to == poolManager && from != poolManager) {
            // LP settle (not a user sell): FeeCollector anytime (seed/recycle); Ownable admin only
            // before sell unlock so deploy can seed then renounce. After renounce owner==0.
            bool collectorSettle = feeCollector != address(0) && from == feeCollector;
            bool ownerSeedBeforeUnlock = from == owner() && block.timestamp < SELL_UNLOCK_TIMESTAMP;
            bool attributorSettle = address(sellAttributor) != address(0) && from == address(sellAttributor);
            if (collectorSettle || ownerSeedBeforeUnlock || attributorSettle) {
                if (address(sellAttributor) != address(0)) {
                    sellAttributor.consumeLpInbound(amount);
                }
                super._update(from, to, amount);
                return;
            }

            if (address(sellAttributor) != address(0)) {
                uint256 pendingSell = sellAttributor.pendingDexSellAmount();
                if (pendingSell != 0) {
                    // Real DEX sell, or a mismatched settle that must revert in attributeSell.
                    _enforceSellAccess(from);
                    super._update(from, to, amount);
                    _onDexSell(from, amount);
                    return;
                }
                if (sellAttributor.consumeLpInbound(amount)) {
                    super._update(from, to, amount);
                    return;
                }
                // Fall through: 2.7% wallet tax.
            } else {
                _enforceSellAccess(from);
                super._update(from, to, amount);
                _onDexSell(from, amount);
                return;
            }
        }

        FeeBreakdown memory fee = _quoteTransfer(from, to, amount);

        if (fee.totalFee == 0) {
            super._update(from, to, amount);
            if (
                poolManager != address(0) && from == poolManager && address(sellAttributor) != address(0)
                    && to != feeCollector
            ) {
                sellAttributor.creditFromPoolManager(to, amount);
            }
            return;
        }

        if (fee.donation > 0) super._update(from, DONATION_WALLET, fee.donation);
        if (fee.marketing > 0) super._update(from, MARKETING_WALLET, fee.marketing);
        super._update(from, to, fee.net);

        emit FeeCharged(from, to, fee.kind, fee.feeBps, fee.totalFee);
    }

    /// @dev Anti-bot clear + optional sell attribution (USDC dump window on the hook).
    function _onDexSell(address seller, uint256 amount) internal {
        if (
            antiBotSeller != address(0) && !sellProtectionCleared && seller == antiBotSeller
                && block.timestamp >= SELL_UNLOCK_TIMESTAMP
        ) {
            sellProtectionCleared = true;
            emit SellProtectionCleared();
        }

        if (address(sellAttributor) != address(0)) {
            sellAttributor.attributeSell(seller, amount);
        }
    }

    function _quoteTransfer(address from, address to, uint256 amount)
        internal
        view
        returns (FeeBreakdown memory breakdown)
    {
        if (poolManager != address(0) && from == poolManager) {
            return PxtFeeModel.noFee(amount);
        }

        // Hook → seller refund of unfilled exact-in burn (RIFM); also hook → PoolManager.
        if (address(sellAttributor) != address(0) && from == address(sellAttributor)) {
            return PxtFeeModel.noFee(amount);
        }

        if (walletStatus[to] == WalletStatus.FeeExempt || walletStatus[to] == WalletStatus.NoPenalty) {
            return PxtFeeModel.noFee(amount);
        }

        // Protocol collector payouts must not pay the 2.7% transfer tax.
        if (feeCollector != address(0) && from == feeCollector) {
            return PxtFeeModel.noFee(amount);
        }

        breakdown.kind = FeeKind.Transfer;
        breakdown.feeBps = PxtFeeModel.TRANSFER_FEE_BPS;
        (breakdown.donation, breakdown.marketing) = PxtFeeModel.splitBuy(amount);
        breakdown.totalFee = breakdown.donation + breakdown.marketing;
        breakdown.net = amount - breakdown.totalFee;
    }
}
