// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pxt} from "../src/core/Pxt.sol";
import {
    DEFAULT_SELL_UNLOCK_TIMESTAMP,
    FeeBreakdown,
    FeeKind,
    SellsLocked,
    AntiBotSellBlocked,
    ZeroAddress
} from "../src/core/PxtFeeModel.sol";
import {ISellAttributor} from "../src/return-delta/ISellAttributor.sol";

contract MockPool {}

contract MockAttributorNoSettle is ISellAttributor {
    function attributeSell(address, uint256) external {}

    function creditFromPoolManager(address, uint256) external {}

    function pendingDexSellAmount() external pure returns (uint256) {
        return 0;
    }

    function consumeLpInbound(uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev Stand-in for FeeCollector owner() in CCIB seed-refund tests.
contract MockFeeCollectorShell {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

contract PxtTest is Test {
    using stdStorage for StdStorage;

    Pxt internal pxt;

    address internal admin = makeAddr("admin");
    address internal donation = makeAddr("donation");
    address internal marketing = makeAddr("marketing");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockPool internal pool;

    uint256 internal constant WHOLE = 1_000_000;
    uint256 internal constant ONE = 1 * WHOLE;

    function setUp() public {
        pool = new MockPool();

        vm.startPrank(admin);
        pxt = new Pxt(admin, donation, marketing, block.timestamp + 30 days);
        // Seed alice with an exact balance (recipient FeeExempt skips transfer tax).
        pxt.setWalletStatus(alice, Pxt.WalletStatus.FeeExempt);
        pxt.transfer(alice, 10_000 * ONE);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.Normal);
        vm.stopPrank();
    }

    function test_metadata_and_supply() public view {
        assertEq(pxt.name(), "Phoenix Token");
        assertEq(pxt.symbol(), "PXT");
        assertEq(pxt.decimals(), 6);
        assertEq(pxt.totalSupply(), pxt.TOTAL_SUPPLY());
        assertEq(pxt.balanceOf(admin), pxt.TOTAL_SUPPLY() - 10_000 * ONE);
        assertEq(pxt.balanceOf(alice), 10_000 * ONE);
    }

    function test_constructor_rejects_past_sell_unlock() public {
        vm.expectRevert(Pxt.InvalidSellUnlock.selector);
        new Pxt(admin, donation, marketing, block.timestamp);

        vm.expectRevert(Pxt.InvalidSellUnlock.selector);
        new Pxt(admin, donation, marketing, block.timestamp - 1);
    }

    function test_wallet_transfer_charges_270bps() public {
        uint256 amount = 100 * ONE;
        vm.prank(alice);
        pxt.transfer(bob, amount);

        assertEq(pxt.balanceOf(bob), 97.3e6);
        assertEq(pxt.balanceOf(donation), 1.45e6);
        assertEq(pxt.balanceOf(marketing), 1.25e6);
    }

    function test_transfer_to_lp_contract_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Pxt.ContractRecipientNotApproved.selector);
        pxt.transfer(address(pool), 10 * ONE);
    }

    function test_transfer_to_approved_contract_recipient() public {
        address rewards = makeAddr("rewardsVault");

        vm.prank(admin);
        pxt.setApprovedContractRecipient(rewards, true);

        vm.prank(alice);
        pxt.transfer(rewards, 50 * ONE);

        assertEq(pxt.balanceOf(rewards), 48.65e6);
    }

    function test_setApprovedContractRecipient_requires_approver_role() public {
        address rewards = makeAddr("rewardsVault");
        address multisig = makeAddr("multisig");
        bytes32 approverRole = pxt.RECIPIENT_APPROVER_ROLE();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, approverRole)
        );
        pxt.setApprovedContractRecipient(rewards, true);

        vm.startPrank(admin);
        pxt.grantRole(approverRole, multisig);
        pxt.revokeRole(approverRole, admin);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, approverRole)
        );
        pxt.setApprovedContractRecipient(rewards, true);

        vm.prank(multisig);
        pxt.setApprovedContractRecipient(rewards, true);
        assertTrue(pxt.isApprovedContractRecipient(rewards));
    }

    function test_approver_role_survives_ownable_renounce() public {
        address multisig = makeAddr("multisig");
        address staking = makeAddr("staking");
        vm.etch(staking, hex"00");

        vm.startPrank(admin);
        pxt.grantRole(pxt.RECIPIENT_APPROVER_ROLE(), multisig);
        pxt.grantRole(pxt.DEFAULT_ADMIN_ROLE(), multisig);
        pxt.revokeRole(pxt.RECIPIENT_APPROVER_ROLE(), admin);
        pxt.renounceRole(pxt.DEFAULT_ADMIN_ROLE(), admin);
        pxt.renounceOwnership();
        vm.stopPrank();

        assertEq(pxt.owner(), address(0));
        assertTrue(pxt.hasRole(pxt.RECIPIENT_APPROVER_ROLE(), multisig));

        vm.prank(multisig);
        pxt.setApprovedContractRecipient(staking, true);
        assertTrue(pxt.isApprovedContractRecipient(staking));
    }

    function test_cannot_revoke_pool_manager_recipient() public {
        address pm = makeAddr("poolManager");
        vm.etch(pm, hex"00");

        vm.prank(admin);
        pxt.setPoolManager(pm);

        vm.prank(admin);
        vm.expectRevert(Pxt.ProtectedRecipient.selector);
        pxt.setApprovedContractRecipient(pm, false);

        assertTrue(pxt.isApprovedContractRecipient(pm));
    }

    function test_cannot_revoke_fee_collector_or_attributor_recipient() public {
        address collector = makeAddr("feeCollector");
        address attributor = makeAddr("sellAttributor");
        vm.etch(collector, hex"00");
        vm.etch(attributor, hex"00");

        vm.startPrank(admin);
        pxt.setFeeCollector(collector);
        pxt.setSellAttributor(ISellAttributor(attributor));
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(Pxt.ProtectedRecipient.selector);
        pxt.setApprovedContractRecipient(collector, false);

        vm.prank(admin);
        vm.expectRevert(Pxt.ProtectedRecipient.selector);
        pxt.setApprovedContractRecipient(attributor, false);
    }

    function test_sell_to_pool_manager_works_if_allowlist_bit_cleared() public {
        address pm = makeAddr("poolManager");
        vm.etch(pm, hex"00");

        vm.prank(admin);
        pxt.setPoolManager(pm);

        // Clear the allowlist bit without going through the setter (protected).
        stdstore.target(address(pxt)).sig("isApprovedContractRecipient(address)").with_key(pm).checked_write(false);
        assertFalse(pxt.isApprovedContractRecipient(pm));

        vm.warp(pxt.sellUnlockTimestamp());
        uint256 amount = 100 * ONE;
        vm.prank(alice);
        pxt.transfer(pm, amount);
        assertEq(pxt.balanceOf(pm), amount);
    }

    function test_transfer_to_fee_exempt_recipient_pays_nothing() public {
        vm.prank(admin);
        pxt.setWalletStatus(bob, Pxt.WalletStatus.FeeExempt);

        uint256 donationBefore = pxt.balanceOf(donation);
        vm.prank(alice);
        pxt.transfer(bob, 100 * ONE);

        assertEq(pxt.balanceOf(bob), 100 * ONE);
        assertEq(pxt.balanceOf(donation), donationBefore);
    }

    function test_transfer_to_no_penalty_recipient_pays_nothing() public {
        vm.prank(admin);
        pxt.setWalletStatus(bob, Pxt.WalletStatus.NoPenalty);

        uint256 donationBefore = pxt.balanceOf(donation);
        vm.prank(alice);
        pxt.transfer(bob, 100 * ONE);

        assertEq(pxt.balanceOf(bob), 100 * ONE);
        assertEq(pxt.balanceOf(donation), donationBefore);
    }

    function test_fee_exempt_sender_still_pays_when_recipient_is_normal() public {
        vm.prank(admin);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.FeeExempt);

        vm.prank(alice);
        pxt.transfer(bob, 100 * ONE);

        assertEq(pxt.balanceOf(bob), 97.3e6);
        assertEq(pxt.balanceOf(donation), 1.45e6);
        assertEq(pxt.balanceOf(marketing), 1.25e6);
    }

    function test_transfer_to_donation_wallet_is_fee_free() public {
        vm.prank(alice);
        pxt.transfer(donation, 100 * ONE);
        assertEq(pxt.balanceOf(donation), 100 * ONE);
    }

    function test_sell_unlock_timestamp_is_fixed() public view {
        assertGt(pxt.sellUnlockTimestamp(), block.timestamp);
    }

    function test_default_sell_unlock_matches_documented_utc() public pure {
        // 2027-03-01 00:00:00 UTC (not 1_803_744_000 = 2027-02-27 16:00 UTC).
        assertEq(DEFAULT_SELL_UNLOCK_TIMESTAMP, 1_803_859_200);
    }

    function test_quote_transfer_matches_execution() public {
        FeeBreakdown memory quote = pxt.quoteTransfer(alice, bob, 1_000 * ONE);

        assertEq(uint256(quote.kind), uint256(FeeKind.Transfer));
        assertEq(quote.feeBps, 270);
        assertEq(quote.net, 973 * ONE);

        uint256 donationBefore = pxt.balanceOf(donation);
        vm.prank(alice);
        pxt.transfer(bob, 1_000 * ONE);
        assertEq(pxt.balanceOf(donation), donationBefore + quote.donation);
    }

    function test_quote_transfer_to_pool_reverts() public {
        vm.expectRevert(Pxt.ContractRecipientNotApproved.selector);
        pxt.quoteTransfer(alice, address(pool), 100 * ONE);
    }

    function test_pool_manager_settlement_is_fee_free() public {
        address pm = makeAddr("poolManager");
        // Give pm code so it is treated as a contract recipient.
        vm.etch(pm, hex"00");

        vm.startPrank(admin);
        pxt.setPoolManager(pm);
        vm.stopPrank();
        vm.warp(pxt.sellUnlockTimestamp());

        uint256 amount = 100 * ONE;
        uint256 donationBefore = pxt.balanceOf(donation);

        vm.prank(alice);
        pxt.transfer(pm, amount);

        assertEq(pxt.balanceOf(pm), amount);
        assertEq(pxt.balanceOf(donation), donationBefore);

        // Reverse direction also fee-free.
        vm.prank(pm);
        pxt.transfer(bob, amount);
        assertEq(pxt.balanceOf(bob), amount);
    }

    function test_transfer_to_pool_manager_pays_tax_without_attested_settle() public {
        address pm = makeAddr("poolManager");
        vm.etch(pm, hex"00");
        MockAttributorNoSettle attributor = new MockAttributorNoSettle();

        vm.startPrank(admin);
        pxt.setPoolManager(pm);
        pxt.setSellAttributor(attributor);
        vm.stopPrank();

        uint256 amount = 100 * ONE;
        uint256 donationBefore = pxt.balanceOf(donation);
        vm.prank(alice);
        pxt.transfer(pm, amount);

        assertEq(pxt.balanceOf(pm), 97.3e6);
        assertEq(pxt.balanceOf(donation), donationBefore + 1.45e6);
    }

    function test_feeExempt_sender_still_sell_locked() public {
        address pm = makeAddr("poolManager");
        vm.etch(pm, hex"00");

        vm.startPrank(admin);
        pxt.setPoolManager(pm);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.FeeExempt);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(SellsLocked.selector);
        pxt.transfer(pm, 10 * ONE);
    }

    function test_feeExempt_sender_still_antibot_blocked() public {
        address pm = makeAddr("poolManager");
        address firstSeller = makeAddr("firstSeller");
        vm.etch(pm, hex"00");

        vm.startPrank(admin);
        pxt.setPoolManager(pm);
        pxt.setAntiBotSeller(firstSeller);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.FeeExempt);
        vm.stopPrank();
        vm.warp(pxt.sellUnlockTimestamp());

        vm.prank(alice);
        vm.expectRevert(AntiBotSellBlocked.selector);
        pxt.transfer(pm, 10 * ONE);
    }

    function test_clearSellProtection_only_antiBot_after_unlock() public {
        address firstSeller = makeAddr("firstSeller");
        vm.prank(admin);
        pxt.setAntiBotSeller(firstSeller);

        vm.prank(firstSeller);
        vm.expectRevert(SellsLocked.selector);
        pxt.clearSellProtection();

        vm.warp(pxt.sellUnlockTimestamp());
        vm.prank(alice);
        vm.expectRevert(AntiBotSellBlocked.selector);
        pxt.clearSellProtection();

        vm.prank(firstSeller);
        pxt.clearSellProtection();
        assertTrue(pxt.sellProtectionCleared());
    }

    function test_clearSellProtection_rejects_txOrigin_helper() public {
        address firstSeller = makeAddr("firstSeller");
        address helper = makeAddr("helper");
        vm.prank(admin);
        pxt.setAntiBotSeller(firstSeller);

        vm.warp(pxt.sellUnlockTimestamp());
        // Former ops path: helper as msg.sender with antiBot as tx.origin — no longer allowed.
        vm.prank(helper, firstSeller);
        vm.expectRevert(AntiBotSellBlocked.selector);
        pxt.clearSellProtection();
        assertFalse(pxt.sellProtectionCleared());
    }

    function test_fake_7702_sized_contract_requires_allowlist() public {
        bytes memory designation = hex"ef0100e6cae83bde06e4c305530e199d7217f42808555b";
        address fake = makeAddr("fake7702Contract");
        vm.etch(fake, designation);

        vm.prank(alice);
        vm.expectRevert(Pxt.ContractRecipientNotApproved.selector);
        pxt.transfer(fake, 100 * ONE);
    }

    function test_7702_shaped_recipient_allowed_after_multisig_approval() public {
        bytes memory designation = hex"ef0100e6cae83bde06e4c305530e199d7217f42808555b";
        vm.etch(bob, designation);

        vm.prank(admin);
        pxt.setApprovedContractRecipient(bob, true);

        vm.prank(alice);
        pxt.transfer(bob, 100 * ONE);
        assertEq(pxt.balanceOf(bob), 97.3e6);
    }

    function test_pool_manager_payout_to_7702_shaped_recipient() public {
        address pm = makeAddr("poolManager");
        address trader = makeAddr("trader7702");
        bytes memory designation = hex"ef0100e6cae83bde06e4c305530e199d7217f42808555b";

        vm.etch(pm, hex"00");
        vm.etch(trader, designation);

        vm.startPrank(admin);
        pxt.setPoolManager(pm);
        vm.stopPrank();

        vm.prank(admin);
        pxt.transfer(pm, 50 * ONE);

        vm.prank(pm);
        pxt.transfer(trader, 10 * ONE);
        assertEq(pxt.balanceOf(trader), 10 * ONE);
    }

    function test_fee_collector_refund_to_owner_with_7702_code() public {
        MockFeeCollectorShell collector = new MockFeeCollectorShell(admin);
        bytes memory designation = hex"ef0100e6cae83bde06e4c305530e199d7217f42808555b";
        vm.etch(admin, designation);

        vm.startPrank(admin);
        pxt.setFeeCollector(address(collector));
        pxt.transfer(address(collector), 100 * ONE);
        vm.stopPrank();

        uint256 before = pxt.balanceOf(admin);
        vm.prank(address(collector));
        pxt.transfer(admin, 18);
        assertEq(pxt.balanceOf(admin), before + 18);
    }

    function test_pool_manager_can_payout_to_contract_recipient() public {
        address pm = makeAddr("poolManager");
        address router = makeAddr("router");
        vm.etch(pm, hex"00");
        vm.etch(router, hex"00");

        vm.startPrank(admin);
        pxt.setPoolManager(pm);
        vm.stopPrank();
        vm.warp(pxt.sellUnlockTimestamp());

        // Seed PM with PXT via fee-free settlement path.
        vm.prank(admin);
        pxt.transfer(pm, 50 * ONE);

        // PM → router must succeed even though router is not an approved contract recipient.
        vm.prank(pm);
        pxt.transfer(router, 10 * ONE);
        assertEq(pxt.balanceOf(router), 10 * ONE);
    }

    function test_setPoolManager_rejects_zero() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        pxt.setPoolManager(address(0));
    }

    function test_setAntiBotSeller_rejects_zero() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        pxt.setAntiBotSeller(address(0));
    }

    function test_setAntiBotSeller_one_shot() public {
        address firstSeller = makeAddr("firstSeller");
        address secondSeller = makeAddr("secondSeller");

        vm.startPrank(admin);
        pxt.setAntiBotSeller(firstSeller);
        vm.expectRevert(Pxt.AntiBotSellerAlreadySet.selector);
        pxt.setAntiBotSeller(secondSeller);
        vm.stopPrank();

        assertEq(pxt.antiBotSeller(), firstSeller);
    }

    function test_setAntiBotSeller_cannot_rearm_after_clear() public {
        address firstSeller = makeAddr("firstSeller");
        address secondSeller = makeAddr("secondSeller");

        vm.prank(admin);
        pxt.setAntiBotSeller(firstSeller);

        vm.warp(pxt.sellUnlockTimestamp());
        vm.prank(firstSeller);
        pxt.clearSellProtection();
        assertTrue(pxt.sellProtectionCleared());

        vm.prank(admin);
        vm.expectRevert(Pxt.SellProtectionAlreadyCleared.selector);
        pxt.setAntiBotSeller(secondSeller);
    }

    function test_setFeeCollector_one_shot() public {
        address firstCollector = makeAddr("firstCollector");
        address secondCollector = makeAddr("secondCollector");
        vm.etch(firstCollector, hex"00");
        vm.etch(secondCollector, hex"00");

        vm.startPrank(admin);
        pxt.setFeeCollector(firstCollector);
        vm.expectRevert(Pxt.FeeCollectorAlreadySet.selector);
        pxt.setFeeCollector(secondCollector);
        vm.stopPrank();

        assertEq(pxt.feeCollector(), firstCollector);
    }

    function test_setSellAttributor_one_shot() public {
        address firstAttributor = makeAddr("firstAttributor");
        address secondAttributor = makeAddr("secondAttributor");
        vm.etch(firstAttributor, hex"00");
        vm.etch(secondAttributor, hex"00");

        vm.startPrank(admin);
        pxt.setSellAttributor(ISellAttributor(firstAttributor));
        vm.expectRevert(Pxt.SellAttributorAlreadySet.selector);
        pxt.setSellAttributor(ISellAttributor(secondAttributor));
        vm.stopPrank();

        assertEq(address(pxt.sellAttributor()), firstAttributor);
    }
}
