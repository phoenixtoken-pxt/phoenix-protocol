// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Pxt} from "../../src/core/Pxt.sol";
import {DEFAULT_SELL_UNLOCK_TIMESTAMP, ZeroAddress} from "../../src/core/PxtFeeModel.sol";
import {PhoenixFeeCollector} from "../../src/fee/PhoenixFeeCollector.sol";
import {PhoenixV4ReturnDeltaHook} from "../../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {PhoenixAntiBotOpenSell} from "../PhoenixAntiBotOpenSell.sol";
import {PhoenixLaunchMath} from "./PhoenixLaunchMath.sol";
import {PhoenixLaunchTypes} from "./PhoenixLaunchTypes.sol";
import {
    PhoenixPxtDeployer,
    PhoenixHookDeployer,
    PhoenixCollectorDeployer,
    PhoenixOpenSellDeployer
} from "./PhoenixChildDeployers.sol";

/// @notice Per-launch owner of Pxt / hook / FeeCollector until `lock()`.
///         Created by PhoenixLauncher. Client is `launchOwner` (seed + lock signer).
contract PhoenixOrchestrator {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public immutable launchOwner;

    Pxt public pxt;
    PhoenixV4ReturnDeltaHook public hook;
    PhoenixFeeCollector public collector;
    PhoenixAntiBotOpenSell public openSell;
    address public quoteToken;
    uint256 public pxtSeed;
    uint256 public usdcSeed;
    uint160 public sqrtPriceX96;
    int24 public tickLower;
    int24 public tickUpper;
    bool public wired;
    bool public locked;

    event Wired(
        address indexed pxt,
        address indexed hook,
        address indexed collector,
        address openSell,
        address quoteToken,
        uint160 sqrtPriceX96
    );
    event Seeded(uint256 pxtAmount, uint256 usdcAmount, uint128 liquidity);
    event Locked(address indexed recipientApprover, uint256 leftoverPxt, uint256 leftoverQuote);

    error NotFactory();
    error NotLaunchOwner();
    error AlreadyWired();
    error NotWired();
    error AlreadyLocked();
    error InvalidTicks();
    error InvalidSeed();
    error LiquidityBelowMin();
    error PoolNotConfigured();
    error ZeroProtocolLiquidity();
    error SlippageNotConfigured();
    error HookMismatch();
    error SellAttributorMustBeHook();
    error FeeWalletMismatch();
    error FeeCollectorMismatch();
    error PoolManagerNotSet();
    error AntiBotSellerNotSet();
    error RecipientApproverRequired();
    error RecipientApproverIsOwner();
    error BuybackCallerRequired();
    error RoleHandoffFailed();
    error RenounceFailed();
    error DeployerStillBuybackCaller();

    modifier onlyLaunchOwner() {
        if (msg.sender != launchOwner) revert NotLaunchOwner();
        _;
    }

    constructor(address factory_, address launchOwner_) {
        if (factory_ == address(0) || launchOwner_ == address(0)) revert ZeroAddress();
        factory = factory_;
        launchOwner = launchOwner_;
    }

    /// @notice Deploy children via CREATE2 deployers; wire; initialize pool. No USDC pulled.
    function wire(PhoenixLaunchTypes.LaunchParams calldata p, PhoenixLaunchTypes.Deployers calldata d) external {
        if (msg.sender != factory) revert NotFactory();
        if (wired) revert AlreadyWired();
        wired = true;

        _validate(p);
        address operator = p.operator == address(0) ? launchOwner : p.operator;
        uint256 sellUnlock = p.sellUnlockTimestamp == 0 ? DEFAULT_SELL_UNLOCK_TIMESTAMP : p.sellUnlockTimestamp;
        int24 lo = p.tickLower == 0 && p.tickUpper == 0 ? PhoenixLaunchTypes.TICK_LOWER : p.tickLower;
        int24 hi = p.tickLower == 0 && p.tickUpper == 0 ? PhoenixLaunchTypes.TICK_UPPER : p.tickUpper;
        if (lo >= hi) revert InvalidTicks();

        bytes32 pxtSalt = keccak256(abi.encodePacked(PhoenixLaunchTypes.PXT_SALT, address(this)));
        Pxt token = PhoenixPxtDeployer(d.pxt).deploy(pxtSalt, address(this), p.donation, p.marketing, sellUnlock);
        PhoenixV4ReturnDeltaHook h =
            PhoenixHookDeployer(d.hook).deploy(p.hookSalt, p.poolManager, token, operator, address(this));
        PhoenixFeeCollector fc =
            PhoenixCollectorDeployer(d.collector).deploy(p.poolManager, token, p.donation, p.marketing, address(this));
        PhoenixAntiBotOpenSell os =
            PhoenixOpenSellDeployer(d.openSell).deploy(token, PoolSwapTest(p.swapRouter), operator);

        pxt = token;
        hook = h;
        collector = fc;
        openSell = os;
        quoteToken = p.quoteToken;
        pxtSeed = p.pxtSeed;
        usdcSeed = p.usdcSeed;
        tickLower = lo;
        tickUpper = hi;

        _configure(p, token, h, fc, os, operator, lo, hi);
        emit Wired(address(token), address(h), address(fc), address(os), p.quoteToken, sqrtPriceX96);
    }

    /// @notice Pull USDC from `launchOwner` (optional permit) and seed protocol LP. One-shot.
    function seed(uint128 minLiquidity, PhoenixLaunchTypes.UsdcPermit calldata permit) external onlyLaunchOwner {
        if (!wired) revert NotWired();
        if (locked) revert AlreadyLocked();

        PhoenixFeeCollector fc = collector;
        address quote = quoteToken;
        uint256 usdcAmt = usdcSeed;
        uint256 pxtAmt = pxtSeed;
        if (permit.deadline != 0) {
            IERC20Permit(quote)
                .permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s);
        }
        IERC20(quote).safeTransferFrom(msg.sender, address(this), usdcAmt);

        PoolKey memory key = PhoenixLaunchMath.poolKey(address(pxt), quote, address(hook));
        (uint256 amount0, uint256 amount1) = PhoenixLaunchMath.orderedAmounts(key, address(pxt), pxtAmt, usdcAmt);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        if (liquidity == 0 || liquidity < minLiquidity) revert LiquidityBelowMin();

        IERC20(address(pxt)).forceApprove(address(fc), pxtAmt);
        IERC20(quote).forceApprove(address(fc), usdcAmt);
        fc.addLiquidity(amount0, amount1, liquidity, abi.encode(address(fc)));
        emit Seeded(pxtAmt, usdcAmt, liquidity);
    }

    /// @notice Sweep leftovers to client, hand AccessControl to `recipientApprover`, renounce Ownable.
    function lock(address recipientApprover, address[] calldata buybackCallers) external onlyLaunchOwner {
        if (!wired) revert NotWired();
        if (locked) revert AlreadyLocked();
        locked = true;

        Pxt token = pxt;
        PhoenixV4ReturnDeltaHook h = hook;
        PhoenixFeeCollector fc = collector;
        _requireLockReady(token, h, fc, recipientApprover);

        uint256 leftoverPxt = token.balanceOf(address(this));
        uint256 leftoverQuote = IERC20(quoteToken).balanceOf(address(this));
        if (leftoverPxt > 0) {
            token.setApprovedContractRecipient(launchOwner, true);
            token.transfer(launchOwner, leftoverPxt);
        }
        if (leftoverQuote > 0) IERC20(quoteToken).safeTransfer(launchOwner, leftoverQuote);

        _handoffRoles(token, fc, recipientApprover, buybackCallers);

        fc.renounceOwnership();
        h.renounceOwnership();
        token.renounceOwnership();

        if (fc.owner() != address(0) || h.owner() != address(0) || token.owner() != address(0)) {
            revert RenounceFailed();
        }
        emit Locked(recipientApprover, leftoverPxt, leftoverQuote);
    }

    function _validate(PhoenixLaunchTypes.LaunchParams calldata p) private pure {
        if (
            address(p.poolManager) == address(0) || p.quoteToken == address(0) || p.donation == address(0)
                || p.marketing == address(0) || p.swapRouter == address(0)
        ) revert ZeroAddress();
        if (p.pxtSeed == 0 || p.usdcSeed == 0) revert InvalidSeed();
    }

    function _configure(
        PhoenixLaunchTypes.LaunchParams calldata p,
        Pxt token,
        PhoenixV4ReturnDeltaHook h,
        PhoenixFeeCollector fc,
        PhoenixAntiBotOpenSell os,
        address operator,
        int24 lo,
        int24 hi
    ) private {
        token.setPoolManager(address(p.poolManager));
        fc.setHook(address(h));
        h.setFeeCollector(fc);
        token.setFeeCollector(address(fc));

        token.setApprovedContractRecipient(address(h), true);
        token.setWalletStatus(address(h), Pxt.WalletStatus.FeeExempt);
        token.setApprovedContractRecipient(address(fc), true);
        token.setWalletStatus(address(fc), Pxt.WalletStatus.FeeExempt);
        token.setSellAttributor(h);
        token.setApprovedContractRecipient(address(os), true);
        token.setWalletStatus(address(os), Pxt.WalletStatus.FeeExempt);
        token.setAntiBotSeller(address(os));
        token.setWalletStatus(launchOwner, Pxt.WalletStatus.FeeExempt);
        token.setApprovedContractRecipient(launchOwner, true);
        token.setWalletStatus(operator, Pxt.WalletStatus.FeeExempt);

        _allowlist(token, p.lpRouter);
        _allowlist(token, p.swapRouter);
        _allowlist(token, p.positionManager);
        _allowlist(token, p.universalRouter);
        _applyStatuses(token, p.feeExempt, Pxt.WalletStatus.FeeExempt);
        _applyStatuses(token, p.noPenalty, Pxt.WalletStatus.NoPenalty);

        PoolKey memory key = PhoenixLaunchMath.poolKey(address(token), p.quoteToken, address(h));
        h.setOfficialPool(key);

        uint160 price = p.sqrtPriceX96;
        if (price == 0) {
            price = PhoenixLaunchMath.sqrtPriceForSpot(address(token), p.quoteToken, p.pxtSeed, p.usdcSeed);
        }
        sqrtPriceX96 = price;
        p.poolManager.initialize(key, price);

        fc.configurePool(key, lo, hi, bytes32(0));
        uint24 width = p.recycleWidthSpacings == 0 ? 10 : p.recycleWidthSpacings;
        uint16 slip = p.maxBuybackSlippageBps == 0 ? 200 : p.maxBuybackSlippageBps;
        fc.setBuybackParams(width, slip);
    }

    function _allowlist(Pxt token, address who) private {
        if (who == address(0)) return;
        token.setApprovedContractRecipient(who, true);
    }

    function _applyStatuses(Pxt token, address[] calldata wallets, Pxt.WalletStatus status) private {
        for (uint256 i; i < wallets.length; ++i) {
            address w = wallets[i];
            if (w == address(0)) continue;
            token.setWalletStatus(w, status);
        }
    }

    function _requireLockReady(
        Pxt token,
        PhoenixV4ReturnDeltaHook h,
        PhoenixFeeCollector fc,
        address recipientApprover
    ) private view {
        if (recipientApprover == address(0)) revert RecipientApproverRequired();
        if (recipientApprover == launchOwner || recipientApprover == address(this)) revert RecipientApproverIsOwner();
        if (!fc.poolConfigured()) revert PoolNotConfigured();
        if (address(fc.hook()) != address(h) || address(h.feeCollector()) != address(fc)) revert HookMismatch();
        if (address(token.sellAttributor()) != address(h)) revert SellAttributorMustBeHook();
        if (token.DONATION_WALLET() != fc.donationWallet() || token.MARKETING_WALLET() != fc.marketingWallet()) {
            revert FeeWalletMismatch();
        }
        if (token.feeCollector() != address(fc)) revert FeeCollectorMismatch();
        if (token.poolManager() == address(0)) revert PoolManagerNotSet();
        if (token.antiBotSeller() == address(0)) revert AntiBotSellerNotSet();
        if (!fc.seedLiquidityAdded()) revert ZeroProtocolLiquidity();
        (, uint128 positionLiq) = fc.quoteBuyback();
        if (positionLiq == 0) revert ZeroProtocolLiquidity();
        if (fc.maxBuybackSlippageBps() == 0) revert SlippageNotConfigured();
    }

    function _handoffRoles(
        Pxt token,
        PhoenixFeeCollector fc,
        address recipientApprover,
        address[] calldata buybackCallers
    ) private {
        bytes32 pxtAdmin = token.DEFAULT_ADMIN_ROLE();
        bytes32 pxtApprover = token.RECIPIENT_APPROVER_ROLE();
        token.grantRole(pxtApprover, recipientApprover);
        token.grantRole(pxtAdmin, recipientApprover);
        token.revokeRole(pxtApprover, address(this));
        token.renounceRole(pxtAdmin, address(this));

        bytes32 fcAdmin = fc.DEFAULT_ADMIN_ROLE();
        bytes32 fcBuyback = fc.BUYBACK_EXECUTOR_APPROVER_ROLE();
        fc.grantRole(fcBuyback, recipientApprover);
        fc.grantRole(fcAdmin, recipientApprover);

        uint256 applied;
        for (uint256 i; i < buybackCallers.length; ++i) {
            address w = buybackCallers[i];
            if (w == address(0) || w == address(this) || w == launchOwner) continue;
            fc.setAuthorizedBuybackCaller(w, true);
            unchecked {
                ++applied;
            }
        }
        if (applied == 0) revert BuybackCallerRequired();
        fc.setAuthorizedBuybackCaller(address(this), false);
        if (fc.isAuthorizedBuybackCaller(address(this))) revert DeployerStillBuybackCaller();

        fc.revokeRole(fcBuyback, address(this));
        fc.renounceRole(fcAdmin, address(this));

        if (!token.hasRole(pxtApprover, recipientApprover) || !token.hasRole(pxtAdmin, recipientApprover)) {
            revert RoleHandoffFailed();
        }
        if (token.hasRole(pxtApprover, address(this)) || token.hasRole(pxtAdmin, address(this))) {
            revert RoleHandoffFailed();
        }
        if (!fc.hasRole(fcBuyback, recipientApprover) || !fc.hasRole(fcAdmin, recipientApprover)) {
            revert RoleHandoffFailed();
        }
        if (fc.hasRole(fcBuyback, address(this)) || fc.hasRole(fcAdmin, address(this))) revert RoleHandoffFailed();
    }
}
