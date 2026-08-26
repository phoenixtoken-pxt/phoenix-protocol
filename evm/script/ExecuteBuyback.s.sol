// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PhoenixFeeCollector} from "../src/fee/PhoenixFeeCollector.sol";

// Kick executeBuyback on the fork. Caller must be isAuthorizedBuybackCaller.
// FEE_COLLECTOR required; MIN_PXT_BOUGHT / DEADLINE_SECONDS optional.
// After lock, use the keeper PRIVATE_KEY (not the deployer).
// Prefer a non-zero MIN_PXT_BOUGHT (keeper quote); protocol maxBuybackSlippageBps is vs previous-block spot.
// After large same-block flow, wait one block so frozenSqrtPriceX96 has been promoted.
contract ExecuteBuyback is Script {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        uint256 key = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        address collectorAddr = vm.envAddress("FEE_COLLECTOR");
        PhoenixFeeCollector collector = PhoenixFeeCollector(collectorAddr);

        uint256 usdcAmount = vm.envOr("USDC_AMOUNT", uint256(0));
        uint256 minPxtBought = vm.envOr("MIN_PXT_BOUGHT", uint256(0));
        uint256 deadlineSeconds = vm.envOr("DEADLINE_SECONDS", uint256(600));
        uint256 deadline = block.timestamp + deadlineSeconds;

        (uint256 usdcSpendable, uint128 positionLiq) = collector.quoteBuyback();
        console2.log("quoteBuyback usdcSpendable", usdcSpendable);
        console2.log("quoteBuyback positionLiquidity", positionLiq);

        vm.startBroadcast(key);
        (uint256 usdcSpent, uint256 pxtBought) = collector.executeBuyback(usdcAmount, minPxtBought, deadline);
        vm.stopBroadcast();

        console2.log("ExecuteBuyback usdcSpent", usdcSpent);
        console2.log("ExecuteBuyback pxtBought", pxtBought);
        console2.log("ExecuteBuyback recyclePxt", collector.recyclePxt());
        console2.log("Caller", vm.addr(key));
    }
}
