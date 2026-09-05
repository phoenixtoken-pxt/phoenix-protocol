// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Pxt} from "../../src/core/Pxt.sol";
import {PhoenixFeeCollector} from "../../src/fee/PhoenixFeeCollector.sol";
import {PhoenixV4ReturnDeltaHook} from "../../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {PhoenixAntiBotOpenSell} from "../PhoenixAntiBotOpenSell.sol";
import {PhoenixLaunchMath} from "./PhoenixLaunchMath.sol";
import {PhoenixLaunchTypes} from "./PhoenixLaunchTypes.sol";

/// @notice Admin-signed bootstrap helpers (msg.sender must be Ownable admin on Pxt/hook/collector).
///         Used by forge scripts and tests — not by the orchestrator (admin owns, not the orch).
abstract contract PhoenixLaunchActions {
    using SafeERC20 for IERC20;

    error LiquidityBelowMin();
    error RecipientApproverRequired();
    error RecipientApproverIsOwner();
    error BuybackCallerRequired();
    error RoleHandoffFailed();
    error RenounceFailed();
    error DeployerStillBuybackCaller();
    error ZeroProtocolLiquidity();
    error PoolNotConfigured();
    error HookMismatch();
    error SellAttributorMustBeHook();
    error FeeWalletMismatch();
    error FeeCollectorMismatch();
    error PoolManagerNotSet();
    error AntiBotSellerNotSet();
    error SlippageNotConfigured();

    /// @dev Wire allowlists / statuses, set official pool, initialize spot, configure FeeCollector.
    function _configureAndInit(
        PhoenixLaunchTypes.LaunchParams memory p,
        Pxt token,
        PhoenixV4ReturnDeltaHook h,
        PhoenixFeeCollector fc,
        PhoenixAntiBotOpenSell os,
        address launchOwner,
        int24 lo,
        int24 hi
    ) internal returns (uint160 sqrtPriceX96) {
        address operator = p.operator == address(0) ? launchOwner : p.operator;

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

    /// @dev Owner of FeeCollector calls addLiquidity; pulls PXT+USDC from msg.sender.
    function _seedAsOwner(
        Pxt token,
        PhoenixFeeCollector fc,
        address quote,
        uint256 pxtAmt,
        uint256 usdcAmt,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 minLiquidity
    ) internal returns (uint128 liquidity) {
        PoolKey memory key = PhoenixLaunchMath.poolKey(address(token), quote, address(fc.hook()));
        (uint256 amount0, uint256 amount1) = PhoenixLaunchMath.orderedAmounts(key, address(token), pxtAmt, usdcAmt);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        if (liquidity == 0 || liquidity < minLiquidity) revert LiquidityBelowMin();

        IERC20(address(token)).forceApprove(address(fc), pxtAmt);
        IERC20(quote).forceApprove(address(fc), usdcAmt);
        fc.addLiquidity(amount0, amount1, liquidity, abi.encode(address(fc)));
    }

    function _lockAsOwner(
        Pxt token,
        PhoenixV4ReturnDeltaHook h,
        PhoenixFeeCollector fc,
        address launchOwner,
        address recipientApprover,
        address[] memory buybackCallers
    ) internal {
        _requireLockReady(token, h, fc, launchOwner, recipientApprover);
        _handoffRoles(token, fc, launchOwner, recipientApprover, buybackCallers);

        fc.renounceOwnership();
        h.renounceOwnership();
        token.renounceOwnership();

        if (fc.owner() != address(0) || h.owner() != address(0) || token.owner() != address(0)) {
            revert RenounceFailed();
        }
    }

    function _allowlist(Pxt token, address who) private {
        if (who == address(0)) return;
        token.setApprovedContractRecipient(who, true);
    }

    function _applyStatuses(Pxt token, address[] memory wallets, Pxt.WalletStatus status) private {
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
        address launchOwner,
        address recipientApprover
    ) private view {
        if (recipientApprover == address(0)) revert RecipientApproverRequired();
        if (recipientApprover == launchOwner) revert RecipientApproverIsOwner();
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
        address launchOwner,
        address recipientApprover,
        address[] memory buybackCallers
    ) private {
        bytes32 pxtAdmin = token.DEFAULT_ADMIN_ROLE();
        bytes32 pxtApprover = token.RECIPIENT_APPROVER_ROLE();
        token.grantRole(pxtApprover, recipientApprover);
        token.grantRole(pxtAdmin, recipientApprover);
        token.revokeRole(pxtApprover, launchOwner);
        token.renounceRole(pxtAdmin, launchOwner);

        bytes32 fcAdmin = fc.DEFAULT_ADMIN_ROLE();
        bytes32 fcBuyback = fc.BUYBACK_EXECUTOR_APPROVER_ROLE();
        fc.grantRole(fcBuyback, recipientApprover);
        fc.grantRole(fcAdmin, recipientApprover);

        uint256 applied;
        for (uint256 i; i < buybackCallers.length; ++i) {
            address w = buybackCallers[i];
            if (w == address(0) || w == launchOwner) continue;
            fc.setAuthorizedBuybackCaller(w, true);
            unchecked {
                ++applied;
            }
        }
        if (applied == 0) revert BuybackCallerRequired();
        if (fc.isAuthorizedBuybackCaller(launchOwner)) {
            fc.setAuthorizedBuybackCaller(launchOwner, false);
        }

        fc.revokeRole(fcBuyback, launchOwner);
        fc.renounceRole(fcAdmin, launchOwner);

        if (!token.hasRole(pxtApprover, recipientApprover) || !token.hasRole(pxtAdmin, recipientApprover)) {
            revert RoleHandoffFailed();
        }
        if (token.hasRole(pxtApprover, launchOwner) || token.hasRole(pxtAdmin, launchOwner)) {
            revert RoleHandoffFailed();
        }
        if (!fc.hasRole(fcBuyback, recipientApprover) || !fc.hasRole(fcAdmin, recipientApprover)) {
            revert RoleHandoffFailed();
        }
        if (fc.hasRole(fcBuyback, launchOwner) || fc.hasRole(fcAdmin, launchOwner)) revert RoleHandoffFailed();
    }
}
