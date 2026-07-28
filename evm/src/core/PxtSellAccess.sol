// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AntiBotSellBlocked, SellsLocked} from "./PxtFeeModel.sol";

/// @notice Minimal read surface for sell unlock / anti-bot checks.
interface IPxtSellControls {
    function sellUnlockTimestamp() external view returns (uint256);
    function antiBotSeller() external view returns (address);
    function sellProtectionCleared() external view returns (bool);
}

/// @notice Shared sell-lock + anti-bot gates for Pxt, hooks, and FeeCollector.
library PxtSellAccess {
    /// @dev Timestamp gate only.
    function enforceSellUnlocked(IPxtSellControls pxt) internal view {
        if (block.timestamp < pxt.sellUnlockTimestamp()) revert SellsLocked();
    }

    /// @dev ERC-20 custody path: unlock + designated first seller (when anti-bot is armed).
    function enforceSellAccess(IPxtSellControls pxt, address seller) internal view {
        enforceSellUnlocked(pxt);
        address bot = pxt.antiBotSeller();
        if (bot == address(0) || pxt.sellProtectionCleared()) return;
        if (seller != bot) revert AntiBotSellBlocked();
    }

    /// @dev Public trading open: unlock + anti-bot cleared (or disabled).
    /// Used by hooks (ERC-6909 path) and FeeCollector buyback / recycle.
    function enforceTradingOpen(IPxtSellControls pxt) internal view {
        enforceSellUnlocked(pxt);
        if (pxt.antiBotSeller() != address(0) && !pxt.sellProtectionCleared()) revert AntiBotSellBlocked();
    }
}
