// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {V4Addresses} from "../src/uniswap/v4/V4Addresses.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

// Exact-in swap on the Anvil fork pool.
// Needs PXT_ADDRESS, QUOTE_TOKEN_ADDRESS, PHOENIX_HOOK, DIRECTION, AMOUNT_WHOLE.
// Buys mint mUSDC if the trader is short.
contract Swap is Script {
    using SafeCast for uint256;
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    int24 internal constant TICK_SPACING = 60;

    function run() external {
        uint256 key = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        address trader = vm.addr(key);

        address pxt = vm.envAddress("PXT_ADDRESS");
        address quote = vm.envAddress("QUOTE_TOKEN_ADDRESS");
        address hook = vm.envAddress("PHOENIX_HOOK");
        address swapTestAddr = vm.envOr("POOL_SWAP_TEST", V4Addresses.BASE_SEPOLIA_POOL_SWAP_TEST);
        uint24 lpFee = uint24(vm.envOr("POOL_FEE", uint256(0)));

        string memory direction = vm.envOr("DIRECTION", string("buy"));
        uint256 amountWhole = vm.envOr("AMOUNT_WHOLE", uint256(100));
        uint8 pxtDecimals = 6;
        uint8 quoteDecimals = uint8(vm.envOr("QUOTE_DECIMALS", uint256(6)));

        bool isBuy = _eq(direction, "buy");
        uint256 amountIn =
            isBuy ? amountWhole * (10 ** uint256(quoteDecimals)) : amountWhole * (10 ** uint256(pxtDecimals));

        PoolKey memory poolKey = _poolKey(pxt, quote, hook, lpFee);
        bool zeroForOne =
            isBuy ? Currency.unwrap(poolKey.currency0) == quote : Currency.unwrap(poolKey.currency0) == pxt;

        PoolSwapTest swapTest = PoolSwapTest(swapTestAddr);
        address tokenIn = isBuy ? quote : pxt;

        vm.startBroadcast(key);

        if (isBuy) {
            _ensureQuoteBalance(quote, trader, amountIn);
        } else {
            uint256 pxtBal = IERC20(pxt).balanceOf(trader);
            require(pxtBal >= amountIn, "Swap: insufficient PXT (distribute-pxt-anvil or use admin)");
        }

        IERC20(tokenIn).approve(address(swapTest), type(uint256).max);
        swapTest.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(trader)
        );
        vm.stopBroadcast();

        console2.log("Swap", direction, "amountIn", amountIn);
        console2.log("Trader", trader);
        console2.log("PXT balance", IERC20(pxt).balanceOf(trader));
        console2.log("Quote balance", IERC20(quote).balanceOf(trader));
    }

    /// @dev Bootstrap drains admin mUSDC into LP; mint more from MockERC20 for local buys.
    function _ensureQuoteBalance(address quote, address trader, uint256 amountIn) internal {
        uint256 bal = IERC20(quote).balanceOf(trader);
        if (bal >= amountIn) return;

        uint256 need = amountIn - bal;
        // Pad a little so follow-up buys don't fail immediately.
        uint256 mintAmount = need + amountIn;
        console2.log("Minting mUSDC for buy:", mintAmount);
        MockERC20(quote).mint(trader, mintAmount);
    }

    function _poolKey(address pxt, address quote, address hook, uint24 lpFee)
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
        key = PoolKey({currency0: c0, currency1: c1, fee: lpFee, tickSpacing: TICK_SPACING, hooks: IHooks(hook)});
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
