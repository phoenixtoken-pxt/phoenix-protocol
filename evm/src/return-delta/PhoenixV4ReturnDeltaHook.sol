// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {Pxt} from "../core/Pxt.sol";
import {IPxtSellControls, PxtSellAccess} from "../core/PxtSellAccess.sol";
import {PhoenixFeeCollector} from "../fee/PhoenixFeeCollector.sol";
import {ISellAttributor} from "./ISellAttributor.sol";
import {FeeKind, PxtFeeEvents, PxtFeeModel, ZeroAddress} from "../core/PxtFeeModel.sol";

// Uniswap v4 return-delta hook for the official PXT/USDC pool.
//
// Overview
// Fees are taken by adjusting swap deltas (not via the pool's LP fee). Buy, sell, and dump-penalty
// legs are skimmed in USDC; sells also burn a fixed 1.85% of PXT input. Exact-in fees true-up
// to the filled amount; exact-out fees are grossed up so published bps apply to total flow (RIFM).
// Exact-in specified leftover cannot be cut in afterSwap (v4 specified delta is frozen); sell PXT
// excess is refunded to the seller in `attributeSell`. Skimmed USDC is forwarded to
// PhoenixFeeCollector for deferred `collect` / cash `executeBuyback`.
// Every official-pool swap (including FeeCollector buybacks) records spot for the previous-block
// buyback price reference. FeeCollector buybacks skip the buy skim (`sender == feeCollector`)
// so recycled PXT is not taxed twice.
//
// Trading gate
// Swaps require sell unlock + anti-bot clear (`PhoenixAntiBotOpenSell` after unlock).
// Liquidity: only FeeCollector may add LP while sells are locked (RAAAU); permissionless after unlock.
// User→PoolManager is fee-free only for attested DEX sells and LP mints (PTTB).
//
// Dump window
// Large sells take a pessimistic USDC skim up front. The authentic seller reclaiming via
// `Pxt.attributeSell` gets a rebate to the fair fee; unclaimed skims finalize as orphan fees.
// Same-tx PoolManager receipts (flash take) are excluded from the 10% denominator (FBBP).
// An open window's snapshot ratchets down if holdings drop.
//
// Same-tx safety
// While an ERC-20 sell skim is pending in transient storage, further swaps are blocked and
// `finalizeOrphanedSell` is refused during unlock so a multi-swap router cannot deny the rebate.
// `attributeSell` also requires the swap locker to still owe at least the transferred PXT (MDSS):
// a 6909 burn that already cleared that debt cannot be followed by a matching deposit rebate.
contract PhoenixV4ReturnDeltaHook is BaseHook, Ownable, PxtFeeEvents, ISellAttributor {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    struct SellWindow {
        uint64 windowStart;
        uint256 soldInWindow;
        uint256 balanceAtWindowStart;
    }

    Pxt public immutable pxt;
    Currency public immutable pxtCurrency;

    PhoenixFeeCollector public feeCollector;

    PoolId public officialPoolId;
    bool public officialPoolSet;

    mapping(address => SellWindow) public sellWindows;

    // Transient pending sell (same-tx ERC-20 attributeSell) via EIP-1153.
    bytes32 private constant _T_PXT_IN = keccak256("phoenix.rd.pending.pxtIn");
    bytes32 private constant _T_USDC_OUT = keccak256("phoenix.rd.pending.usdcOut");
    bytes32 private constant _T_USDC_SKIM = keccak256("phoenix.rd.pending.usdcSkim");
    bytes32 private constant _T_QUOTE = keccak256("phoenix.rd.pending.quote");
    /// @dev keccak256(abi.encode(_T_PM_IN, account)) → PXT received from PoolManager this tx.
    bytes32 private constant _T_PM_IN = keccak256("phoenix.rd.pmIn");
    /// @dev Official-pool LP mint: PXT the locker still owes PoolManager this tx (PTTB).
    bytes32 private constant _T_LP_IN = keccak256("phoenix.rd.lpIn");
    /// @dev Exact-in specified take; after a sell, leftover PXT to refund in attributeSell.
    bytes32 private constant _T_SPECIFIED_TAKE = keccak256("phoenix.rd.specifiedTake");
    /// @dev 1 if pending USDC notional is exact-out net (gross-up in attributeSell).
    bytes32 private constant _T_FEE_ON_NET = keccak256("phoenix.rd.feeOnNet");
    /// @dev Swap `sender` (locker) that still owes PXT until ERC-20 / 6909 settle (MDSS).
    bytes32 private constant _T_DEBTOR = keccak256("phoenix.rd.pending.debtor");

    /// @notice Persistent skim awaiting attributeSell or finalizeOrphanedSell (ERC-6909).
    struct OrphanSkim {
        uint128 pxtIn;
        uint128 usdcOut;
        uint128 usdcSkim;
        address quote;
        bool feeOnNet;
    }

    OrphanSkim public orphanSkim;

    event OfficialPoolSet(PoolId indexed poolId);
    event FeeCollectorSet(address indexed collector);
    event HookFeeCharged(address indexed trader, FeeKind kind, uint256 feeBps, uint256 feeAmount);
    event SellAttributed(address indexed seller, uint256 pxtAmount, uint256 fairFeeBps, uint256 usdcRefunded);
    event OrphanSellFinalized(uint256 usdcSkim, uint256 donation, uint256 marketing, uint256 buyback);

    error InvalidPool();
    error ZeroAmount();
    error OfficialPoolAlreadySet();
    error OfficialPoolNotSet();
    error OnlyPxt();
    error PendingSellMismatch();
    /// @dev Transient sell skim still awaiting attributeSell (or unlock still open after a claim sell).
    error PendingSellOpen();
    /// @dev ERC-20 attributeSell after the locker's PXT swap debt was already paid (e.g. 6909 burn).
    error SellAlreadySettled();
    error FeeCollectorNotSet();
    error LiquidityNotAllowed();

    constructor(IPoolManager manager_, Pxt pxt_, address, address admin) BaseHook(manager_) Ownable(admin) {
        if (address(pxt_) == address(0) || admin == address(0)) revert ZeroAddress();
        pxt = pxt_;
        pxtCurrency = Currency.wrap(address(pxt_));
    }

    function setFeeCollector(PhoenixFeeCollector collector_) external onlyOwner {
        if (address(collector_) == address(0)) revert ZeroAddress();
        feeCollector = collector_;
        emit FeeCollectorSet(address(collector_));
    }

    function setOfficialPool(PoolKey calldata key) external onlyOwner {
        if (officialPoolSet) revert OfficialPoolAlreadySet();
        if (!_poolContainsPxt(key)) revert InvalidPool();
        officialPoolId = key.toId();
        officialPoolSet = true;
        emit OfficialPoolSet(officialPoolId);
    }

    function sellProtectionCleared() external view returns (bool) {
        return pxt.sellProtectionCleared();
    }

    function antiBotSeller() external view returns (address) {
        return pxt.antiBotSeller();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function flags() public pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    /// @dev During sell lock only FeeCollector may add LP (calls modifyLiquidity itself — RAAAU).
    ///      After unlock, anyone may mint via shared routers.
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        _enforceOfficialPool(key);
        if (params.liquidityDelta > 0 && block.timestamp < pxt.sellUnlockTimestamp()) {
            if (address(feeCollector) == address(0) || sender != address(feeCollector)) {
                revert LiquidityNotAllowed();
            }
        }
        return this.beforeAddLiquidity.selector;
    }

    /// @dev Reserve the PXT the locker will settle so a same-tx hop cannot ride the LP path (PTTB).
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _enforceOfficialPool(key);
        int256 pxtDelta = _pxtIsCurrency0(key) ? int256(delta.amount0()) : int256(delta.amount1());
        if (pxtDelta < 0) {
            _tstore(_T_LP_IN, _tload(_T_LP_IN) + uint256(-pxtDelta));
        }
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _enforceOfficialPool(key);
        // Do not start another swap while a same-tx sell skim awaits attributeSell.
        if (_tload(_T_PXT_IN) != 0) revert PendingSellOpen();
        // Cross-tx ERC-6909 orphan (transient cleared at prior tx end) — finalize at penalty.
        if (orphanSkim.usdcSkim > 0) {
            finalizeOrphanedSell();
        }
        (bool isBuy, bool isSell) = _classifySwap(key, params);

        if (isSell) return _beforeSell(key, params);
        if (isBuy) return _beforeBuy(sender, key, params);
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _enforceOfficialPool(key);
        _noteOfficialSpot();
        (bool isBuy, bool isSell) = _classifySwap(key, params);

        if (isSell) return _afterSell(sender, key, params, delta);
        if (isBuy) return _afterBuy(sender, key, params, delta);
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @dev Record post-swap spot on the collector (including protocol buyback; must run before
    ///      `_afterBuy` early-returns when `sender == feeCollector`).
    function _noteOfficialSpot() internal {
        if (address(feeCollector) == address(0)) return;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(officialPoolId);
        if (sqrtPriceX96 != 0) feeCollector.noteOfficialSpot(sqrtPriceX96);
    }

    /// @inheritdoc ISellAttributor
    function creditFromPoolManager(address account, uint256 amount) external {
        if (msg.sender != address(pxt)) revert OnlyPxt();
        if (account == address(0) || amount == 0) return;
        if (address(feeCollector) != address(0) && account == address(feeCollector)) return;
        bytes32 slot = _pmInSlot(account);
        _tstore(slot, _tload(slot) + amount);
    }

    /// @inheritdoc ISellAttributor
    function pendingDexSellAmount() external view returns (uint256) {
        return _tload(_T_PXT_IN);
    }

    /// @inheritdoc ISellAttributor
    function consumeLpInbound(uint256 amount) external returns (bool) {
        if (msg.sender != address(pxt)) revert OnlyPxt();
        if (amount == 0) return false;
        uint256 left = _tload(_T_LP_IN);
        if (left < amount) return false;
        _tstore(_T_LP_IN, left - amount);
        return true;
    }

    /// @inheritdoc ISellAttributor
    function attributeSell(address seller, uint256 pxtAmount) external {
        if (msg.sender != address(pxt)) revert OnlyPxt();
        uint256 pendingPxt = _tload(_T_PXT_IN);
        // LP / non-swap settlements also hit PoolManager; ignore when no pending swap skim.
        if (pendingPxt == 0) return;
        if (pxtAmount != pendingPxt) revert PendingSellMismatch();

        // Rebate only while this transfer still pays the swap debt. A 6909 burn zeros the
        // locker's PXT delta first; a later matching deposit must not take the dump-tax refund.
        address debtor = address(uint160(_tload(_T_DEBTOR)));
        int256 pxtDebt = poolManager.currencyDelta(debtor, pxtCurrency);
        if (debtor == address(0) || pxtDebt >= 0 || SignedMath.abs(pxtDebt) < pxtAmount) {
            revert SellAlreadySettled();
        }

        uint256 usdcOut = _tload(_T_USDC_OUT);
        uint256 skimmed = _tload(_T_USDC_SKIM);
        address quoteAddr = address(uint160(_tload(_T_QUOTE)));
        bool feeOnNet = _tload(_T_FEE_ON_NET) != 0;
        uint256 pxtRefund = _tload(_T_SPECIFIED_TAKE);

        _clearPendingSkim();

        // Exact-in specified take is the request slice; refund unfilled burn after we know the seller.
        uint256 sold = pxtAmount;
        if (pxtRefund > sold) pxtRefund = sold;
        sold -= pxtRefund;

        uint256 balanceBefore = _effectiveSellBalance(seller, pxtAmount);
        if (pxtRefund > 0) IERC20(address(pxt)).safeTransfer(seller, pxtRefund);

        uint256 fairBps = _fairSellFeeBps(seller, sold, balanceBefore);
        _applySellWindow(seller, sold, balanceBefore);

        uint256 refund;
        if (fairBps == 0) {
            refund = skimmed;
        } else if (fairBps == PxtFeeModel.SELL_FEE_BPS && usdcOut > 0) {
            (uint256 dPen, uint256 mPen, uint256 bPen) = _sellUsdcSplit(PxtFeeModel.PENALTY_FEE_BPS, usdcOut, feeOnNet);
            (uint256 dSell, uint256 mSell, uint256 bSell) = _sellUsdcSplit(PxtFeeModel.SELL_FEE_BPS, usdcOut, feeOnNet);
            uint256 fairSkim = dSell + mSell + bSell;
            uint256 penSkim = dPen + mPen + bPen;
            if (penSkim > fairSkim) refund = penSkim - fairSkim;
            if (refund > skimmed) refund = skimmed;
        }

        if (refund > 0 && quoteAddr != address(0)) {
            IERC20(quoteAddr).safeTransfer(seller, refund);
        }

        uint256 keep = skimmed - refund;
        if (keep > 0 && quoteAddr != address(0)) {
            uint256 feeBps = fairBps == 0 ? PxtFeeModel.SELL_FEE_BPS : fairBps;
            (uint256 donation, uint256 marketing, uint256 buyback) = _sellUsdcSplit(feeBps, usdcOut, feeOnNet);
            uint256 target = donation + marketing + buyback;
            // Rounding: distribute `keep` (may be 1 wei off vs target).
            if (target > 0 && keep != target) {
                donation = (keep * donation) / target;
                marketing = (keep * marketing) / target;
                buyback = keep - donation - marketing;
            } else if (target == 0) {
                buyback = keep;
            }
            FeeKind kind = fairBps == PxtFeeModel.PENALTY_FEE_BPS ? FeeKind.Penalty : FeeKind.Sell;
            _accrueUsdc(Currency.wrap(quoteAddr), kind, donation, marketing, buyback);
        }

        emit SellAttributed(seller, sold, fairBps, refund);
    }

    /// @notice Accrue orphaned sell skim at penalty rates when ERC-20 attributeSell never ran (ERC-6909).
    /// @dev Safe vs collect/buyback: USDC stays on the hook until this or attributeSell finalizes.
    /// While PoolManager is unlocked and transient pending is set, refuse finalize so a router
    /// cannot deny an in-flight ERC-20 rebate. After unlock ends, finalize is allowed
    /// even if transient is still set (same-tx claim settle left no attributeSell).
    function finalizeOrphanedSell() public {
        if (poolManager.isUnlocked() && _tload(_T_PXT_IN) != 0) revert PendingSellOpen();

        OrphanSkim memory o = orphanSkim;
        if (o.usdcSkim == 0) return;

        _clearPendingSkim();

        address quoteAddr = o.quote;
        uint256 skimmed = o.usdcSkim;
        uint256 usdcOut = o.usdcOut;
        bool feeOnNet = o.feeOnNet;
        if (skimmed == 0 || quoteAddr == address(0)) return;

        (uint256 donation, uint256 marketing, uint256 buyback) =
            _sellUsdcSplit(PxtFeeModel.PENALTY_FEE_BPS, usdcOut, feeOnNet);
        uint256 target = donation + marketing + buyback;
        if (target > 0 && skimmed != target) {
            donation = (skimmed * donation) / target;
            marketing = (skimmed * marketing) / target;
            buyback = skimmed - donation - marketing;
        } else if (target == 0) {
            buyback = skimmed;
        }

        _accrueUsdc(Currency.wrap(quoteAddr), FeeKind.Penalty, donation, marketing, buyback);
        emit OrphanSellFinalized(skimmed, donation, marketing, buyback);
    }

    function _beforeSell(PoolKey calldata key, SwapParams calldata params)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Time unlock + anti-bot cleared: blocks ERC-6909 before clearSellProtection.
        PxtSellAccess.enforceTradingOpen(IPxtSellControls(address(pxt)));

        // Exact-in: hold 1.85% of requested PXT; burn the fill in afterSwap (RIFM).
        if (_pxtIsSpecified(key, params)) {
            uint256 pxtAmount = SignedMath.abs(params.amountSpecified);
            if (pxtAmount == 0) revert ZeroAmount();
            uint256 burnAmount = PxtFeeModel.splitSellBurn(PxtFeeModel.SELL_FEE_BPS, pxtAmount);
            if (burnAmount == 0) {
                return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
            }
            poolManager.take(pxtCurrency, address(this), burnAmount);
            _tstore(_T_SPECIFIED_TAKE, burnAmount);
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(burnAmount.toInt128(), 0), 0);
        }

        // Exact-out: pessimistic USDC skim from specified *net* at penalty rates, grossed up.
        uint256 usdcAmount = SignedMath.abs(params.amountSpecified);
        if (usdcAmount == 0) revert ZeroAmount();
        (uint256 donation, uint256 marketing, uint256 buyback) =
            _sellUsdcSplit(PxtFeeModel.PENALTY_FEE_BPS, usdcAmount, true);
        uint256 usdcFee = donation + marketing + buyback;
        if (usdcFee == 0) {
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
        Currency quote = _quoteCurrency(key);
        poolManager.take(quote, address(this), usdcFee);
        _tstore(_T_USDC_OUT, usdcAmount);
        _tstore(_T_USDC_SKIM, usdcFee);
        _tstore(_T_QUOTE, uint256(uint160(Currency.unwrap(quote))));
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(usdcFee.toInt128(), 0), 0);
    }

    function _beforeBuy(address sender, PoolKey calldata key, SwapParams calldata params)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Protocol buyback (FeeCollector is PoolManager.swap sender) - do not re-tax recycle USDC.
        if (address(feeCollector) != address(0) && sender == address(feeCollector)) {
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        if (_pxtIsSpecified(key, params)) {
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        uint256 usdcAmount = SignedMath.abs(params.amountSpecified);
        if (usdcAmount == 0) revert ZeroAmount();

        (uint256 donation, uint256 marketing) = PxtFeeModel.splitBuy(usdcAmount);
        uint256 usdcFee = donation + marketing;
        if (usdcFee == 0) {
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        Currency quote = _quoteCurrency(key);
        poolManager.take(quote, address(this), usdcFee);
        _tstore(_T_SPECIFIED_TAKE, usdcFee);

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(usdcFee.toInt128(), 0), 0);
    }

    function _afterSell(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        internal
        returns (bytes4, int128)
    {
        uint256 hookDeltaUnspecified;

        if (_pxtIsSpecified(key, params)) {
            uint256 poolPxt = _absDelta(delta, _pxtIsCurrency0(key));
            uint256 taken = _tload(_T_SPECIFIED_TAKE);
            uint256 burnAmount = PxtFeeModel.grossUp(poolPxt, PxtFeeModel.SELL_BURN_BPS);
            if (burnAmount > taken) burnAmount = taken;
            if (burnAmount > 0) pxt.burnBalance(burnAmount);
            // User still pays `poolPxt + taken` (specified delta is frozen). Refund leftover in attributeSell.
            _tstore(_T_SPECIFIED_TAKE, taken - burnAmount);

            uint256 pxtAmount = poolPxt + taken;
            if (pxtAmount == 0) {
                return (BaseHook.afterSwap.selector, 0);
            }

            uint256 usdcOut = _absDelta(delta, !_pxtIsCurrency0(key));
            (uint256 donation, uint256 marketing, uint256 buyback) =
                PxtFeeModel.splitSellUsdc(PxtFeeModel.PENALTY_FEE_BPS, usdcOut);
            uint256 usdcFee = donation + marketing + buyback;
            Currency quote = _quoteCurrency(key);
            if (usdcFee > 0) {
                poolManager.take(quote, address(this), usdcFee);
            }
            _recordPendingSkim(sender, pxtAmount, usdcOut, usdcFee, Currency.unwrap(quote), false);
            hookDeltaUnspecified = usdcFee;
            emit HookFeeCharged(address(0), FeeKind.Penalty, PxtFeeModel.PENALTY_FEE_BPS, usdcFee + burnAmount);
            emit FeeCharged(
                address(0), address(poolManager), FeeKind.Penalty, PxtFeeModel.PENALTY_FEE_BPS, usdcFee + burnAmount
            );
        } else {
            uint256 poolPxt = _absDelta(delta, _pxtIsCurrency0(key));
            uint256 burnAmount = PxtFeeModel.grossUp(poolPxt, PxtFeeModel.SELL_BURN_BPS);
            if (poolPxt == 0 && burnAmount == 0) {
                return (BaseHook.afterSwap.selector, 0);
            }
            if (burnAmount > 0) {
                poolManager.take(pxtCurrency, address(this), burnAmount);
                pxt.burnBalance(burnAmount);
            }
            uint256 skimmed = _tload(_T_USDC_SKIM);
            uint256 usdcOut = _tload(_T_USDC_OUT);
            address quoteAddr = address(uint160(_tload(_T_QUOTE)));
            _recordPendingSkim(sender, poolPxt + burnAmount, usdcOut, skimmed, quoteAddr, true);
            hookDeltaUnspecified = burnAmount;
            emit HookFeeCharged(address(0), FeeKind.Penalty, PxtFeeModel.PENALTY_FEE_BPS, skimmed + burnAmount);
            emit FeeCharged(
                address(0), address(poolManager), FeeKind.Penalty, PxtFeeModel.PENALTY_FEE_BPS, skimmed + burnAmount
            );
        }

        return (BaseHook.afterSwap.selector, hookDeltaUnspecified.toInt128());
    }

    function _afterBuy(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        internal
        returns (bytes4, int128)
    {
        if (address(feeCollector) != address(0) && sender == address(feeCollector)) {
            return (BaseHook.afterSwap.selector, 0);
        }

        Currency quote = _quoteCurrency(key);
        uint256 poolUsdc = _absDelta(delta, !_pxtIsCurrency0(key));

        if (!_pxtIsSpecified(key, params)) {
            uint256 taken = _tload(_T_SPECIFIED_TAKE);
            _tstore(_T_SPECIFIED_TAKE, 0);
            uint256 fee = PxtFeeModel.grossUp(poolUsdc, PxtFeeModel.BUY_FEE_BPS);
            (uint256 donation, uint256 marketing) = PxtFeeModel.splitBuy(poolUsdc + fee);
            uint256 keep = donation + marketing;
            if (keep > taken) keep = taken;
            uint256 extra = taken - keep;
            if (keep == 0 && extra == 0) {
                return (BaseHook.afterSwap.selector, 0);
            }
            if (donation + marketing != keep && donation + marketing != 0) {
                donation = (keep * donation) / (donation + marketing);
                marketing = keep - donation;
            }
            // v4 cannot cut exact-in specified; leftover request slice is booked as buyback.
            _accrueUsdc(quote, FeeKind.Buy, donation, marketing, extra);
            emit HookFeeCharged(address(0), FeeKind.Buy, PxtFeeModel.BUY_FEE_BPS, keep + extra);
            emit FeeCharged(address(0), address(poolManager), FeeKind.Buy, PxtFeeModel.BUY_FEE_BPS, keep + extra);
            return (BaseHook.afterSwap.selector, 0);
        }

        if (poolUsdc == 0) {
            return (BaseHook.afterSwap.selector, 0);
        }

        {
            uint256 usdcFee = PxtFeeModel.grossUp(poolUsdc, PxtFeeModel.BUY_FEE_BPS);
            if (usdcFee == 0) {
                return (BaseHook.afterSwap.selector, 0);
            }
            (uint256 donation, uint256 marketing) = PxtFeeModel.splitBuy(poolUsdc + usdcFee);
            poolManager.take(quote, address(this), donation + marketing);
            _accrueUsdc(quote, FeeKind.Buy, donation, marketing, 0);

            emit HookFeeCharged(address(0), FeeKind.Buy, PxtFeeModel.BUY_FEE_BPS, donation + marketing);
            emit FeeCharged(
                address(0), address(poolManager), FeeKind.Buy, PxtFeeModel.BUY_FEE_BPS, donation + marketing
            );

            return (BaseHook.afterSwap.selector, (donation + marketing).toInt128());
        }
    }

    function _accrueUsdc(Currency quote, FeeKind kind, uint256 donation, uint256 marketing, uint256 buyback) internal {
        if (address(feeCollector) == address(0)) revert FeeCollectorNotSet();
        uint256 total = donation + marketing + buyback;
        if (total == 0) return;

        address token = Currency.unwrap(quote);
        IERC20(token).forceApprove(address(feeCollector), total);
        feeCollector.receiveAccruedFees(token, kind, donation, marketing, 0, buyback);
    }

    function _fairSellFeeBps(address seller, uint256 amount, uint256 balanceBefore) internal view returns (uint256) {
        Pxt.WalletStatus status = pxt.walletStatus(seller);
        if (status == Pxt.WalletStatus.FeeExempt) return 0;
        if (status == Pxt.WalletStatus.NoPenalty) return PxtFeeModel.SELL_FEE_BPS;

        SellWindow storage window = sellWindows[seller];
        uint256 soldInWindow = window.soldInWindow;
        uint256 balanceAtStart = window.balanceAtWindowStart;

        if (window.windowStart == 0 || block.timestamp >= window.windowStart + PxtFeeModel.PENALTY_WINDOW) {
            soldInWindow = 0;
            balanceAtStart = balanceBefore;
        }

        uint256 newSold = soldInWindow + amount;
        if (balanceAtStart > balanceBefore) balanceAtStart = balanceBefore;
        bool penalized =
            balanceAtStart > 0 && newSold * PxtFeeModel.BPS > balanceAtStart * PxtFeeModel.PENALTY_THRESHOLD_BPS;
        return penalized ? PxtFeeModel.PENALTY_FEE_BPS : PxtFeeModel.SELL_FEE_BPS;
    }

    function _applySellWindow(address seller, uint256 amount, uint256 balanceBefore) internal {
        if (pxt.walletStatus(seller) == Pxt.WalletStatus.NoPenalty) return;
        if (pxt.walletStatus(seller) == Pxt.WalletStatus.FeeExempt) return;

        SellWindow storage window = sellWindows[seller];
        if (window.windowStart == 0 || block.timestamp >= window.windowStart + PxtFeeModel.PENALTY_WINDOW) {
            window.windowStart = uint64(block.timestamp);
            window.soldInWindow = 0;
            window.balanceAtWindowStart = balanceBefore;
        } else if (balanceBefore < window.balanceAtWindowStart) {
            window.balanceAtWindowStart = balanceBefore;
        }
        window.soldInWindow += amount;
    }

    /// @dev Pre-sell holdings excluding PXT received from PoolManager in this transaction (FBBP).
    function _effectiveSellBalance(address seller, uint256 pxtAmount) internal view returns (uint256) {
        uint256 raw = pxt.balanceOf(seller) + pxtAmount;
        uint256 fromPm = _tload(_pmInSlot(seller));
        if (raw > fromPm) return raw - fromPm;
        return pxtAmount;
    }

    function _pmInSlot(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(_T_PM_IN, account));
    }

    function _enforceOfficialPool(PoolKey calldata key) internal view {
        if (!_poolContainsPxt(key)) revert InvalidPool();
        if (!officialPoolSet) revert OfficialPoolNotSet();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(officialPoolId)) revert InvalidPool();
    }

    function _poolContainsPxt(PoolKey calldata key) internal view returns (bool) {
        address token = address(pxt);
        return Currency.unwrap(key.currency0) == token || Currency.unwrap(key.currency1) == token;
    }

    function _pxtIsCurrency0(PoolKey calldata key) internal view returns (bool) {
        return Currency.unwrap(key.currency0) == address(pxt);
    }

    function _quoteCurrency(PoolKey calldata key) internal view returns (Currency) {
        return _pxtIsCurrency0(key) ? key.currency1 : key.currency0;
    }

    function _classifySwap(PoolKey calldata key, SwapParams calldata params)
        internal
        view
        returns (bool isBuy, bool isSell)
    {
        bool pxtIs0 = _pxtIsCurrency0(key);
        if (pxtIs0) {
            isBuy = !params.zeroForOne;
            isSell = params.zeroForOne;
        } else {
            isBuy = params.zeroForOne;
            isSell = !params.zeroForOne;
        }
    }

    function _pxtIsSpecified(PoolKey calldata key, SwapParams calldata params) internal view returns (bool) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIs0 == _pxtIsCurrency0(key);
    }

    function _recordPendingSkim(
        address debtor,
        uint256 pxtIn,
        uint256 usdcOut,
        uint256 usdcSkim,
        address quote,
        bool feeOnNet
    ) internal {
        _tstore(_T_PXT_IN, pxtIn);
        _tstore(_T_USDC_OUT, usdcOut);
        _tstore(_T_USDC_SKIM, usdcSkim);
        _tstore(_T_QUOTE, uint256(uint160(quote)));
        _tstore(_T_FEE_ON_NET, feeOnNet ? 1 : 0);
        _tstore(_T_DEBTOR, uint256(uint160(debtor)));
        orphanSkim = OrphanSkim({
            pxtIn: pxtIn.toUint128(),
            usdcOut: usdcOut.toUint128(),
            usdcSkim: usdcSkim.toUint128(),
            quote: quote,
            feeOnNet: feeOnNet
        });
    }

    function _clearPendingSkim() internal {
        _tstore(_T_PXT_IN, 0);
        _tstore(_T_USDC_OUT, 0);
        _tstore(_T_USDC_SKIM, 0);
        _tstore(_T_QUOTE, 0);
        _tstore(_T_FEE_ON_NET, 0);
        _tstore(_T_SPECIFIED_TAKE, 0);
        _tstore(_T_DEBTOR, 0);
        orphanSkim = OrphanSkim({pxtIn: 0, usdcOut: 0, usdcSkim: 0, quote: address(0), feeOnNet: false});
    }

    function _sellUsdcSplit(uint256 feeBps, uint256 usdcAmount, bool feeOnNet)
        internal
        pure
        returns (uint256 donation, uint256 marketing, uint256 buyback)
    {
        if (feeOnNet) {
            uint256 bps = PxtFeeModel.sellUsdcBps(feeBps);
            usdcAmount = usdcAmount + PxtFeeModel.grossUp(usdcAmount, bps);
        }
        return PxtFeeModel.splitSellUsdc(feeBps, usdcAmount);
    }

    function _absDelta(BalanceDelta delta, bool token0) internal pure returns (uint256) {
        int256 amount = token0 ? int256(delta.amount0()) : int256(delta.amount1());
        return SignedMath.abs(amount);
    }

    function _tstore(bytes32 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
