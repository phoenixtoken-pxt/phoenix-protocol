// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PhoenixBuybackMath} from "../src/fee/PhoenixBuybackMath.sol";

contract PhoenixBuybackMathHarness {
    function pxtForQuote(uint256 quoteAmount, uint160 sqrtPriceX96, bool pxtIsToken0) external pure returns (uint256) {
        return PhoenixBuybackMath.pxtForQuote(quoteAmount, sqrtPriceX96, pxtIsToken0);
    }

    function enforceMinOut(uint256 actual, uint256 callerMin, uint256 expected, uint16 slippageBps) external pure {
        PhoenixBuybackMath.enforceMinOut(actual, callerMin, expected, slippageBps);
    }
}

contract PhoenixBuybackMathTest is Test {
    PhoenixBuybackMathHarness internal harness;

    function setUp() public {
        harness = new PhoenixBuybackMathHarness();
    }

    /// @dev Cyberscope EORZ counterexample: old token1 path rounded to zero.
    function test_pxtForQuote_token1_no_premature_zero() public view {
        uint160 sqrtPriceX96 = uint160((1 << 48) - 1);
        uint256 quote = 79_228_162_514_264_900_543_497_371_652;
        uint256 out = harness.pxtForQuote(quote, sqrtPriceX96, false);
        assertEq(out, 1);
    }

    function test_pxtForQuote_token0_matches_combined_formula() public view {
        uint160 sqrtPriceX96 = uint160(1 << 96);
        uint256 quote = 1_000_000;
        uint256 out = harness.pxtForQuote(quote, sqrtPriceX96, true);
        assertEq(out, quote);
    }

    function test_enforceMinOut_reverts_when_expected_zero() public {
        vm.expectRevert(PhoenixBuybackMath.Slippage.selector);
        harness.enforceMinOut(1, 0, 0, 200);
    }

    function test_enforceMinOut_applies_protocol_floor() public view {
        harness.enforceMinOut(980, 0, 1000, 200);
    }

    function test_enforceMinOut_reverts_below_protocol_floor() public {
        vm.expectRevert(PhoenixBuybackMath.Slippage.selector);
        harness.enforceMinOut(979, 0, 1000, 200);
    }
}
