// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

// Mint mock USDC (or whatever) to testers.
// Env: TOKEN_ADDRESS, PRIVATE_KEY, RECIPIENTS, AMOUNT_WHOLE, FUND_ETH.
contract MintMockToken is Script {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant TESTER_ETH = 1 ether;

    function run() external {
        MockERC20 token = MockERC20(vm.envAddress("TOKEN_ADDRESS"));
        uint256 ownerKey = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        address[] memory recipients = vm.envAddress("RECIPIENTS", ",");
        uint256 unit = 10 ** uint256(token.decimals());
        uint256 amount = vm.envOr("AMOUNT_WHOLE", uint256(10_000)) * unit;
        bool fundEth = vm.envOr("FUND_ETH", true);

        vm.startBroadcast(ownerKey);
        for (uint256 i = 0; i < recipients.length; i++) {
            if (fundEth) {
                vm.deal(recipients[i], TESTER_ETH);
            }
            token.mint(recipients[i], amount);
            console2.log("Minted to:", recipients[i]);
            console2.log("  token balance:", token.balanceOf(recipients[i]));
            console2.log("  ETH balance:", recipients[i].balance);
        }
        vm.stopBroadcast();
    }
}
