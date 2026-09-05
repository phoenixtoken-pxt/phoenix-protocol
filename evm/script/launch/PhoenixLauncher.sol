// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {ZeroAddress} from "../../src/core/PxtFeeModel.sol";
import {PhoenixLaunchTypes} from "./PhoenixLaunchTypes.sol";
import {PhoenixOrchestrator} from "./PhoenixOrchestrator.sol";

/// @notice Factory: CREATE2-deploy a per-owner PhoenixOrchestrator (4-phase ceremony).
contract PhoenixLauncher {
    address public immutable pxtDeployer;
    address public immutable hookDeployer;
    address public immutable collectorDeployer;
    address public immutable openSellDeployer;

    mapping(address => address) public latestOrchestrator;

    event Created(address indexed owner, address indexed orchestrator, bytes32 salt);

    error SaltRequired();
    error OrchestratorMismatch();
    error ZeroDeployer();

    constructor(address pxtDeployer_, address hookDeployer_, address collectorDeployer_, address openSellDeployer_) {
        if (
            pxtDeployer_ == address(0) || hookDeployer_ == address(0) || collectorDeployer_ == address(0)
                || openSellDeployer_ == address(0)
        ) revert ZeroDeployer();
        pxtDeployer = pxtDeployer_;
        hookDeployer = hookDeployer_;
        collectorDeployer = collectorDeployer_;
        openSellDeployer = openSellDeployer_;
    }

    /// @notice CREATE2-deploy orchestrator for `msg.sender` (no token yet).
    function create(bytes32 salt) external returns (PhoenixOrchestrator orchestrator) {
        return createFor(msg.sender, salt);
    }

    function createFor(address owner, bytes32 salt) public returns (PhoenixOrchestrator orchestrator) {
        if (owner == address(0)) revert ZeroAddress();
        if (salt == bytes32(0)) revert SaltRequired();

        bytes32 orchSalt = _orchSalt(owner, salt);
        address predicted = predictOrchestrator(owner, salt);
        orchestrator = new PhoenixOrchestrator{
            salt: orchSalt
        }(address(this), owner, pxtDeployer, hookDeployer, collectorDeployer, openSellDeployer);
        if (address(orchestrator) != predicted) revert OrchestratorMismatch();
        latestOrchestrator[owner] = address(orchestrator);
        emit Created(owner, address(orchestrator), salt);
    }

    function predictOrchestrator(address owner, bytes32 salt) public view returns (address) {
        if (owner == address(0)) revert ZeroAddress();
        bytes32 orchSalt = _orchSalt(owner, salt);
        bytes memory init = abi.encodePacked(
            type(PhoenixOrchestrator).creationCode,
            abi.encode(address(this), owner, pxtDeployer, hookDeployer, collectorDeployer, openSellDeployer)
        );
        return Create2.computeAddress(orchSalt, keccak256(init), address(this));
    }

    function hookFlags() external pure returns (uint160) {
        return PhoenixLaunchTypes.hookFlags();
    }

    function pxtCreate2Salt(address orchestrator) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(PhoenixLaunchTypes.PXT_SALT, orchestrator));
    }

    function _orchSalt(address owner, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(PhoenixLaunchTypes.ORCH_SALT_PREFIX, owner, salt));
    }
}
