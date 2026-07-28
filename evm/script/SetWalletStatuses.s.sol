// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {Pxt} from "../src/core/Pxt.sol";
import {WalletStatusConfig} from "./WalletStatusConfig.sol";

// Apply FeeExempt / NoPenalty wallet lists before Ownable renounce (make lock-anvil).
// Env: PXT_ADDRESS, PRIVATE_KEY
//      FEE_EXEMPT_WALLETS (comma-separated, optional)
//      NO_PENALTY_WALLETS (comma-separated, optional)
//      NO_PENALTY_WALLET (optional legacy single address if NO_PENALTY_WALLETS unset)
//
// Does not default Anvil #3 — set lists in .env explicitly for this script.
contract SetWalletStatuses is WalletStatusConfig {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    error NotOwner(address actual, address expected);
    error AlreadyRenounced();

    function run() external {
        address pxtAddr = vm.envAddress("PXT_ADDRESS");
        uint256 adminKey = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        address admin = vm.addr(adminKey);

        Pxt pxt = Pxt(pxtAddr);
        address owner = pxt.owner();
        if (owner == address(0)) revert AlreadyRenounced();
        if (owner != admin) revert NotOwner(owner, admin);

        bool hasExempt = vm.envExists("FEE_EXEMPT_WALLETS");
        bool hasNoPen = vm.envExists("NO_PENALTY_WALLETS") || vm.envExists("NO_PENALTY_WALLET");
        if (!hasExempt && !hasNoPen) {
            console2.log("No FEE_EXEMPT_WALLETS / NO_PENALTY_WALLETS / NO_PENALTY_WALLET set - nothing to do");
            return;
        }

        console2.log("=== SetWalletStatuses ===");
        console2.log("PXT:", pxtAddr);
        console2.log("Owner:", admin);

        vm.startBroadcast(adminKey);
        _applyWalletStatusesFromEnv(pxt, false);
        vm.stopBroadcast();

        console2.log("=== SetWalletStatuses complete (run before make lock-anvil) ===");
    }
}
