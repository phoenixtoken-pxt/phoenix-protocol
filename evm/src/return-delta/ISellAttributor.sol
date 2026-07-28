// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Hook receives authentic seller identity from Pxt settlement
/// (user -> PoolManager). Used for USDC fee rebate + dump-window accounting.
interface ISellAttributor {
    function attributeSell(address seller, uint256 pxtAmount) external;
}
