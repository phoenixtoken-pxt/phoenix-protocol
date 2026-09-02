// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {Pxt} from "../core/Pxt.sol";
import {FeeKind, PxtFeeModel, ZeroAddress} from "../core/PxtFeeModel.sol";
import {IPxtSellControls, PxtSellAccess} from "../core/PxtSellAccess.sol";
import {PhoenixBuybackMath} from "./PhoenixBuybackMath.sol";

// Protocol LP seed + cash USDC buyback + PXT recycle LP.
// Fee accrual (`receiveAccruedFees` / `collect`) is on PhoenixFeeCollector, which inherits this.
// Buyback is cash-only (ReturnDelta USDC skims); bought PXT is recycled as single-sided LP.
// Buyback swaps skip the hook buy skim when unlock sender is the FeeCollector address.
// executeBuyback is allowlisted via isAuthorizedBuybackCaller; BUYBACK_EXECUTOR_APPROVER_ROLE
// manages the list after Ownable renounce (intended multisig, parallel to Pxt recipient approver).
// Fill min-out / sqrtLimit use previous-block official-pool spot (`frozenSqrtPriceX96`).
abstract contract PhoenixBuyback is IUnlockCallback, Ownable, AccessControl, ReentrancyGuard {
    bytes32 public constant BUYBACK_EXECUTOR_APPROVER_ROLE = keccak256("BUYBACK_EXECUTOR_APPROVER_ROLE");

    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint8 private constant ACTION_ADD = 0;
    /// @dev Spend USDC already held (skim accruals) to buy PXT + recycle LP.
    uint8 private constant ACTION_BUYBACK_CASH = 1;

    /// @dev Distinct salt so recycle LP never mixes with the seeded full-range position.
    bytes32 public constant RECYCLE_SALT = keccak256("PHOENIX_RECYCLE_LP");

    IPoolManager public immutable poolManager;
    Pxt public immutable pxt;
    address public immutable donationWallet;
    address public immutable marketingWallet;

    address public hook;

    PoolKey public poolKey;
    int24 public tickLower;
    int24 public tickUpper;
    bytes32 public positionSalt;
    bool public poolConfigured;
    /// @notice True after the one-shot protocol seed mint. Recycle LP uses a different salt and is unaffected.
    bool public seedLiquidityAdded;

    /// @notice Recycle band width in tick-spacings (e.g. 10 -> 10 * pool.tickSpacing).
    uint24 public recycleWidthSpacings = 10;
    /// @notice Max USDC→PXT buyback slippage vs previous-block official-pool spot (bps). Default 2%; frozen at renounce.
    /// @dev Band is MEV / price impact only (buy skim skipped when swap sender is FeeCollector).
    ///      Fill quality uses `frozenSqrtPriceX96`, not this-block `slot0`. Recycle ticks still use live spot.
    uint16 public maxBuybackSlippageBps = 200;

    /// @notice Cumulative PXT deposited into single-sided recycle LP (not held as ERC-20).
    uint256 public recyclePxt;
    /// @notice Last recycle band ticks / liquidity minted (each buyback may use a new range).
    int24 public lastRecycleTickLower;
    int24 public lastRecycleTickUpper;
    uint128 public lastRecycleLiquidity;

    /// @notice Accrued obligations per ERC-20 (quote and/or PXT).
    mapping(address => uint256) public pendingDonation;
    mapping(address => uint256) public pendingMarketing;
    mapping(address => uint256) public pendingBurn;
    mapping(address => uint256) public pendingBuyback;

    /// @dev Only authorized ops / keeper addresses may call executeBuyback.
    mapping(address => bool) public isAuthorizedBuybackCaller;

    /// @notice Last official-pool spot from a *prior* block (buyback min / limit reference).
    uint160 public frozenSqrtPriceX96;
    /// @notice Last official-pool spot observed this `pendingSpotBlock`.
    uint160 public pendingSqrtPriceX96;
    uint256 public pendingSpotBlock;

    event HookSet(address indexed hook);
    event BuybackSpotNoted(uint160 sqrtPriceX96, uint256 blockNumber);
    event AuthorizedBuybackCallerSet(address indexed caller, bool authorized);
    event PoolConfigured(PoolKey key, int24 tickLower, int24 tickUpper, bytes32 salt);
    event BuybackParamsSet(uint24 recycleWidthSpacings, uint16 maxBuybackSlippageBps);
    event FeeAccrued(
        address indexed token,
        FeeKind kind,
        uint256 grossAmount,
        uint256 donation,
        uint256 marketing,
        uint256 burnAmount,
        uint256 buyback
    );
    event FeesCollected(
        address indexed caller,
        address indexed token,
        uint256 donation,
        uint256 marketing,
        uint256 burnAmount,
        uint256 buyback,
        uint256 pulledFromPool
    );
    event TokensBurned(address indexed token, uint256 amount);
    event BuybackExecuted(
        address indexed caller,
        uint256 usdcSpent,
        uint256 pxtBought,
        uint256 recycleAdded,
        int24 recycleTickLower,
        int24 recycleTickUpper,
        uint128 recycleLiquidity
    );
    event RecycleLiquidityAdded(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 pxtAmount);
    /// @notice Ideal wallet/burn pending reduced to match on-hand tokens after a collect/pull.
    event AccrualReconciled(address indexed token, uint256 dueBefore, uint256 dueAfter);

    error NotHook();
    error HookAlreadySet();
    error LiquidityAlreadySeeded();
    error NotPoolManager();
    error PoolAlreadyConfigured();
    error PoolNotConfigured();
    error ZeroLiquidity();
    error NoBuybackBudget();
    error DeadlineExpired();
    error Slippage();
    error InvalidAction();
    error InvalidRecycleWidth();
    error InvalidSlippageBps();
    error RecycleRangeInvalid();
    error RecycleBandNotPxtOnly();
    error SlippageNotConfigured();
    error UnauthorizedBuybackCaller();
    error BuybackPriceNotWarmed();

    modifier onlyHook() {
        _onlyHook();
        _;
    }

    function _onlyHook() internal view {
        if (msg.sender != hook) revert NotHook();
    }

    constructor(IPoolManager poolManager_, Pxt pxt_, address donation_, address marketing_, address admin_)
        Ownable(admin_)
    {
        if (
            address(poolManager_) == address(0) || address(pxt_) == address(0) || donation_ == address(0)
                || marketing_ == address(0) || admin_ == address(0)
        ) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        pxt = pxt_;
        donationWallet = donation_;
        marketingWallet = marketing_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(BUYBACK_EXECUTOR_APPROVER_ROLE, admin_);
        _setAuthorizedBuybackCaller(admin_, true);
    }

    /// @notice Allow/deny an address to call executeBuyback. Intended for a multisig with
    /// BUYBACK_EXECUTOR_APPROVER_ROLE after Ownable is renounced.
    function setAuthorizedBuybackCaller(address caller, bool authorized)
        external
        onlyRole(BUYBACK_EXECUTOR_APPROVER_ROLE)
    {
        if (caller == address(0)) revert ZeroAddress();
        _setAuthorizedBuybackCaller(caller, authorized);
    }

    function _setAuthorizedBuybackCaller(address caller, bool authorized) internal {
        isAuthorizedBuybackCaller[caller] = authorized;
        emit AuthorizedBuybackCallerSet(caller, authorized);
    }

    /// @notice Record official-pool spot after a swap (including protocol buyback). Hook only.
    ///         Promotes last block's pending into `frozenSqrtPriceX96` before overwriting pending.
    function noteOfficialSpot(uint160 sqrtPriceX96) external onlyHook {
        if (sqrtPriceX96 == 0) return;
        _promoteBuybackSpot();
        pendingSqrtPriceX96 = sqrtPriceX96;
        pendingSpotBlock = block.number;
        emit BuybackSpotNoted(sqrtPriceX96, block.number);
    }

    /// @dev If the last observed swap was in an earlier block, freeze that price as the buyback ref.
    function _promoteBuybackSpot() internal {
        if (pendingSpotBlock != 0 && block.number > pendingSpotBlock) {
            frozenSqrtPriceX96 = pendingSqrtPriceX96;
        }
    }

    /// @dev Previous-block spot. Reverts until at least one official swap has been promoted.
    function _buybackRefSqrtPriceX96() internal returns (uint160 ref) {
        _promoteBuybackSpot();
        ref = frozenSqrtPriceX96;
        if (ref == 0) revert BuybackPriceNotWarmed();
    }

    /// @notice One-time pool + position range used for seed LP and fee collection.
    function configurePool(PoolKey calldata key, int24 tickLower_, int24 tickUpper_, bytes32 salt_) external onlyOwner {
        if (poolConfigured) revert PoolAlreadyConfigured();
        poolKey = key;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        positionSalt = salt_;
        poolConfigured = true;
        emit PoolConfigured(key, tickLower_, tickUpper_, salt_);
    }

    /// @notice Configure recycle width + buyback MEV slippage (call before renouncing ownership).
    /// @param recycleWidthSpacings_ Band width in multiples of pool tickSpacing (min 1).
    /// @param maxBuybackSlippageBps_ Max USDC -> PXT fill slippage vs previous-block spot (1..9999 bps).
    function setBuybackParams(uint24 recycleWidthSpacings_, uint16 maxBuybackSlippageBps_) external onlyOwner {
        if (recycleWidthSpacings_ == 0) revert InvalidRecycleWidth();
        if (maxBuybackSlippageBps_ == 0 || maxBuybackSlippageBps_ >= PxtFeeModel.BPS) {
            revert InvalidSlippageBps();
        }
        recycleWidthSpacings = recycleWidthSpacings_;
        maxBuybackSlippageBps = maxBuybackSlippageBps_;
        emit BuybackParamsSet(recycleWidthSpacings_, maxBuybackSlippageBps_);
    }

    /// @notice One-shot protocol seed LP. Caller supplies tokens; position owned by this contract.
    ///         Cannot be called again (extra LP is minted on Uniswap, not through this function).
    function addLiquidity(uint256 amount0Desired, uint256 amount1Desired, uint128 liquidity, bytes calldata hookData)
        external
        onlyOwner
        nonReentrant
    {
        if (!poolConfigured) revert PoolNotConfigured();
        if (seedLiquidityAdded) revert LiquidityAlreadySeeded();
        if (liquidity == 0) revert ZeroLiquidity();

        PoolKey memory key = poolKey;
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        if (amount0Desired > 0) {
            IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1Desired);
        }

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: positionSalt
        });

        poolManager.unlock(abi.encode(ACTION_ADD, abi.encode(params, hookData)));
        seedLiquidityAdded = true;

        // Return unused seed tokens to caller.
        uint256 left0 = IERC20(token0).balanceOf(address(this));
        uint256 left1 = IERC20(token1).balanceOf(address(this));
        if (left0 > 0) IERC20(token0).safeTransfer(msg.sender, left0);
        if (left1 > 0) IERC20(token1).safeTransfer(msg.sender, left1);
    }

    /// @dev Buyback / recycle only after sell unlock and anti-bot clear.
    function _requireTradingOpen() internal view {
        PxtSellAccess.enforceTradingOpen(IPxtSellControls(address(pxt)));
    }

    /// @notice Authorized cash buyback: spend pending USDC buyback budget, recycle bought PXT as LP.
    /// @param usdcAmount Max USDC to spend (`0` = full available buyback budget).
    /// @param minPxtBought Caller floor on PXT bought. Prefer a quote-based floor (keeper); `0` still
    ///        enforces protocol `maxBuybackSlippageBps` vs the previous-block official-pool spot.
    function executeBuyback(uint256 usdcAmount, uint256 minPxtBought, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdcSpent, uint256 pxtBought)
    {
        if (!isAuthorizedBuybackCaller[msg.sender]) revert UnauthorizedBuybackCaller();
        if (!poolConfigured) revert PoolNotConfigured();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (maxBuybackSlippageBps == 0) revert SlippageNotConfigured();
        _requireTradingOpen();

        address pxtAddr = address(pxt);
        PoolKey memory key = poolKey;
        address quote =
            Currency.unwrap(key.currency0) == pxtAddr ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

        uint256 usdcBudget = pendingBuyback[quote];
        if (usdcBudget == 0) revert NoBuybackBudget();
        return _executeBuybackCash(quote, usdcBudget, usdcAmount, minPxtBought);
    }

    function _walletBurnDue(address token) internal view returns (uint256) {
        return pendingDonation[token] + pendingMarketing[token] + pendingBurn[token];
    }

    function _executeBuybackCash(address quote, uint256 usdcBudget, uint256 usdcAmount, uint256 minPxtBought)
        internal
        returns (uint256 usdcSpent, uint256 pxtBought)
    {
        uint256 reserved = _walletBurnDue(quote);
        uint256 bal = IERC20(quote).balanceOf(address(this));
        uint256 spendable = bal > reserved ? bal - reserved : 0;
        uint256 spend = usdcAmount == 0 ? usdcBudget : usdcAmount;
        if (spend > usdcBudget) spend = usdcBudget;
        if (spend > spendable) spend = spendable;
        if (spend == 0) revert NoBuybackBudget();

        PoolKey memory key = poolKey;
        uint160 sqrtPriceX96 = _buybackRefSqrtPriceX96();
        bool pxtIsToken0 = Currency.unwrap(key.currency0) == address(pxt);
        bool zeroForOne = !pxtIsToken0;
        uint160 sqrtLimit =
            PhoenixBuybackMath.sqrtPriceLimitAfterSlippage(sqrtPriceX96, zeroForOne, maxBuybackSlippageBps);

        bytes memory result = poolManager.unlock(
            abi.encode(ACTION_BUYBACK_CASH, abi.encode(spend, sqrtLimit, abi.encode(address(this))))
        );
        (uint256 quoteSpent, uint256 recycled, int24 recLower, int24 recUpper, uint128 recLiq) =
            abi.decode(result, (uint256, uint256, int24, int24, uint128));

        usdcSpent = quoteSpent;
        pxtBought = recycled;
        uint256 expectedPxt = PhoenixBuybackMath.pxtForQuote(usdcSpent, sqrtPriceX96, pxtIsToken0);
        PhoenixBuybackMath.enforceMinOut(pxtBought, minPxtBought, expectedPxt, maxBuybackSlippageBps);

        pendingBuyback[quote] = usdcBudget - usdcSpent;
        _reconcilePending(quote);

        recyclePxt += recycled;
        lastRecycleTickLower = recLower;
        lastRecycleTickUpper = recUpper;
        lastRecycleLiquidity = recLiq;

        emit BuybackExecuted(msg.sender, usdcSpent, pxtBought, recycled, recLower, recUpper, recLiq);
    }

    function pending(address token)
        external
        view
        returns (uint256 donation, uint256 marketing, uint256 burnAmount, uint256 buyback)
    {
        return (pendingDonation[token], pendingMarketing[token], pendingBurn[token], pendingBuyback[token]);
    }

    /// @notice Preview cash buyback budget and seeded position liquidity.
    function quoteBuyback() external view returns (uint256 usdcSpendable, uint128 positionLiquidity) {
        if (!poolConfigured) return (0, 0);

        PoolKey memory key = poolKey;
        PoolId id = key.toId();
        (positionLiquidity,,) = poolManager.getPositionInfo(id, address(this), tickLower, tickUpper, positionSalt);

        address pxtAddr = address(pxt);
        address quote =
            Currency.unwrap(key.currency0) == pxtAddr ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

        uint256 usdcBudget = pendingBuyback[quote];
        if (usdcBudget == 0) return (0, positionLiquidity);

        uint256 reserved = _walletBurnDue(quote);
        uint256 bal = IERC20(quote).balanceOf(address(this));
        uint256 spendable = bal > reserved ? bal - reserved : 0;
        usdcSpendable = usdcBudget < spendable ? usdcBudget : spendable;
    }

    /// @dev Cap all four pending legs to on-hand cash. Buyback is reserved first, then burn, then wallets.
    function _reconcilePending(address token) internal {
        uint256 don = pendingDonation[token];
        uint256 mkt = pendingMarketing[token];
        uint256 burn = pendingBurn[token];
        uint256 bb = pendingBuyback[token];
        uint256 due = don + mkt + burn + bb;
        if (due == 0) return;

        uint256 bal = IERC20(token).balanceOf(address(this));
        if (due <= bal) return;

        uint256 bbKeep = bb < bal ? bb : bal;
        uint256 rest = bal - bbKeep;
        uint256 burnKeep = burn < rest ? burn : rest;
        rest -= burnKeep;

        uint256 wallets = don + mkt;
        uint256 donKeep = 0;
        uint256 mktKeep = 0;
        if (wallets > 0 && rest > 0) {
            donKeep = (don * rest) / wallets;
            mktKeep = rest - donKeep;
        }

        pendingBuyback[token] = bbKeep;
        pendingBurn[token] = burnKeep;
        pendingDonation[token] = donKeep;
        pendingMarketing[token] = mktKeep;

        emit AccrualReconciled(token, due, bbKeep + burnKeep + donKeep + mktKeep);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (uint8 action, bytes memory data) = abi.decode(rawData, (uint8, bytes));
        PoolKey memory key = poolKey;

        if (action == ACTION_ADD) {
            (ModifyLiquidityParams memory params, bytes memory hookData) =
                abi.decode(data, (ModifyLiquidityParams, bytes));
            (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, hookData);

            if (delta.amount0() < 0) {
                key.currency0.settle(poolManager, address(this), uint256(int256(-delta.amount0())), false);
            }
            if (delta.amount1() < 0) {
                key.currency1.settle(poolManager, address(this), uint256(int256(-delta.amount1())), false);
            }
            if (delta.amount0() > 0) {
                key.currency0.take(poolManager, address(this), uint256(int256(delta.amount0())), false);
            }
            if (delta.amount1() > 0) {
                key.currency1.take(poolManager, address(this), uint256(int256(delta.amount1())), false);
            }
            return abi.encode(delta);
        }

        if (action == ACTION_BUYBACK_CASH) {
            (uint256 usdcSpend, uint160 sqrtPriceLimitX96, bytes memory hookData) =
                abi.decode(data, (uint256, uint160, bytes));
            address pxtAddr = address(pxt);
            bool pxtIsToken0 = Currency.unwrap(key.currency0) == pxtAddr;
            uint256 pxtStart = IERC20(pxtAddr).balanceOf(address(this));

            uint256 quoteSpent = 0;
            if (usdcSpend > 0) {
                bool zeroForOne = !pxtIsToken0;
                Currency quoteCurrency = pxtIsToken0 ? key.currency1 : key.currency0;
                Currency pxtCurrency_ = pxtIsToken0 ? key.currency0 : key.currency1;

                // casting to int256 is safe: usdcSpend is an accrued fee amount well below int256 max
                // forge-lint: disable-next-line(unsafe-typecast)
                int256 usdcSpecified = -int256(usdcSpend);
                BalanceDelta swapDelta = poolManager.swap(
                    key,
                    SwapParams({
                        zeroForOne: zeroForOne, amountSpecified: usdcSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
                    }),
                    hookData
                );

                if (zeroForOne) {
                    quoteSpent = uint256(int256(-swapDelta.amount0()));
                    quoteCurrency.settle(poolManager, address(this), quoteSpent, false);
                    if (swapDelta.amount1() > 0) {
                        pxtCurrency_.take(poolManager, address(this), uint256(int256(swapDelta.amount1())), false);
                    }
                } else {
                    quoteSpent = uint256(int256(-swapDelta.amount1()));
                    quoteCurrency.settle(poolManager, address(this), quoteSpent, false);
                    if (swapDelta.amount0() > 0) {
                        pxtCurrency_.take(poolManager, address(this), uint256(int256(swapDelta.amount0())), false);
                    }
                }
            }

            uint256 recycleAdded = IERC20(pxtAddr).balanceOf(address(this)) - pxtStart;
            int24 recLower;
            int24 recUpper;
            uint128 recLiq;
            if (recycleAdded > 0) {
                (recLower, recUpper, recLiq) = _addRecycleLiquidity(key, recycleAdded, pxtIsToken0, hookData);
            }

            return abi.encode(quoteSpent, recycleAdded, recLower, recUpper, recLiq);
        }

        revert InvalidAction();
    }

    function _burnToken(address token, uint256 amount) internal {
        if (amount == 0 || token != address(pxt)) return;
        pxt.burnBalance(amount);
        emit TokensBurned(token, amount);
    }

    /// @dev Deposit `pxtAmount` as single-sided LP on the PXT side of spot.
    ///      Always mints the current ideal ticks; never pulls USDC (`quoteDelta < 0` reverts).
    function _addRecycleLiquidity(PoolKey memory key, uint256 pxtAmount, bool pxtIsToken0, bytes memory hookData)
        internal
        returns (int24 lo, int24 hi, uint128 liquidity)
    {
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        int24 spacing = key.tickSpacing;
        (lo, hi) = PhoenixBuybackMath.recycleTicks(tick, spacing, recycleWidthSpacings, pxtIsToken0);
        if (lo >= hi) revert RecycleRangeInvalid();

        uint160 sqrtL = TickMath.getSqrtPriceAtTick(lo);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(hi);
        if (pxtIsToken0) {
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtL, sqrtU, pxtAmount);
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtL, sqrtU, pxtAmount);
        }
        if (liquidity == 0) revert ZeroLiquidity();

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(liquidity)), salt: RECYCLE_SALT
            }),
            hookData
        );

        // Never settle quote (USDC) for recycle — only PXT-only ranges are allowed.
        int256 pxtDelta = pxtIsToken0 ? delta.amount0() : delta.amount1();
        int256 quoteDelta = pxtIsToken0 ? delta.amount1() : delta.amount0();
        if (quoteDelta < 0) revert RecycleBandNotPxtOnly();

        Currency pxtCurrency = pxtIsToken0 ? key.currency0 : key.currency1;
        Currency quoteCurrency = pxtIsToken0 ? key.currency1 : key.currency0;
        if (pxtDelta < 0) {
            pxtCurrency.settle(poolManager, address(this), uint256(int256(-pxtDelta)), false);
        }
        // Out-of-range single-sided add should not credit quote; return any dust.
        if (pxtDelta > 0) {
            pxtCurrency.take(poolManager, address(this), uint256(int256(pxtDelta)), false);
        }
        if (quoteDelta > 0) {
            quoteCurrency.take(poolManager, address(this), uint256(int256(quoteDelta)), false);
        }

        emit RecycleLiquidityAdded(lo, hi, liquidity, pxtAmount);
    }
}
