// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {PxtFeeModel} from "../core/PxtFeeModel.sol";

/// @notice Pure math for cash USDC buyback sizing, slippage limits, and recycle tick bands.
library PhoenixBuybackMath {
    error Slippage();
    error RecycleRangeInvalid();

    /// @dev PXT notional equal to `quoteAmount` USDC at the given sqrt price.
    function pxtForQuote(uint256 quoteAmount, uint160 sqrtPriceX96, bool pxtIsToken0)
        internal
        pure
        returns (uint256 pxtAmount)
    {
        if (quoteAmount == 0 || sqrtPriceX96 == 0) return 0;
        if (pxtIsToken0) {
            pxtAmount = FullMath.mulDiv(quoteAmount, FixedPoint96.Q96, sqrtPriceX96);
            pxtAmount = FullMath.mulDiv(pxtAmount, FixedPoint96.Q96, sqrtPriceX96);
        } else {
            pxtAmount = FullMath.mulDiv(
                quoteAmount, FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96), FixedPoint96.Q96
            );
        }
    }

    /// @dev Require `actual >= max(callerMin, expected * (BPS - slippageBps) / BPS)`.
    function enforceMinOut(uint256 actual, uint256 callerMin, uint256 expected, uint16 slippageBps) internal pure {
        if (actual < callerMin) revert Slippage();
        if (expected == 0) {
            if (actual == 0) revert Slippage();
            return;
        }
        uint256 protocolMin = FullMath.mulDiv(expected, PxtFeeModel.BPS - slippageBps, PxtFeeModel.BPS);
        if (actual < protocolMin) revert Slippage();
    }

    /// @dev Bound swap execution: zeroForOne → price falls; else price rises. Limit = spot ± slippage.
    function sqrtPriceLimitAfterSlippage(uint160 sqrtPriceX96, bool zeroForOne, uint16 slippageBps)
        internal
        pure
        returns (uint160)
    {
        if (slippageBps == 0 || slippageBps >= PxtFeeModel.BPS) {
            return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        uint256 bps = PxtFeeModel.BPS;
        uint256 factor = zeroForOne ? (bps - slippageBps) : (bps + slippageBps);
        // sqrtPriceLimit ≈ sqrtPrice * sqrt(factor) / sqrt(BPS)
        uint256 scaled = Math.mulDiv(uint256(sqrtPriceX96), Math.sqrt(factor * 1e18), Math.sqrt(bps * 1e18));
        if (scaled <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (scaled >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        // casting to uint160 is safe: scaled is clamped to (MIN_SQRT_PRICE, MAX_SQRT_PRICE)
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(scaled);
    }

    function floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    /// @dev PXT-only band above economic spot (higher USDC/PXT).
    function recycleTicks(int24 tick, int24 spacing, uint24 recycleWidthSpacings, bool pxtIsToken0)
        internal
        pure
        returns (int24 lo, int24 hi)
    {
        // casting to int24 is safe: recycleWidthSpacings is small and width stays in tick bounds
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 width = int24(uint24(recycleWidthSpacings)) * spacing;
        int24 floor = floorToSpacing(tick, spacing);
        if (pxtIsToken0) {
            lo = floor + spacing;
            hi = lo + width;
        } else {
            hi = floor;
            lo = hi - width;
        }

        int24 minU = TickMath.minUsableTick(spacing);
        int24 maxU = TickMath.maxUsableTick(spacing);
        if (lo < minU) lo = minU;
        if (hi > maxU) hi = maxU;
        if (lo >= hi) revert RecycleRangeInvalid();
    }

    /// @dev True when `[lo, hi)` is entirely on the PXT side of `tick` (single-sided PXT LP).
    function isPxtOnlyBand(int24 tick, int24 lo, int24 hi, bool pxtIsToken0) internal pure returns (bool) {
        if (lo >= hi) return false;
        if (pxtIsToken0) {
            // amount0-only when current price is below the range
            return tick < lo;
        }
        // amount1-only when current price is at or above the range
        return tick >= hi;
    }
}
