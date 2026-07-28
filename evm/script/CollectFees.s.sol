// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PhoenixFeeCollector} from "../src/fee/PhoenixFeeCollector.sol";

// Call collect() on the fee collector. Needs FEE_COLLECTOR.
contract CollectFees is Script {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        uint256 key = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        address collectorAddr = vm.envAddress("FEE_COLLECTOR");
        PhoenixFeeCollector collector = PhoenixFeeCollector(collectorAddr);

        vm.startBroadcast(key);
        (uint256 pulled0, uint256 pulled1) = collector.collect();
        vm.stopBroadcast();

        console2.log("CollectFees pulled0", pulled0);
        console2.log("CollectFees pulled1", pulled1);
        console2.log("Caller", vm.addr(key));
    }
}
