// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Pxt} from "../src/core/Pxt.sol";

// Send PXT from admin to testers. Recipients that are not FeeExempt/NoPenalty pay the 2.7%
// transfer tax (recipient-based), so net received is 97.3% of the sent amount.
// Env: PXT_ADDRESS, PRIVATE_KEY, RECIPIENTS, AMOUNT_WHOLE, FUND_ETH.
contract Distribute is Script {
    uint256 internal constant WHOLE = 1_000_000;
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant TESTER_ETH = 1 ether;

    function run() external {
        address token = vm.envAddress("PXT_ADDRESS");
        uint256 adminKey = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        address[] memory recipients = vm.envAddress("RECIPIENTS", ",");
        uint256 amountWhole = vm.envOr("AMOUNT_WHOLE", uint256(1_000));
        uint256 amount = amountWhole * WHOLE;
        bool fundEth = vm.envOr("FUND_ETH", true);

        Pxt pxt = Pxt(token);
        address admin = vm.addr(adminKey);

        console2.log("Admin:", admin);
        console2.log("Admin balance before:", pxt.balanceOf(admin));
        console2.log("Per-recipient amount (base units):", amount);

        vm.startBroadcast(adminKey);
        for (uint256 i = 0; i < recipients.length; i++) {
            if (fundEth) {
                vm.deal(recipients[i], TESTER_ETH);
            }
            pxt.transfer(recipients[i], amount);
            console2.log("Sent to:", recipients[i]);
            console2.log("  recipient PXT:", pxt.balanceOf(recipients[i]));
            console2.log("  recipient ETH:", recipients[i].balance);
        }
        vm.stopBroadcast();

        console2.log("Admin balance after:", pxt.balanceOf(admin));
    }
}
