// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Pxt} from "../src/core/Pxt.sol";
import {ZeroAddress} from "../src/core/PxtFeeModel.sol";

/// @notice Ops helper: atomic `clearSellProtection` + exact-in ERC-20 sell.
/// @dev Not protocol core. Set `pxt.setAntiBotSeller(address(this))` so this contract is the
///      designated first seller / clearer (no `tx.origin`). Only `operator` may call
///      `openWithExactInSell`. Pulls PXT from operator, settles via PoolSwapTest, refunds
///      leftover PXT + quote proceeds to operator. If the sell reverts, the clear rolls back.
contract PhoenixAntiBotOpenSell {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    Pxt public immutable pxt;
    PoolSwapTest public immutable swapRouter;
    /// @notice EOA/multisig allowed to open trading (funds the ceremonial sell).
    address public immutable operator;

    error NotOperator();
    error NotSell();
    error ZeroAmount();
    error AntiBotMustBeThis();

    constructor(Pxt pxt_, PoolSwapTest swapRouter_, address operator_) {
        if (address(pxt_) == address(0) || address(swapRouter_) == address(0) || operator_ == address(0)) {
            revert ZeroAddress();
        }
        pxt = pxt_;
        swapRouter = swapRouter_;
        operator = operator_;
    }

    /// @notice Clear public-sell gate then execute an exact-in PXT→quote sell.
    /// @param key Official Phoenix pool key.
    /// @param amountIn PXT amount pulled from `msg.sender` and sold (exact-in).
    /// @param hookData Passed to PoolSwapTest (empty → encodes `msg.sender`).
    function openWithExactInSell(PoolKey calldata key, uint256 amountIn, bytes calldata hookData)
        external
        returns (BalanceDelta delta)
    {
        if (msg.sender != operator) revert NotOperator();
        if (pxt.antiBotSeller() != address(this)) revert AntiBotMustBeThis();
        if (amountIn == 0) revert ZeroAmount();

        address pxtAddr = address(pxt);
        bool zeroForOne = Currency.unwrap(key.currency0) == pxtAddr;
        if (!zeroForOne && Currency.unwrap(key.currency1) != pxtAddr) revert NotSell();

        IERC20(pxtAddr).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(pxtAddr).forceApprove(address(swapRouter), amountIn);

        // Clear first so beforeSwap `enforceTradingOpen` passes; rolls back if swap reverts.
        // msg.sender to Pxt is this contract (= antiBotSeller).
        pxt.clearSellProtection();

        bytes memory data = hookData.length == 0 ? abi.encode(msg.sender) : hookData;
        delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            data
        );

        _sweep(pxtAddr, msg.sender);
        address quote = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        _sweep(quote, msg.sender);
    }

    function _sweep(address token, address to) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(to, bal);
    }
}
