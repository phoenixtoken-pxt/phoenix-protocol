// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice Shared launch params / salts for PhoenixLauncher + PhoenixOrchestrator.
library PhoenixLaunchTypes {
    bytes32 internal constant ORCH_SALT_PREFIX = keccak256("PHOENIX_ORCHESTRATOR_V1");
    bytes32 internal constant PXT_SALT = keccak256("PHOENIX_LAUNCH_PXT");

    uint24 internal constant LP_FEE = 0;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -887_220;
    int24 internal constant TICK_UPPER = 887_220;

    struct Deployers {
        address pxt;
        address hook;
        address collector;
        address openSell;
    }

    struct LaunchParams {
        IPoolManager poolManager;
        address quoteToken;
        address donation;
        address marketing;
        address operator;
        address swapRouter;
        address lpRouter;
        address positionManager;
        address universalRouter;
        uint256 sellUnlockTimestamp;
        uint256 pxtSeed;
        uint256 usdcSeed;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint24 recycleWidthSpacings;
        uint16 maxBuybackSlippageBps;
        bytes32 hookSalt;
        address[] feeExempt;
        address[] noPenalty;
    }

    struct UsdcPermit {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function hookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }
}
