// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {Pxt} from "../src/core/Pxt.sol";

/// @dev Random transfers / self-burns; supply must never increase after construction.
contract PxtSupplyHandler is Test {
    Pxt public immutable pxt;
    address[] public actors;

    constructor(Pxt pxt_, address[] memory actors_) {
        pxt = pxt_;
        actors = actors_;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        if (from == to) return;

        uint256 bal = pxt.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(from);
        pxt.transfer(to, amount);
    }

    function burn(uint256 fromSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        uint256 bal = pxt.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(from);
        pxt.burnBalance(amount);
    }
}

contract PxtSupplyInvariantTest is StdInvariant, Test {
    Pxt internal pxt;
    PxtSupplyHandler internal handler;
    uint256 internal initialSupply;

    address internal admin = makeAddr("admin");
    address internal donation = makeAddr("donation");
    address internal marketing = makeAddr("marketing");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.startPrank(admin);
        pxt = new Pxt(admin, donation, marketing, block.timestamp + 30 days);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.FeeExempt);
        pxt.transfer(alice, 1_000_000e6);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.Normal);
        pxt.setWalletStatus(bob, Pxt.WalletStatus.FeeExempt);
        pxt.transfer(bob, 1_000_000e6);
        pxt.setWalletStatus(bob, Pxt.WalletStatus.Normal);
        vm.stopPrank();

        address[] memory actors = new address[](3);
        actors[0] = admin;
        actors[1] = alice;
        actors[2] = bob;

        handler = new PxtSupplyHandler(pxt, actors);
        initialSupply = pxt.totalSupply();

        targetContract(address(handler));
    }

    function invariant_totalSupply_never_increases() public view {
        assertLe(pxt.totalSupply(), initialSupply);
    }

    function invariant_totalSupply_eq_sum_of_tracked_plus_fee_wallets() public view {
        // Conservatively: supply equals sum of all non-burned balances we can read.
        // Fee wallets receive transfer tax; burns permanently destroy supply.
        uint256 sum =
            pxt.balanceOf(admin) + pxt.balanceOf(alice) + pxt.balanceOf(bob) + pxt.balanceOf(donation)
            + pxt.balanceOf(marketing);
        assertEq(pxt.totalSupply(), sum);
    }
}
