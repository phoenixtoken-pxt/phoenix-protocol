// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Pxt} from "../../src/core/Pxt.sol";
import {DEFAULT_SELL_UNLOCK_TIMESTAMP, ZeroAddress} from "../../src/core/PxtFeeModel.sol";
import {PhoenixFeeCollector} from "../../src/fee/PhoenixFeeCollector.sol";
import {PhoenixV4ReturnDeltaHook} from "../../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {PhoenixAntiBotOpenSell} from "../PhoenixAntiBotOpenSell.sol";
import {PhoenixLaunchTypes} from "./PhoenixLaunchTypes.sol";
import {
    PhoenixPxtDeployer,
    PhoenixHookDeployer,
    PhoenixCollectorDeployer,
    PhoenixOpenSellDeployer
} from "./PhoenixChildDeployers.sol";

/// @notice 4-phase launch registry + CREATE2 helper.
///         Phase 1 `createToken` — Pxt minted to `launchOwner` (admin is Ownable).
///         Phase 2 `deployPoolContracts` — hook / FeeCollector / openSell with admin = launchOwner.
///         Phase 3/4 — admin-signed scripts call FeeCollector.addLiquidity / renounce (see PhoenixLaunchActions).
/// @dev Orchestrator is NOT Ownable on Pxt/hook/collector. Admin holds supply and ownership.
contract PhoenixOrchestrator {
    address public immutable factory;
    address public immutable launchOwner;
    address public immutable pxtDeployer;
    address public immutable hookDeployer;
    address public immutable collectorDeployer;
    address public immutable openSellDeployer;

    enum Phase {
        None,
        TokenCreated,
        PoolContractsDeployed,
        PoolConfigured,
        Seeded,
        Locked
    }

    Phase public phase;

    Pxt public pxt;
    PhoenixV4ReturnDeltaHook public hook;
    PhoenixFeeCollector public collector;
    PhoenixAntiBotOpenSell public openSell;
    address public quoteToken;
    uint256 public pxtSeed;
    uint256 public usdcSeed;
    uint160 public sqrtPriceX96;
    int24 public tickLower;
    int24 public tickUpper;
    uint256 public sellUnlockTimestamp;
    address public donation;
    address public marketing;

    event TokenCreated(address indexed pxt, address indexed owner, uint256 sellUnlock);
    event SeedAmountsSet(uint256 pxtSeed, uint256 usdcSeed);
    event PoolContractsDeployed(
        address indexed hook, address indexed collector, address openSell, address quoteToken
    );
    event PoolConfigured(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper);
    event Seeded(uint256 pxtAmount, uint256 usdcAmount);
    event Locked(address indexed recipientApprover);

    error NotFactory();
    error NotLaunchOwner();
    error WrongPhase();
    error InvalidSeed();
    error InvalidTicks();
    error ZeroAmount();

    modifier onlyLaunchOwner() {
        if (msg.sender != launchOwner) revert NotLaunchOwner();
        _;
    }

    constructor(
        address factory_,
        address launchOwner_,
        address pxtDeployer_,
        address hookDeployer_,
        address collectorDeployer_,
        address openSellDeployer_
    ) {
        if (
            factory_ == address(0) || launchOwner_ == address(0) || pxtDeployer_ == address(0)
                || hookDeployer_ == address(0) || collectorDeployer_ == address(0) || openSellDeployer_ == address(0)
        ) revert ZeroAddress();
        factory = factory_;
        launchOwner = launchOwner_;
        pxtDeployer = pxtDeployer_;
        hookDeployer = hookDeployer_;
        collectorDeployer = collectorDeployer_;
        openSellDeployer = openSellDeployer_;
    }

    /// @notice Phase 1: deploy Pxt with admin = launchOwner (full supply + Ownable to admin).
    function createToken(address donation_, address marketing_, uint256 sellUnlock)
        external
        onlyLaunchOwner
        returns (Pxt token)
    {
        if (phase != Phase.None) revert WrongPhase();
        if (donation_ == address(0) || marketing_ == address(0)) revert ZeroAddress();
        uint256 unlock = sellUnlock == 0 ? DEFAULT_SELL_UNLOCK_TIMESTAMP : sellUnlock;

        bytes32 pxtSalt = keccak256(abi.encodePacked(PhoenixLaunchTypes.PXT_SALT, address(this)));
        token = PhoenixPxtDeployer(pxtDeployer).deploy(pxtSalt, launchOwner, donation_, marketing_, unlock);

        pxt = token;
        donation = donation_;
        marketing = marketing_;
        sellUnlockTimestamp = unlock;
        phase = Phase.TokenCreated;
        emit TokenCreated(address(token), launchOwner, unlock);
    }

    /// @notice Set / update planned LP sizes (spot ratio at configure). Before pool configure.
    function setSeedAmounts(uint256 pxtAmt, uint256 usdcAmt) external onlyLaunchOwner {
        if (phase == Phase.None || phase == Phase.Seeded || phase == Phase.Locked) revert WrongPhase();
        if (phase == Phase.PoolConfigured) revert WrongPhase();
        if (pxtAmt == 0 || usdcAmt == 0) revert InvalidSeed();
        pxtSeed = pxtAmt;
        usdcSeed = usdcAmt;
        emit SeedAmountsSet(pxtAmt, usdcAmt);
    }

    /// @notice Phase 2a: deploy hook / FeeCollector / openSell with admin = launchOwner.
    ///         Admin must then run configure (PhoenixLaunchActions) and call `markPoolConfigured`.
    function deployPoolContracts(PhoenixLaunchTypes.LaunchParams calldata p)
        external
        onlyLaunchOwner
        returns (PhoenixV4ReturnDeltaHook h, PhoenixFeeCollector fc, PhoenixAntiBotOpenSell os)
    {
        if (phase != Phase.TokenCreated) revert WrongPhase();
        if (address(pxt) == address(0)) revert WrongPhase();
        if (address(p.poolManager) == address(0) || p.quoteToken == address(0) || p.swapRouter == address(0)) {
            revert ZeroAddress();
        }
        if (p.pxtSeed == 0 || p.usdcSeed == 0) revert InvalidSeed();

        int24 lo = p.tickLower == 0 && p.tickUpper == 0 ? PhoenixLaunchTypes.TICK_LOWER : p.tickLower;
        int24 hi = p.tickLower == 0 && p.tickUpper == 0 ? PhoenixLaunchTypes.TICK_UPPER : p.tickUpper;
        if (lo >= hi) revert InvalidTicks();

        address operator = p.operator == address(0) ? launchOwner : p.operator;
        Pxt token = pxt;

        h = PhoenixHookDeployer(hookDeployer).deploy(p.hookSalt, p.poolManager, token, operator, launchOwner);
        fc = PhoenixCollectorDeployer(collectorDeployer).deploy(
            p.poolManager, token, donation, marketing, launchOwner
        );
        os = PhoenixOpenSellDeployer(openSellDeployer).deploy(token, PoolSwapTest(p.swapRouter), operator);

        hook = h;
        collector = fc;
        openSell = os;
        quoteToken = p.quoteToken;
        pxtSeed = p.pxtSeed;
        usdcSeed = p.usdcSeed;
        tickLower = lo;
        tickUpper = hi;
        phase = Phase.PoolContractsDeployed;

        emit PoolContractsDeployed(address(h), address(fc), address(os), p.quoteToken);
    }

    /// @notice Phase 2b bookkeeping after admin configures + initializes the pool.
    function markPoolConfigured(uint160 sqrtPriceX96_) external onlyLaunchOwner {
        if (phase != Phase.PoolContractsDeployed) revert WrongPhase();
        if (sqrtPriceX96_ == 0) revert ZeroAmount();
        sqrtPriceX96 = sqrtPriceX96_;
        phase = Phase.PoolConfigured;
        emit PoolConfigured(sqrtPriceX96_, tickLower, tickUpper);
    }

    /// @notice Phase 3 bookkeeping after admin seeds LP via FeeCollector.addLiquidity.
    function markSeeded() external onlyLaunchOwner {
        if (phase != Phase.PoolConfigured) revert WrongPhase();
        if (!collector.seedLiquidityAdded()) revert WrongPhase();
        phase = Phase.Seeded;
        emit Seeded(pxtSeed, usdcSeed);
    }

    /// @notice Phase 4 bookkeeping after admin renounces / hands roles off.
    function markLocked(address recipientApprover) external onlyLaunchOwner {
        if (phase != Phase.Seeded) revert WrongPhase();
        phase = Phase.Locked;
        emit Locked(recipientApprover);
    }

    // --- views used by scripts / checks ---

    function tokenCreated() external view returns (bool) {
        return phase >= Phase.TokenCreated;
    }

    function poolReady() external view returns (bool) {
        return phase >= Phase.PoolConfigured;
    }

    function seeded() external view returns (bool) {
        return phase >= Phase.Seeded;
    }

    function locked() external view returns (bool) {
        return phase == Phase.Locked;
    }

    /// @dev Back-compat for older check scripts that expected `wired`.
    function wired() external view returns (bool) {
        return phase >= Phase.PoolConfigured;
    }
}
