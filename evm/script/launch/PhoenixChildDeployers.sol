// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Pxt} from "../../src/core/Pxt.sol";
import {PhoenixFeeCollector} from "../../src/fee/PhoenixFeeCollector.sol";
import {PhoenixV4ReturnDeltaHook} from "../../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {PhoenixAntiBotOpenSell} from "../PhoenixAntiBotOpenSell.sol";

/// @dev One-shot CREATE2 wrappers so PhoenixOrchestrator does not embed child bytecode (EIP-170).
contract PhoenixPxtDeployer {
    function deploy(bytes32 salt, address admin, address donation, address marketing, uint256 sellUnlock)
        external
        returns (Pxt)
    {
        return new Pxt{salt: salt}(admin, donation, marketing, sellUnlock);
    }
}

contract PhoenixHookDeployer {
    function deploy(bytes32 salt, IPoolManager manager, Pxt pxt, address operator, address admin)
        external
        returns (PhoenixV4ReturnDeltaHook)
    {
        return new PhoenixV4ReturnDeltaHook{salt: salt}(manager, pxt, operator, admin);
    }
}

contract PhoenixCollectorDeployer {
    function deploy(IPoolManager manager, Pxt pxt, address donation, address marketing, address admin)
        external
        returns (PhoenixFeeCollector)
    {
        return new PhoenixFeeCollector(manager, pxt, donation, marketing, admin);
    }
}

contract PhoenixOpenSellDeployer {
    function deploy(Pxt pxt, PoolSwapTest swapRouter, address operator) external returns (PhoenixAntiBotOpenSell) {
        return new PhoenixAntiBotOpenSell(pxt, swapRouter, operator);
    }
}
