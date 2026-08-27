// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Hook receives authentic seller identity from Pxt settlement
/// (user -> PoolManager). Used for USDC fee rebate + dump-window accounting.
interface ISellAttributor {
    function attributeSell(address seller, uint256 pxtAmount) external;

    /// @notice PXT received from PoolManager this tx (flash take / LP exit). Dump-window only.
    function creditFromPoolManager(address account, uint256 amount) external;
}
