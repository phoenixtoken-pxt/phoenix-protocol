// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PxtFeeModel} from "../src/core/PxtFeeModel.sol";

/// @dev Exposes internal library splits for unit / fuzz checks.
contract PxtFeeModelHarness {
    function grossUp(uint256 net, uint256 bps) external pure returns (uint256) {
        return PxtFeeModel.grossUp(net, bps);
    }

    function splitBuy(uint256 amount) external pure returns (uint256 donation, uint256 marketing) {
        return PxtFeeModel.splitBuy(amount);
    }

    function splitSellUsdc(uint256 feeBps, uint256 usdcAmount)
        external
        pure
        returns (uint256 donation, uint256 marketing, uint256 buyback)
    {
        return PxtFeeModel.splitSellUsdc(feeBps, usdcAmount);
    }

    function splitSellBurn(uint256 feeBps, uint256 pxtAmount) external pure returns (uint256) {
        return PxtFeeModel.splitSellBurn(feeBps, pxtAmount);
    }
}

contract PxtFeeModelTest is Test {
    PxtFeeModelHarness internal harness;

    function setUp() public {
        harness = new PxtFeeModelHarness();
    }

    function test_grossUp_penalty_exceeds_net_times_bps() public view {
        uint256 net = 100_000_000;
        uint256 fee = harness.grossUp(net, PxtFeeModel.PENALTY_USDC_FEE_BPS);
        assertEq(fee, (net * PxtFeeModel.PENALTY_USDC_FEE_BPS) / (PxtFeeModel.BPS - PxtFeeModel.PENALTY_USDC_FEE_BPS));
        assertGt(fee, (net * PxtFeeModel.PENALTY_USDC_FEE_BPS) / PxtFeeModel.BPS);
    }

    function testFuzz_grossUp(uint256 net, uint256 bps) public view {
        net = bound(net, 0, type(uint128).max);
        bps = bound(bps, 0, PxtFeeModel.BPS - 1);
        uint256 fee = harness.grossUp(net, bps);
        if (bps == 0 || net == 0) {
            assertEq(fee, 0);
            return;
        }
        assertEq(fee, (net * bps) / (PxtFeeModel.BPS - bps));
    }

    function test_splitBuy_legs_sum_to_buy_fee() public view {
        uint256 amount = 1_000_000_000;
        (uint256 donation, uint256 marketing) = harness.splitBuy(amount);
        assertEq(donation + marketing, (amount * PxtFeeModel.BUY_FEE_BPS) / PxtFeeModel.BPS);
        assertEq(donation, (amount * PxtFeeModel.BUY_DONATION_BPS) / PxtFeeModel.BPS);
    }

    function test_splitSellUsdc_legs_sum_to_usdc_fee() public view {
        uint256 amount = 1_000_000_000;
        (uint256 dSell, uint256 mSell, uint256 bSell) = harness.splitSellUsdc(PxtFeeModel.SELL_FEE_BPS, amount);
        assertEq(dSell + mSell + bSell, (amount * PxtFeeModel.SELL_USDC_FEE_BPS) / PxtFeeModel.BPS);

        (uint256 dPen, uint256 mPen, uint256 bPen) = harness.splitSellUsdc(PxtFeeModel.PENALTY_FEE_BPS, amount);
        assertEq(dPen + mPen + bPen, (amount * PxtFeeModel.PENALTY_USDC_FEE_BPS) / PxtFeeModel.BPS);
    }

    function testFuzz_splitBuy_sum(uint256 amount) public view {
        amount = bound(amount, 0, type(uint128).max);
        (uint256 donation, uint256 marketing) = harness.splitBuy(amount);
        uint256 total = donation + marketing;
        assertEq(total, (amount * PxtFeeModel.BUY_FEE_BPS) / PxtFeeModel.BPS);
        assertLe(total, amount);
        assertLe(donation, amount);
        assertLe(marketing, amount);
    }

    function testFuzz_splitSellUsdc_sum(uint256 amount) public view {
        amount = bound(amount, 0, type(uint128).max);
        (uint256 dSell, uint256 mSell, uint256 bSell) = harness.splitSellUsdc(PxtFeeModel.SELL_FEE_BPS, amount);
        uint256 sellTotal = dSell + mSell + bSell;
        assertEq(sellTotal, (amount * PxtFeeModel.SELL_USDC_FEE_BPS) / PxtFeeModel.BPS);
        assertLe(sellTotal, amount);

        (uint256 dPen, uint256 mPen, uint256 bPen) = harness.splitSellUsdc(PxtFeeModel.PENALTY_FEE_BPS, amount);
        uint256 penTotal = dPen + mPen + bPen;
        assertEq(penTotal, (amount * PxtFeeModel.PENALTY_USDC_FEE_BPS) / PxtFeeModel.BPS);
        assertLe(penTotal, amount);
    }

    function testFuzz_splitSellBurn_never_exceeds_input(uint256 feeBps, uint256 pxtAmount) public view {
        feeBps = bound(feeBps, 0, PxtFeeModel.PENALTY_FEE_BPS);
        pxtAmount = bound(pxtAmount, 0, type(uint128).max);
        uint256 burnAmount = harness.splitSellBurn(feeBps, pxtAmount);
        assertLe(burnAmount, pxtAmount);
    }
}
