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
import {PhoenixLauncher} from "../script/launch/PhoenixLauncher.sol";
import {PhoenixOrchestrator} from "../script/launch/PhoenixOrchestrator.sol";
import {PhoenixLaunchTypes} from "../script/launch/PhoenixLaunchTypes.sol";
import {
    PhoenixPxtDeployer,
    PhoenixHookDeployer,
    PhoenixCollectorDeployer,
    PhoenixOpenSellDeployer
} from "../script/launch/PhoenixChildDeployers.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PhoenixLauncherTest is Test {
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

    function test_launch_seed_lock() public {
        PhoenixOrchestrator orch = _launch();
        Pxt pxt = orch.pxt();
        PhoenixFeeCollector fc = orch.collector();

        assertEq(pxt.owner(), address(orch));
        assertEq(orch.hook().owner(), address(orch));
        assertEq(fc.owner(), address(orch));
        assertEq(pxt.balanceOf(address(orch)), pxt.TOTAL_SUPPLY());
        assertFalse(fc.seedLiquidityAdded());
        assertTrue(pxt.isApprovedContractRecipient(address(swapRouter)));
        assertTrue(pxt.isApprovedContractRecipient(address(lpRouter)));
        assertTrue(pxt.isApprovedContractRecipient(ur));

        _seed(orch);
        assertTrue(fc.seedLiquidityAdded());
        (, uint128 liq) = fc.quoteBuyback();
        assertGt(liq, 0);
        assertEq(musdc.balanceOf(client), 0);

        uint256 leftover = pxt.balanceOf(address(orch));
        assertGt(leftover, 0);

        address[] memory callers = new address[](1);
        callers[0] = keeper;
        vm.prank(client);
        orch.lock(safe, callers);

        assertEq(pxt.owner(), address(0));
        assertEq(orch.hook().owner(), address(0));
        assertEq(fc.owner(), address(0));
        assertTrue(pxt.hasRole(pxt.DEFAULT_ADMIN_ROLE(), safe));
        assertTrue(pxt.hasRole(pxt.RECIPIENT_APPROVER_ROLE(), safe));
        assertFalse(pxt.hasRole(pxt.DEFAULT_ADMIN_ROLE(), address(orch)));
        assertTrue(fc.hasRole(fc.BUYBACK_EXECUTOR_APPROVER_ROLE(), safe));
        assertTrue(fc.isAuthorizedBuybackCaller(keeper));
        assertFalse(fc.isAuthorizedBuybackCaller(address(orch)));
        assertEq(pxt.balanceOf(client), leftover);
        assertTrue(orch.locked());
    }

    function test_predict_orchestrator_and_pxt() public view {
        address orch = launcher.predictOrchestrator(client, SALT);
        address predictedPxt = _predictPxt(orch);
        assertTrue(orch != address(0));
        assertTrue(predictedPxt != address(0));
        assertTrue(orch != predictedPxt);
    }

    function test_developer_launchFor_owner_seeds() public {
        bytes32 salt = bytes32(uint256(2));
        PhoenixLaunchTypes.LaunchParams memory p = _params(client, salt);
        PhoenixOrchestrator orch = launcher.launchFor(client, salt, p);
        assertEq(orch.launchOwner(), client);
        assertEq(address(orch), launcher.predictOrchestrator(client, salt));
        assertEq(address(orch.pxt()), _predictPxt(address(orch)));
        assertEq(launcher.latestOrchestrator(client), address(orch));

        vm.prank(stranger);
        PhoenixLaunchTypes.UsdcPermit memory permit;
        vm.expectRevert(PhoenixOrchestrator.NotLaunchOwner.selector);
        orch.seed(0, permit);

        _seed(orch);
        assertTrue(orch.collector().seedLiquidityAdded());
    }

    function test_seed_reverts_for_stranger() public {
        PhoenixOrchestrator orch = _launch();
        PhoenixLaunchTypes.UsdcPermit memory permit;
        vm.prank(stranger);
        vm.expectRevert(PhoenixOrchestrator.NotLaunchOwner.selector);
        orch.seed(0, permit);
    }

    function test_second_seed_reverts() public {
        PhoenixOrchestrator orch = _launch();
        _seed(orch);
        musdc.mint(client, usdcSeed);
        vm.startPrank(client);
        musdc.approve(address(orch), usdcSeed);
        PhoenixLaunchTypes.UsdcPermit memory permit;
        vm.expectRevert();
        orch.seed(0, permit);
        vm.stopPrank();
    }

    function test_lock_rejects_client_as_approver() public {
        PhoenixOrchestrator orch = _launch();
        _seed(orch);
        address[] memory callers = new address[](1);
        callers[0] = keeper;
        vm.prank(client);
        vm.expectRevert(PhoenixOrchestrator.RecipientApproverIsOwner.selector);
        orch.lock(client, callers);
    }

    function test_lock_requires_seed() public {
        PhoenixOrchestrator orch = _launch();
        address[] memory callers = new address[](1);
        callers[0] = keeper;
        vm.prank(client);
        vm.expectRevert(PhoenixOrchestrator.ZeroProtocolLiquidity.selector);
        orch.lock(safe, callers);
    }

    function test_wrong_hook_salt_reverts() public {
        PhoenixLaunchTypes.LaunchParams memory p = _params(client, SALT);
        p.hookSalt = bytes32(uint256(123456));
        vm.prank(client);
        vm.expectRevert();
        launcher.launch(SALT, p);
    }

    function test_post_lock_client_cannot_set_wallet_status() public {
        PhoenixOrchestrator orch = _launch();
        _seed(orch);
        address[] memory callers = new address[](1);
        callers[0] = keeper;
        vm.prank(client);
        orch.lock(safe, callers);

        Pxt token = orch.pxt();
        vm.prank(client);
        vm.expectRevert();
        token.setWalletStatus(stranger, Pxt.WalletStatus.FeeExempt);
    }

    function test_post_lock_safe_can_allowlist_recipient() public {
        PhoenixOrchestrator orch = _launch();
        _seed(orch);
        address[] memory callers = new address[](1);
        callers[0] = keeper;
        vm.prank(client);
        orch.lock(safe, callers);

        address staking = makeAddr("staking");
        vm.etch(staking, hex"00");
        Pxt token = orch.pxt();
        vm.prank(safe);
        token.setApprovedContractRecipient(staking, true);
        assertTrue(token.isApprovedContractRecipient(staking));
    }

    function _launch() internal returns (PhoenixOrchestrator orch) {
        PhoenixLaunchTypes.LaunchParams memory p = _params(client, SALT);
        vm.prank(client);
        orch = launcher.launch(SALT, p);
        assertEq(address(orch), launcher.predictOrchestrator(client, SALT));
        assertEq(address(orch.pxt()), _predictPxt(address(orch)));
    }

    function _seed(PhoenixOrchestrator orch) internal {
        vm.startPrank(client);
        musdc.approve(address(orch), usdcSeed);
        PhoenixLaunchTypes.UsdcPermit memory permit;
        orch.seed(0, permit);
        vm.stopPrank();
    }

    function _predictPxt(address orch) internal view returns (address) {
        bytes memory init = abi.encodePacked(type(Pxt).creationCode, abi.encode(orch, donation, marketing, sellUnlock));
        return HookMiner.computeAddress(address(pxtDeployer), uint256(launcher.pxtCreate2Salt(orch)), init);
    }

    function _params(address owner, bytes32 salt) internal view returns (PhoenixLaunchTypes.LaunchParams memory p) {
        address orch = launcher.predictOrchestrator(owner, salt);
        address predictedPxt = _predictPxt(orch);
        (, bytes32 hookSalt) = HookMiner.find(
            address(hookDeployer),
            launcher.hookFlags(),
            type(PhoenixV4ReturnDeltaHook).creationCode,
            abi.encode(manager, predictedPxt, owner, orch)
        );

        p.poolManager = manager;
        p.quoteToken = address(musdc);
        p.donation = donation;
        p.marketing = marketing;
        p.operator = owner;
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
