// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PhoenixLaunchTypes} from "./PhoenixLaunchTypes.sol";

/// @notice Pool key, token order, and sqrtPriceX96 helpers for the launch ceremony.
library PhoenixLaunchMath {
    error ZeroAmount();
    error SqrtOverflow();

    function poolKey(address pxt, address quote, address hook) internal pure returns (PoolKey memory key) {
        Currency c0;
        Currency c1;
        if (pxt < quote) {
            c0 = Currency.wrap(pxt);
            c1 = Currency.wrap(quote);
        } else {
            c0 = Currency.wrap(quote);
            c1 = Currency.wrap(pxt);
        }
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: PhoenixLaunchTypes.LP_FEE,
            tickSpacing: PhoenixLaunchTypes.TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    function orderedAmounts(PoolKey memory key, address pxt, uint256 pxtAmt, uint256 usdcAmt)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (Currency.unwrap(key.currency0) == pxt) {
            return (pxtAmt, usdcAmt);
        }
        return (usdcAmt, pxtAmt);
    }

    function sqrtPriceForSpot(address pxt, address quote, uint256 pxtAmt, uint256 usdcAmt)
        internal
        pure
        returns (uint160)
    {
        uint256 amount0;
        uint256 amount1;
        if (pxt < quote) {
            amount0 = pxtAmt;
            amount1 = usdcAmt;
        } else {
            amount0 = usdcAmt;
            amount1 = pxtAmt;
        }
        return encodeSqrtRatioX96(amount1, amount0);
    }

    function encodeSqrtRatioX96(uint256 amount1, uint256 amount0) internal pure returns (uint160) {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
        uint256 ratioX192 = (amount1 << 192) / amount0;
        uint256 sqrtX96 = _sqrt(ratioX192);
        if (sqrtX96 > type(uint160).max) revert SqrtOverflow();
        return uint160(sqrtX96);
    }

    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        uint256 xx = x;
        uint256 r = 1;
        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x8) r <<= 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        uint256 r1 = x / r;
        return r < r1 ? r : r1;
    }
}
