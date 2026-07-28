// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {Pxt} from "../src/core/Pxt.sol";
import {PhoenixAntiBotOpenSell} from "./PhoenixAntiBotOpenSell.sol";

// Atomic anti-bot open: clearSellProtection + operator exact-in sell in one tx.
// Env: PXT_ADDRESS, QUOTE_TOKEN_ADDRESS, PHOENIX_HOOK, ANTI_BOT_OPEN_SELL,
//      PRIVATE_KEY (= openSell.operator()), AMOUNT_WHOLE (default 100).
// On-chain antiBotSeller is the openSell helper; operator is the EOA that calls it.
contract OpenTrading is Script {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    int24 internal constant TICK_SPACING = 60;

    function run() external {
        uint256 key = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        address seller = vm.addr(key);

        Pxt pxt = Pxt(vm.envAddress("PXT_ADDRESS"));
        address quote = vm.envAddress("QUOTE_TOKEN_ADDRESS");
        address hook = vm.envAddress("PHOENIX_HOOK");
        uint24 lpFee = uint24(vm.envOr("POOL_FEE", uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG)));
        uint256 amountWhole = vm.envOr("AMOUNT_WHOLE", uint256(100));
        uint256 amountIn = amountWhole * (10 ** uint256(pxt.decimals()));

        address openSellAddr = vm.envAddress("ANTI_BOT_OPEN_SELL");
        require(openSellAddr != address(0), "OpenTrading: set ANTI_BOT_OPEN_SELL");
        PhoenixAntiBotOpenSell openSell = PhoenixAntiBotOpenSell(openSellAddr);
        require(seller == openSell.operator(), "OpenTrading: PRIVATE_KEY must be openSell.operator()");
        require(pxt.antiBotSeller() == openSellAddr, "OpenTrading: antiBotSeller must be openSell");
        require(block.timestamp >= pxt.sellUnlockTimestamp(), "OpenTrading: warp past sell unlock first");

        PoolKey memory poolKey = _poolKey(address(pxt), quote, hook, lpFee);

        vm.startBroadcast(key);
        IERC20(address(pxt)).approve(openSellAddr, amountIn);
        openSell.openWithExactInSell(poolKey, amountIn, bytes(""));
        vm.stopBroadcast();

        console2.log("Opened trading via atomic clear+sell");
        console2.log("Operator", seller);
        console2.log("AmountIn", amountIn);
        console2.log("sellProtectionCleared", pxt.sellProtectionCleared());
        console2.log("PXT balance", IERC20(address(pxt)).balanceOf(seller));
        console2.log("Quote balance", IERC20(quote).balanceOf(seller));
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
}
