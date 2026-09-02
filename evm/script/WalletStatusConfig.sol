// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Pxt} from "../src/core/Pxt.sol";
import {PhoenixFeeCollector} from "../src/fee/PhoenixFeeCollector.sol";

/// @dev Shared env parsing for FeeExempt / NoPenalty wallet lists.
/// Env (comma-separated, optional):
///   FEE_EXEMPT_WALLETS=0x...,0x...
///   NO_PENALTY_WALLETS=0x...,0x...
/// Legacy single: NO_PENALTY_WALLET=0x... (used when NO_PENALTY_WALLETS is unset).
///   BUYBACK_CALLERS=0x...,0x... (optional authorized executeBuyback callers)
abstract contract WalletStatusConfig is Script {
    uint256 internal constant WALLET_STATUS_ANVIL_KEY_3 =
        0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    /// @param defaultAnvilNoPenalty If true and no NoPenalty env is set, tag Anvil #3 (local demo).
    /// @return firstNoPenalty First NoPenalty address applied (address(0) if none).
    function _applyWalletStatusesFromEnv(Pxt pxt, bool defaultAnvilNoPenalty)
        internal
        returns (address firstNoPenalty)
    {
        _applyStatusList(pxt, "FEE_EXEMPT_WALLETS", Pxt.WalletStatus.FeeExempt);

        address[] memory noPenalty = _noPenaltyWallets(defaultAnvilNoPenalty);
        for (uint256 i = 0; i < noPenalty.length; ++i) {
            address w = noPenalty[i];
            if (w == address(0)) continue;
            pxt.setWalletStatus(w, Pxt.WalletStatus.NoPenalty);
            console2.log("NoPenalty:", w);
            if (firstNoPenalty == address(0)) firstNoPenalty = w;
        }
    }

    /// @dev Env (comma-separated, optional): BUYBACK_CALLERS=0x...,0x...
    ///      Skips `exclude` (typically the deployer) so lock can require a non-admin keeper.
    function _applyBuybackCallersFromEnv(PhoenixFeeCollector collector, address exclude)
        internal
        returns (uint256 applied)
    {
        if (!vm.envExists("BUYBACK_CALLERS")) return 0;
        address[] memory callers = vm.envAddress("BUYBACK_CALLERS", ",");
        for (uint256 i = 0; i < callers.length; ++i) {
            address w = callers[i];
            if (w == address(0) || w == exclude) continue;
            collector.setAuthorizedBuybackCaller(w, true);
            console2.log("AuthorizedBuybackCaller:", w);
            unchecked {
                ++applied;
            }
        }
    }

    function _applyStatusList(Pxt pxt, string memory envKey, Pxt.WalletStatus status) internal {
        if (!vm.envExists(envKey)) return;
        // Empty string → empty array (forge-std).
        address[] memory wallets = vm.envAddress(envKey, ",");
        for (uint256 i = 0; i < wallets.length; ++i) {
            address w = wallets[i];
            if (w == address(0)) continue;
            pxt.setWalletStatus(w, status);
            if (status == Pxt.WalletStatus.FeeExempt) {
                console2.log("FeeExempt:", w);
            } else if (status == Pxt.WalletStatus.NoPenalty) {
                console2.log("NoPenalty:", w);
            }
        }
    }

    function _noPenaltyWallets(bool defaultAnvilNoPenalty) internal view returns (address[] memory wallets) {
        if (vm.envExists("NO_PENALTY_WALLETS")) {
            return vm.envAddress("NO_PENALTY_WALLETS", ",");
        }
        if (vm.envExists("NO_PENALTY_WALLET")) {
            wallets = new address[](1);
            wallets[0] = vm.envAddress("NO_PENALTY_WALLET");
            return wallets;
        }
        if (defaultAnvilNoPenalty) {
            wallets = new address[](1);
            wallets[0] = vm.addr(WALLET_STATUS_ANVIL_KEY_3);
            return wallets;
        }
        return new address[](0);
    }
}
