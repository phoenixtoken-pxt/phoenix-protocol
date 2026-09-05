// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Pxt} from "../src/core/Pxt.sol";
import {PhoenixFeeCollector} from "../src/fee/PhoenixFeeCollector.sol";
import {PhoenixV4ReturnDeltaHook} from "../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {HookMiner} from "../src/uniswap/v4/HookMiner.sol";
import {PhoenixAntiBotOpenSell} from "../script/PhoenixAntiBotOpenSell.sol";
import {PhoenixLauncher} from "../script/launch/PhoenixLauncher.sol";
import {PhoenixOrchestrator} from "../script/launch/PhoenixOrchestrator.sol";
import {PhoenixLaunchTypes} from "../script/launch/PhoenixLaunchTypes.sol";
import {PhoenixLaunchActions} from "../script/launch/PhoenixLaunchActions.sol";
import {
    PhoenixPxtDeployer,
    PhoenixHookDeployer,
    PhoenixCollectorDeployer,
    PhoenixOpenSellDeployer
} from "../script/launch/PhoenixChildDeployers.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PhoenixLauncherTest is Test, PhoenixLaunchActions {
    uint256 internal constant WHOLE = 1e6;
    bytes32 internal constant SALT = bytes32(uint256(1));

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    PhoenixLauncher internal launcher;
    PhoenixPxtDeployer internal pxtDeployer;
    PhoenixHookDeployer internal hookDeployer;
    MockERC20 internal musdc;

    address internal client = makeAddr("client");
    address internal donation = makeAddr("donation");
    address internal marketing = makeAddr("marketing");
    address internal safe = makeAddr("safe");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    address internal ur = makeAddr("universalRouter");
    address internal mainWallet = makeAddr("mainSupply");

    uint256 internal sellUnlock;
    uint256 internal pxtSeed;
    uint256 internal usdcSeed;

    function setUp() public {
        sellUnlock = block.timestamp + 30 days;
        pxtSeed = 210_000_000 * WHOLE;
        usdcSeed = 210_000 * WHOLE;

        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        pxtDeployer = new PhoenixPxtDeployer();
        hookDeployer = new PhoenixHookDeployer();
        launcher = new PhoenixLauncher(
            address(pxtDeployer),
            address(hookDeployer),
            address(new PhoenixCollectorDeployer()),
            address(new PhoenixOpenSellDeployer())
        );

        musdc = new MockERC20("Mock USDC", "mUSDC", 6, address(this));
        musdc.mint(client, usdcSeed);
        vm.deal(client, 10 ether);
    }

    function test_four_phase_create_deploy_seed_lock() public {
        PhoenixOrchestrator orch = _createToken();
        Pxt pxt = orch.pxt();

        assertEq(pxt.owner(), client);
        assertEq(pxt.balanceOf(client), pxt.TOTAL_SUPPLY());
        assertEq(uint256(orch.phase()), uint256(PhoenixOrchestrator.Phase.TokenCreated));

        // Park treasury on MAIN (keep seed slice on admin).
        uint256 toMain = pxt.TOTAL_SUPPLY() - pxtSeed;
        vm.prank(client);
        pxt.setWalletStatus(mainWallet, Pxt.WalletStatus.FeeExempt);
        vm.prank(client);
        pxt.transfer(mainWallet, toMain);
        assertEq(pxt.balanceOf(mainWallet), toMain);
        assertEq(pxt.balanceOf(client), pxtSeed);

        _deployPool(orch);
        assertEq(uint256(orch.phase()), uint256(PhoenixOrchestrator.Phase.PoolConfigured));
        assertEq(orch.hook().owner(), client);
        assertEq(orch.collector().owner(), client);
        assertTrue(pxt.isApprovedContractRecipient(address(swapRouter)));

        _seed(orch);
        assertTrue(orch.collector().seedLiquidityAdded());
        assertEq(uint256(orch.phase()), uint256(PhoenixOrchestrator.Phase.Seeded));

        address[] memory callers = new address[](1);
        callers[0] = keeper;
        vm.startPrank(client);
        _lockAsOwner(pxt, orch.hook(), orch.collector(), client, safe, callers);
        orch.markLocked(safe);
        vm.stopPrank();

        assertEq(pxt.owner(), address(0));
        assertEq(orch.hook().owner(), address(0));
        assertEq(orch.collector().owner(), address(0));
        assertTrue(pxt.hasRole(pxt.DEFAULT_ADMIN_ROLE(), safe));
        assertTrue(pxt.hasRole(pxt.RECIPIENT_APPROVER_ROLE(), safe));
        assertFalse(pxt.hasRole(pxt.DEFAULT_ADMIN_ROLE(), client));
        assertTrue(orch.collector().hasRole(orch.collector().BUYBACK_EXECUTOR_APPROVER_ROLE(), safe));
        assertTrue(orch.collector().isAuthorizedBuybackCaller(keeper));
        assertTrue(orch.locked());
        assertEq(pxt.balanceOf(mainWallet), toMain);
    }

    function test_setSeedAmounts_before_deploy() public {
        PhoenixOrchestrator orch = _createToken();
        uint256 newPxt = 100_000 * WHOLE;
        uint256 newUsdc = 100 * WHOLE;
        vm.prank(client);
        orch.setSeedAmounts(newPxt, newUsdc);
        assertEq(orch.pxtSeed(), newPxt);
        assertEq(orch.usdcSeed(), newUsdc);
    }

    function test_deploy_reverts_for_stranger() public {
        PhoenixOrchestrator orch = _createToken();
        PhoenixLaunchTypes.LaunchParams memory p = _poolParams(orch);
        vm.prank(stranger);
        vm.expectRevert(PhoenixOrchestrator.NotLaunchOwner.selector);
        orch.deployPoolContracts(p);
    }

    function test_lock_rejects_client_as_approver() public {
        PhoenixOrchestrator orch = _createToken();
        _deployPool(orch);
        _seed(orch);
        address[] memory callers = new address[](1);
        callers[0] = keeper;
        Pxt token = orch.pxt();
        PhoenixV4ReturnDeltaHook h = orch.hook();
        PhoenixFeeCollector fc = orch.collector();
        vm.expectRevert(RecipientApproverIsOwner.selector);
        this.lockExternal(token, h, fc, client, client, callers);
    }

    function test_lock_requires_seed() public {
        PhoenixOrchestrator orch = _createToken();
        _deployPool(orch);
        address[] memory callers = new address[](1);
        callers[0] = keeper;
        Pxt token = orch.pxt();
        PhoenixV4ReturnDeltaHook h = orch.hook();
        PhoenixFeeCollector fc = orch.collector();
        vm.expectRevert(ZeroProtocolLiquidity.selector);
        this.lockExternal(token, h, fc, client, safe, callers);
    }

    function test_post_lock_safe_can_allowlist_recipient() public {
        PhoenixOrchestrator orch = _createToken();
        _deployPool(orch);
        _seed(orch);
        address[] memory callers = new address[](1);
        callers[0] = keeper;
        vm.startPrank(client);
        _lockAsOwner(orch.pxt(), orch.hook(), orch.collector(), client, safe, callers);
        orch.markLocked(safe);
        vm.stopPrank();

        address staking = makeAddr("staking");
        vm.etch(staking, hex"00");
        Pxt token = orch.pxt();
        vm.prank(safe);
        token.setApprovedContractRecipient(staking, true);
        assertTrue(token.isApprovedContractRecipient(staking));
    }

    /// @dev External wrapper so `vm.expectRevert` can catch `_lockAsOwner` reverts.
    function lockExternal(
        Pxt token,
        PhoenixV4ReturnDeltaHook h,
        PhoenixFeeCollector fc,
        address launchOwner,
        address recipientApprover,
        address[] calldata buybackCallers
    ) external {
        _lockAsOwner(token, h, fc, launchOwner, recipientApprover, buybackCallers);
    }

    function _createToken() internal returns (PhoenixOrchestrator orch) {
        vm.prank(client);
        orch = launcher.create(SALT);
        assertEq(address(orch), launcher.predictOrchestrator(client, SALT));

        bytes memory pxtInit =
            abi.encodePacked(type(Pxt).creationCode, abi.encode(client, donation, marketing, sellUnlock));
        address predictedPxt =
            HookMiner.computeAddress(address(pxtDeployer), uint256(launcher.pxtCreate2Salt(address(orch))), pxtInit);

        vm.prank(client);
        Pxt token = orch.createToken(donation, marketing, sellUnlock);
        assertEq(address(token), predictedPxt);
    }

    function _deployPool(PhoenixOrchestrator orch) internal {
        PhoenixLaunchTypes.LaunchParams memory p = _poolParams(orch);
        vm.startPrank(client);
        (PhoenixV4ReturnDeltaHook h, PhoenixFeeCollector fc, PhoenixAntiBotOpenSell os) = orch.deployPoolContracts(p);
        uint160 sqrtPrice = _configureAndInit(p, orch.pxt(), h, fc, os, client, orch.tickLower(), orch.tickUpper());
        orch.markPoolConfigured(sqrtPrice);
        vm.stopPrank();
    }

    function _seed(PhoenixOrchestrator orch) internal {
        // Ensure client has pxtSeed (may have sent rest to MAIN).
        Pxt token = orch.pxt();
        uint256 need = orch.pxtSeed();
        uint256 have = token.balanceOf(client);
        if (have < need) {
            vm.prank(mainWallet);
            token.transfer(client, need - have);
        }
        if (musdc.balanceOf(client) < orch.usdcSeed()) {
            musdc.mint(client, orch.usdcSeed() - musdc.balanceOf(client));
        }

        vm.startPrank(client);
        _seedAsOwner(
            token,
            orch.collector(),
            address(musdc),
            orch.pxtSeed(),
            orch.usdcSeed(),
            orch.sqrtPriceX96(),
            orch.tickLower(),
            orch.tickUpper(),
            0
        );
        orch.markSeeded();
        vm.stopPrank();
    }

    function _poolParams(PhoenixOrchestrator orch) internal view returns (PhoenixLaunchTypes.LaunchParams memory p) {
        address predictedPxt = address(orch.pxt());
        (, bytes32 hookSalt) = HookMiner.find(
            address(hookDeployer),
            launcher.hookFlags(),
            type(PhoenixV4ReturnDeltaHook).creationCode,
            abi.encode(manager, predictedPxt, client, client)
        );

        p.poolManager = manager;
        p.quoteToken = address(musdc);
        p.donation = donation;
        p.marketing = marketing;
        p.operator = client;
        p.swapRouter = address(swapRouter);
        p.lpRouter = address(lpRouter);
        p.positionManager = address(0);
        p.universalRouter = ur;
        p.sellUnlockTimestamp = sellUnlock;
        p.pxtSeed = pxtSeed;
        p.usdcSeed = usdcSeed;
        p.sqrtPriceX96 = 0;
        p.tickLower = 0;
        p.tickUpper = 0;
        p.recycleWidthSpacings = 10;
        p.maxBuybackSlippageBps = 200;
        p.hookSalt = hookSalt;
        p.feeExempt = new address[](0);
        p.noPenalty = new address[](0);
    }
}
