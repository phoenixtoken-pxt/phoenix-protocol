// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Pxt} from "../src/core/Pxt.sol";
import {PhoenixV4ReturnDeltaHook} from "../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {PhoenixFeeCollector} from "../src/fee/PhoenixFeeCollector.sol";
import {V4Addresses} from "../src/uniswap/v4/V4Addresses.sol";

// Dump spot / pending fees / buyback quote. Read-only.
contract StatusAnvil is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 internal constant TICK_SPACING = 60;

    function run() external view {
        address pxtAddr = vm.envAddress("PXT_ADDRESS");
        address quote = vm.envAddress("QUOTE_TOKEN_ADDRESS");
        address hookAddr = vm.envAddress("PHOENIX_HOOK");
        address collectorAddr = vm.envAddress("FEE_COLLECTOR");
        address pmAddr = vm.envOr("POOL_MANAGER", V4Addresses.BASE_SEPOLIA_POOL_MANAGER);
        uint24 poolFee = uint24(vm.envOr("POOL_FEE", uint256(0)));

        Pxt pxt = Pxt(pxtAddr);
        PhoenixV4ReturnDeltaHook hook = PhoenixV4ReturnDeltaHook(hookAddr);
        PhoenixFeeCollector collector = PhoenixFeeCollector(collectorAddr);
        IPoolManager pm = IPoolManager(pmAddr);

        PoolKey memory key = _poolKey(pxtAddr, quote, hookAddr, poolFee);
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = pm.getSlot0(key.toId());

        (uint256 donPxt, uint256 mktPxt, uint256 burnPxt, uint256 bbPxt) = collector.pending(pxtAddr);
        (uint256 donQ, uint256 mktQ, uint256 burnQ, uint256 bbQ) = collector.pending(quote);
        (uint256 usdcSpendable, uint128 positionLiq) = collector.quoteBuyback();

        console2.log("=== Anvil status ===");
        console2.log("block.timestamp", block.timestamp);
        console2.log("sellUnlockTimestamp", pxt.sellUnlockTimestamp());
        console2.log("sellProtectionCleared", hook.sellProtectionCleared());
        console2.log("antiBotSeller", hook.antiBotSeller());
        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("tick", tick);
        console2.log("storedLpFee", lpFee);
        console2.log("spot quote-per-PXT (1e18 scale)", _spotQuotePerPxt1e18(sqrtPriceX96, pxtAddr, key));
        console2.log("--- pending PXT ---");
        console2.log("donation", donPxt);
        console2.log("marketing", mktPxt);
        console2.log("burn", burnPxt);
        console2.log("buyback", bbPxt);
        console2.log("--- pending quote ---");
        console2.log("donation", donQ);
        console2.log("marketing", mktQ);
        console2.log("burn", burnQ);
        console2.log("buyback", bbQ);
        console2.log("--- buyback ---");
        console2.log("recycleWidthSpacings", collector.recycleWidthSpacings());
        console2.log("maxBuybackSlippageBps", collector.maxBuybackSlippageBps());
        console2.log("frozenSqrtPriceX96", collector.frozenSqrtPriceX96());
        console2.log("pendingSqrtPriceX96", collector.pendingSqrtPriceX96());
        console2.log("pendingSpotBlock", collector.pendingSpotBlock());
        console2.log("positionLiquidity", positionLiq);
        console2.log("quoteBuyback usdcSpendable", usdcSpendable);
        console2.log("seedLiquidityAdded", collector.seedLiquidityAdded());
        console2.log("recyclePxt", collector.recyclePxt());
        console2.log("lastRecycleTickLower", collector.lastRecycleTickLower());
        console2.log("lastRecycleTickUpper", collector.lastRecycleTickUpper());
        console2.log("lastRecycleLiquidity", collector.lastRecycleLiquidity());
        console2.log("collector PXT bal", IERC20(pxtAddr).balanceOf(collectorAddr));
        console2.log("collector quote bal", IERC20(quote).balanceOf(collectorAddr));
        console2.log("PXT totalSupply", pxt.totalSupply());
    }

    function _poolKey(address pxt, address quote, address hook, uint24 poolFee)
        internal
        pure
        returns (PoolKey memory key)
    {
        Currency c0;
        Currency c1;
        if (pxt < quote) {
            c0 = Currency.wrap(pxt);
            c1 = Currency.wrap(quote);
        } else {
            c0 = Currency.wrap(quote);
            c1 = Currency.wrap(pxt);
        }
        key = PoolKey({currency0: c0, currency1: c1, fee: poolFee, tickSpacing: TICK_SPACING, hooks: IHooks(hook)});
    }

    /// @dev Approximate quote per 1 PXT, scaled by 1e18.
    function _spotQuotePerPxt1e18(uint160 sqrtPriceX96, address pxt, PoolKey memory key)
        internal
        pure
        returns (uint256)
    {
        uint256 p1Per0 = FullMath.mulDiv(
            FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96), 1e18, FixedPoint96.Q96
        );
        bool pxtIsToken0 = Currency.unwrap(key.currency0) == pxt;
        if (pxtIsToken0) return p1Per0;
        if (p1Per0 == 0) return 0;
        return FullMath.mulDiv(1e18, 1e18, p1Per0);
    }
}
