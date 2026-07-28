// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Pxt} from "../src/core/Pxt.sol";
import {PhoenixV4ReturnDeltaHook} from "../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {PhoenixFeeCollector} from "../src/fee/PhoenixFeeCollector.sol";

// Final lock ceremony (after config + LP seed):
// optional buyback params write, hand Pxt AccessControl roles to a multisig (recipient
// approver), then renounce Ownable on FeeCollector → Hook → Pxt.
// Collect / executeBuyback remain permissionless; setApprovedContractRecipient stays
// callable by RECIPIENT_APPROVER_ROLE.
// Requires non-zero maxBuybackSlippageBps (cash buyback only; seed LP is never peeled).
// Requires sellAttributor == hook (dump / rebate attribution path).
//
// Env: PXT_ADDRESS, PHOENIX_HOOK, FEE_COLLECTOR, PRIVATE_KEY
//      RECIPIENT_APPROVER — Safe/multisig that keeps DEFAULT_ADMIN_ROLE + RECIPIENT_APPROVER_ROLE
// Optional: BUYBACK_RECYCLE_WIDTH_SPACINGS, BUYBACK_MAX_SLIPPAGE_BPS
//           (if any is set, both are applied via setBuybackParams before renounce)
contract LockProtocolReturnDelta is Script {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    error NotOwner(address who, address expected);
    error PoolNotConfigured();
    error ZeroProtocolLiquidity();
    error SlippageNotConfigured();
    error CollectorNotLiquidityProvider();
    error HookMismatch();
    error AlreadyRenounced(address who);
    error RenounceFailed(address who);
    error RecipientApproverRequired();
    error RecipientApproverIsDeployer();
    error RoleHandoffFailed();
    error SellAttributorMustBeHook();
    error FeeWalletMismatch();
    error PoolManagerNotSet();
    error AntiBotSellerNotSet();
    error AntiBotSellerMismatch();

    function run() external {
        address pxtAddr = vm.envAddress("PXT_ADDRESS");
        address hookAddr = vm.envAddress("PHOENIX_HOOK");
        address collectorAddr = vm.envAddress("FEE_COLLECTOR");
        uint256 adminKey = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        address admin = vm.addr(adminKey);

        address recipientApprover = vm.envAddress("RECIPIENT_APPROVER");
        if (recipientApprover == address(0)) revert RecipientApproverRequired();
        if (recipientApprover == admin) revert RecipientApproverIsDeployer();

        Pxt pxt = Pxt(pxtAddr);
        PhoenixV4ReturnDeltaHook hook = PhoenixV4ReturnDeltaHook(hookAddr);
        PhoenixFeeCollector collector = PhoenixFeeCollector(collectorAddr);

        _requireOwner(address(pxt), pxt.owner(), admin);
        _requireOwner(address(hook), hook.owner(), admin);
        _requireOwner(address(collector), collector.owner(), admin);

        if (!collector.poolConfigured()) revert PoolNotConfigured();
        if (address(collector.hook()) != hookAddr) revert HookMismatch();
        if (address(hook.feeCollector()) != collectorAddr) revert HookMismatch();
        if (!hook.liquidityProvider(collectorAddr)) revert CollectorNotLiquidityProvider();
        requireSellAttributorIsHook(pxt, hookAddr);
        requireMatchingFeeWallets(pxt, collector);
        if (pxt.poolManager() == address(0)) revert PoolManagerNotSet();
        if (pxt.antiBotSeller() == address(0)) revert AntiBotSellerNotSet();
        if (vm.envExists("ANTI_BOT_OPEN_SELL")) {
            address openSell = vm.envAddress("ANTI_BOT_OPEN_SELL");
            if (pxt.antiBotSeller() != openSell) revert AntiBotSellerMismatch();
        }

        (, uint128 positionLiq) = collector.quoteBuyback();
        if (positionLiq == 0) revert ZeroProtocolLiquidity();

        bool setParams = vm.envExists("BUYBACK_RECYCLE_WIDTH_SPACINGS") || vm.envExists("BUYBACK_MAX_SLIPPAGE_BPS");

        console2.log("=== LockProtocolReturnDelta (pre) ===");
        console2.log("Admin:", admin);
        console2.log("RecipientApprover (multisig):", recipientApprover);
        console2.log("PXT:", pxtAddr);
        console2.log("Hook:", hookAddr);
        console2.log("FeeCollector:", collectorAddr);
        console2.log("positionLiquidity:", positionLiq);
        console2.log("recycleWidthSpacings:", collector.recycleWidthSpacings());
        console2.log("maxBuybackSlippageBps:", collector.maxBuybackSlippageBps());

        vm.startBroadcast(adminKey);

        if (setParams) {
            uint24 recycleWidth =
                uint24(vm.envOr("BUYBACK_RECYCLE_WIDTH_SPACINGS", uint256(collector.recycleWidthSpacings())));
            uint16 buybackSlip =
                uint16(vm.envOr("BUYBACK_MAX_SLIPPAGE_BPS", uint256(collector.maxBuybackSlippageBps())));
            collector.setBuybackParams(recycleWidth, buybackSlip);
            console2.log("Updated buyback params");
            console2.log("  recycleWidthSpacings:", recycleWidth);
            console2.log("  maxBuybackSlippageBps:", buybackSlip);
        }

        if (collector.maxBuybackSlippageBps() == 0) revert SlippageNotConfigured();

        bytes32 adminRole = pxt.DEFAULT_ADMIN_ROLE();
        bytes32 approverRole = pxt.RECIPIENT_APPROVER_ROLE();
        pxt.grantRole(approverRole, recipientApprover);
        pxt.grantRole(adminRole, recipientApprover);
        pxt.revokeRole(approverRole, admin);
        pxt.renounceRole(adminRole, admin);

        collector.renounceOwnership();
        hook.renounceOwnership();
        pxt.renounceOwnership();

        vm.stopBroadcast();

        if (collector.owner() != address(0)) revert RenounceFailed(collectorAddr);
        if (hook.owner() != address(0)) revert RenounceFailed(hookAddr);
        if (pxt.owner() != address(0)) revert RenounceFailed(pxtAddr);
        if (!pxt.hasRole(approverRole, recipientApprover)) revert RoleHandoffFailed();
        if (!pxt.hasRole(adminRole, recipientApprover)) revert RoleHandoffFailed();
        if (pxt.hasRole(approverRole, admin) || pxt.hasRole(adminRole, admin)) revert RoleHandoffFailed();

        console2.log("=== LockProtocolReturnDelta complete ===");
        console2.log("FeeCollector owner:", collector.owner());
        console2.log("Hook owner:", hook.owner());
        console2.log("PXT owner:", pxt.owner());
        console2.log("PXT DEFAULT_ADMIN_ROLE:", recipientApprover);
        console2.log("PXT RECIPIENT_APPROVER_ROLE:", recipientApprover);
        console2.log("sellAttributor (hook):", address(pxt.sellAttributor()));
        console2.log("positionLiquidity (unchanged holder):", positionLiq);
        console2.log("maxBuybackSlippageBps (frozen):", collector.maxBuybackSlippageBps());
        console2.log("Public LP allowed after sell unlock; FeeCollector remains allowlisted for recycle");
        console2.log("collect / executeBuyback remain permissionless");
        console2.log("setApprovedContractRecipient remains on RECIPIENT_APPROVER_ROLE");
    }

    /// @notice ReturnDelta must keep the hook as sellAttributor for dump rebate / window.
    function requireSellAttributorIsHook(Pxt pxt, address hookAddr) public view {
        if (address(pxt.sellAttributor()) != hookAddr) revert SellAttributorMustBeHook();
    }

    /// @notice Transfer-tax and USDC-skim fee wallets must be the same addresses.
    function requireMatchingFeeWallets(Pxt pxt, PhoenixFeeCollector collector) public view {
        if (pxt.DONATION_WALLET() != collector.donationWallet()) revert FeeWalletMismatch();
        if (pxt.MARKETING_WALLET() != collector.marketingWallet()) revert FeeWalletMismatch();
    }

    function _requireOwner(address who, address actual, address expected) internal pure {
        if (actual == address(0)) revert AlreadyRenounced(who);
        if (actual != expected) revert NotOwner(who, expected);
    }
}
