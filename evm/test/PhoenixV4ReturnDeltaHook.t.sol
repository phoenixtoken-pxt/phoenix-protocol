// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {Pxt} from "../src/core/Pxt.sol";
import {PhoenixAntiBotOpenSell} from "../script/PhoenixAntiBotOpenSell.sol";
import {PhoenixV4ReturnDeltaHook} from "../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {PhoenixFeeCollector} from "../src/fee/PhoenixFeeCollector.sol";
import {PhoenixBuyback} from "../src/fee/PhoenixBuyback.sol";
import {PhoenixBuybackMath} from "../src/fee/PhoenixBuybackMath.sol";
import {LockProtocolReturnDelta} from "../script/LockProtocolReturnDelta.s.sol";
import {ISellAttributor} from "../src/return-delta/ISellAttributor.sol";
import {HookMiner} from "../src/uniswap/v4/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeKind, PxtFeeModel} from "../src/core/PxtFeeModel.sol";

/// @dev Hostile / multi-hop unlocker: sell then second swap or finalize before ERC-20 settle.
contract PendingSellUnlockProbe is IUnlockCallback {
    enum AfterFirst {
        SecondSwap,
        Finalize
    }

    IPoolManager public immutable manager;
    PhoenixV4ReturnDeltaHook public immutable hook;

    constructor(IPoolManager manager_, PhoenixV4ReturnDeltaHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function attack(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData, AfterFirst next)
        external
    {
        manager.unlock(abi.encode(key, params, hookData, next));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, SwapParams memory params, bytes memory hookData, AfterFirst next) =
            abi.decode(rawData, (PoolKey, SwapParams, bytes, AfterFirst));

        // First sell — records orphan + transient; do not settle yet.
        manager.swap(key, params, hookData);

        if (next == AfterFirst.SecondSwap) {
            manager.swap(key, params, hookData);
        } else {
            hook.finalizeOrphanedSell();
        }
        return bytes("");
    }
}

// Return-delta: USDC skims → FeeCollector pending; collect / buyback deferred.
contract PhoenixV4ReturnDeltaHookTest is Test {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using stdStorage for StdStorage;

    uint256 internal constant WHOLE = 1e6;
    uint24 internal constant LP_FEE = 0;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -60_000;
    int24 internal constant TICK_UPPER = 60_000;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;

    Pxt internal pxt;
    MockERC20 internal musdc;
    PhoenixV4ReturnDeltaHook internal hook;
    PhoenixFeeCollector internal feeCollector;
    PhoenixAntiBotOpenSell internal openSell;
    PoolKey internal key;

    address internal admin = makeAddr("admin");
    address internal donation = makeAddr("donation");
    address internal marketing = makeAddr("marketing");
    address internal alice = makeAddr("alice");
    address internal antiBot = makeAddr("antiBot");

    uint256 internal sellUnlock;

    function setUp() public {
        sellUnlock = block.timestamp + 30 days;

        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        vm.startPrank(admin);
        pxt = new Pxt(admin, donation, marketing, sellUnlock);
        musdc = new MockERC20("Mock USDC", "mUSDC", 6, admin);
        pxt.setPoolManager(address(manager));

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), flags, type(PhoenixV4ReturnDeltaHook).creationCode, abi.encode(manager, pxt, antiBot, admin)
        );
        vm.stopPrank();

        hook = new PhoenixV4ReturnDeltaHook{salt: salt}(manager, pxt, antiBot, admin);
        require(address(hook) == hookAddr, "hook addr");

        vm.startPrank(admin);
        feeCollector = new PhoenixFeeCollector(manager, pxt, donation, marketing, admin);
        feeCollector.setHook(address(hook));
        hook.setFeeCollector(feeCollector);
        pxt.setFeeCollector(address(feeCollector));

        pxt.setApprovedContractRecipient(address(hook), true);
        pxt.setWalletStatus(address(hook), Pxt.WalletStatus.FeeExempt);
        pxt.setApprovedContractRecipient(address(feeCollector), true);
        pxt.setWalletStatus(address(feeCollector), Pxt.WalletStatus.FeeExempt);
        pxt.setApprovedContractRecipient(address(lpRouter), true);
        pxt.setApprovedContractRecipient(address(swapRouter), true);
        pxt.setSellAttributor(hook);

        // Operator EOA funds the ceremony; on-chain antiBotSeller is the helper (no tx.origin).
        openSell = new PhoenixAntiBotOpenSell(pxt, swapRouter, antiBot);
        pxt.setApprovedContractRecipient(address(openSell), true);
        pxt.setWalletStatus(address(openSell), Pxt.WalletStatus.FeeExempt);
        pxt.setAntiBotSeller(address(openSell));

        key = _poolKey();
        hook.setOfficialPool(key);
        feeCollector.configurePool(key, TICK_LOWER, TICK_UPPER, bytes32(0));
        feeCollector.setBuybackParams(10, 200);

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        manager.initialize(key, sqrtPrice);

        uint256 seedAmount = 10_000_000 * WHOLE;
        musdc.mint(admin, seedAmount);
        IERC20(address(pxt)).approve(address(feeCollector), type(uint256).max);
        IERC20(address(musdc)).approve(address(feeCollector), type(uint256).max);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            seedAmount,
            seedAmount
        );
        feeCollector.addLiquidity(seedAmount, seedAmount, liquidity, abi.encode(address(feeCollector)));

        musdc.mint(alice, 100_000 * WHOLE);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.FeeExempt);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        pxt.transfer(alice, 100_000 * WHOLE);
        pxt.transfer(antiBot, 100_000 * WHOLE);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.Normal);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.Normal);
        vm.stopPrank();
    }

    function test_hook_flags_have_return_delta() public view {
        uint160 f = hook.flags();
        assertEq(f & Hooks.BEFORE_ADD_LIQUIDITY_FLAG, Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        assertEq(f & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        assertEq(f & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG, Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        assertEq(f & Hooks.BEFORE_SWAP_FLAG, Hooks.BEFORE_SWAP_FLAG);
        assertEq(f & Hooks.AFTER_SWAP_FLAG, Hooks.AFTER_SWAP_FLAG);
    }

    function test_lp_gate_blocks_stranger_during_sell_lock() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(admin);
        musdc.mint(stranger, 1_000 * WHOLE);
        pxt.transfer(stranger, 1_000 * WHOLE);
        vm.stopPrank();

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            100 * WHOLE,
            100 * WHOLE
        );

        vm.startPrank(stranger);
        IERC20(address(pxt)).approve(address(lpRouter), type(uint256).max);
        musdc.approve(address(lpRouter), type(uint256).max);
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(uint256(1))
            }),
            abi.encode(stranger)
        );
        vm.stopPrank();
    }

    function test_lp_gate_allows_stranger_after_sell_unlock() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(admin);
        musdc.mint(stranger, 1_000 * WHOLE);
        pxt.transfer(stranger, 1_000 * WHOLE);
        vm.stopPrank();

        vm.warp(sellUnlock);
        // Public LP settle is user→PoolManager; anti-bot must be cleared first.
        _clearAntiBot();

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            100 * WHOLE,
            100 * WHOLE
        );

        vm.startPrank(stranger);
        IERC20(address(pxt)).approve(address(lpRouter), type(uint256).max);
        musdc.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(uint256(2))
            }),
            abi.encode(stranger)
        );
        vm.stopPrank();
    }

    function test_buy_skims_usdc_to_fee_collector() public {
        uint256 amountIn = 1_000 * WHOLE;
        uint256 expectDon = (amountIn * PxtFeeModel.BUY_DONATION_BPS) / PxtFeeModel.BPS;
        uint256 expectMkt = (amountIn * PxtFeeModel.BUY_FEE_BPS) / PxtFeeModel.BPS - expectDon;

        uint256 alicePxtBefore = pxt.balanceOf(alice);

        _buy(alice, amountIn);

        (uint256 pendDon, uint256 pendMkt,, uint256 pendBb) = feeCollector.pending(address(musdc));
        assertEq(pendDon, expectDon);
        assertEq(pendMkt, expectMkt);
        assertEq(pendBb, 0);
        assertGt(pxt.balanceOf(alice), alicePxtBefore);

        feeCollector.collect();
        assertEq(musdc.balanceOf(donation), expectDon);
        assertEq(musdc.balanceOf(marketing), expectMkt);
    }

    function test_setHook_is_one_shot() public {
        vm.prank(admin);
        vm.expectRevert(PhoenixBuyback.HookAlreadySet.selector);
        feeCollector.setHook(makeAddr("otherHook"));
    }

    function test_buy_fee_exempt_still_pays_usdc_fee() public {
        // DEX FeeExempt no longer bypasses buy fees (no spoofable identity).
        vm.prank(admin);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.FeeExempt);

        uint256 amountIn = 1_000 * WHOLE;
        _buy(alice, amountIn);

        (uint256 pendDon,,,) = feeCollector.pending(address(musdc));
        assertEq(pendDon, (amountIn * PxtFeeModel.BUY_DONATION_BPS) / PxtFeeModel.BPS);
    }

    function test_sell_reverts_before_unlock() public {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(pxt);
        vm.startPrank(alice);
        IERC20(address(pxt)).approve(address(swapRouter), type(uint256).max);
        // Hook revert is wrapped by PoolManager (sell lock gate runs in beforeSwap).
        vm.expectRevert(); // WrappedError(SellsLocked) from PoolManager
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -(100 * WHOLE).toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice)
        );
        vm.stopPrank();
    }

    /// @dev Claim settle cannot bypass hook sell lock.
    function test_erc6909_sell_reverts_before_unlock() public {
        uint256 amountIn = 1_000 * WHOLE;
        bool buyZfo = Currency.unwrap(key.currency0) == address(musdc);
        vm.startPrank(alice);
        musdc.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: buyZfo,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: buyZfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            abi.encode(alice)
        );

        uint256 sellAmount = manager.balanceOf(alice, uint256(uint160(address(pxt)))) / 2;
        assertGt(sellAmount, 0);
        bool sellZfo = Currency.unwrap(key.currency0) == address(pxt);
        vm.expectRevert(); // WrappedError(SellsLocked) from PoolManager
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: sellZfo,
                amountSpecified: -sellAmount.toInt256(),
                sqrtPriceLimitX96: sellZfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: true}),
            abi.encode(alice)
        );
        vm.stopPrank();
    }

    /// @dev After unlock but before clearSellProtection, ERC-6909 sells are blocked.
    function test_erc6909_sell_reverts_until_antibot_cleared() public {
        uint256 amountIn = 1_000 * WHOLE;
        bool buyZfo = Currency.unwrap(key.currency0) == address(musdc);
        vm.startPrank(alice);
        musdc.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: buyZfo,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: buyZfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            abi.encode(alice)
        );

        uint256 sellAmount = manager.balanceOf(alice, uint256(uint160(address(pxt)))) / 2;
        assertGt(sellAmount, 0);
        bool sellZfo = Currency.unwrap(key.currency0) == address(pxt);

        vm.warp(sellUnlock);
        manager.setOperator(address(swapRouter), true);
        vm.expectRevert(); // WrappedError(AntiBotSellBlocked)
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: sellZfo,
                amountSpecified: -sellAmount.toInt256(),
                sqrtPriceLimitX96: sellZfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: true}),
            abi.encode(alice)
        );
        vm.stopPrank();

        _clearAntiBot();
        vm.startPrank(alice);
        manager.setOperator(address(swapRouter), true);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: sellZfo,
                amountSpecified: -sellAmount.toInt256(),
                sqrtPriceLimitX96: sellZfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: true}),
            abi.encode(alice)
        );
        vm.stopPrank();
    }

    /// @dev ERC-6909 sell leaves skim on hook until finalizeOrphanedSell accrues penalty.
    function test_erc6909_sell_finalize_orphaned_skim() public {
        _openSells();

        uint256 amountIn = 5_000 * WHOLE;
        bool buyZfo = Currency.unwrap(key.currency0) == address(musdc);
        vm.startPrank(alice);
        musdc.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: buyZfo,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: buyZfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            abi.encode(alice)
        );

        uint256 claims = manager.balanceOf(alice, uint256(uint160(address(pxt))));
        uint256 sellAmount = claims / 2;
        assertGt(sellAmount, 0);

        uint256 hookUsdcBefore = musdc.balanceOf(address(hook));
        (,,, uint256 pendBbBefore) = feeCollector.pending(address(musdc));

        bool sellZfo = Currency.unwrap(key.currency0) == address(pxt);
        // PoolSwapTest burns claims from `sender`; approve it as ERC-6909 operator.
        manager.setOperator(address(swapRouter), true);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: sellZfo,
                amountSpecified: -sellAmount.toInt256(),
                sqrtPriceLimitX96: sellZfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: true}),
            abi.encode(alice)
        );
        vm.stopPrank();

        (uint128 pxtIn, uint128 usdcOut, uint128 usdcSkim, address quote) = hook.orphanSkim();
        assertGt(usdcSkim, 0);
        assertEq(quote, address(musdc));
        assertGt(pxtIn, 0);
        assertGt(usdcOut, 0);
        assertEq(musdc.balanceOf(address(hook)), hookUsdcBefore + usdcSkim);
        (,,, uint256 pendBbMid) = feeCollector.pending(address(musdc));
        assertEq(pendBbMid, pendBbBefore); // not yet accrued

        hook.finalizeOrphanedSell();

        (,, uint128 skimLeft,) = hook.orphanSkim();
        assertEq(skimLeft, 0);
        assertEq(musdc.balanceOf(address(hook)), hookUsdcBefore);
        (,,, uint256 pendBbAfter) = feeCollector.pending(address(musdc));
        assertGt(pendBbAfter, pendBbBefore);
    }

    /// @dev Second swap in the same unlock before ERC-20 settle must revert (PendingSellOpen).
    function test_second_swap_before_settle_reverts() public {
        _openSells();
        PendingSellUnlockProbe probe = new PendingSellUnlockProbe(manager, hook);

        bool zeroForOne = Currency.unwrap(key.currency0) == address(pxt);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -(100 * WHOLE).toInt256(),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // PoolManager wraps hook revert (PendingSellOpen).
        vm.expectRevert();
        probe.attack(key, params, abi.encode(alice), PendingSellUnlockProbe.AfterFirst.SecondSwap);

        (,, uint128 skim,) = hook.orphanSkim();
        assertEq(skim, 0); // whole unlock reverted — no leftover orphan
    }

    /// @dev finalizeOrphanedSell during unlock while transient pending must revert.
    function test_finalize_during_unlock_before_settle_reverts() public {
        _openSells();
        PendingSellUnlockProbe probe = new PendingSellUnlockProbe(manager, hook);

        bool zeroForOne = Currency.unwrap(key.currency0) == address(pxt);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -(100 * WHOLE).toInt256(),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.expectRevert();
        probe.attack(key, params, abi.encode(alice), PendingSellUnlockProbe.AfterFirst.Finalize);

        (,, uint128 skim,) = hook.orphanSkim();
        assertEq(skim, 0);
    }

    /// @dev Normal ERC-20 sell still attributes / rebates after settle (FeeExempt).
    function test_erc20_sell_still_rebates_after_settle() public {
        vm.prank(admin);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.FeeExempt);
        _openSells();

        uint256 aliceUsdcBefore = musdc.balanceOf(alice);
        (,,, uint256 pendBbBefore) = feeCollector.pending(address(musdc));
        _sell(alice, 500 * WHOLE);

        // FeeExempt: full USDC skim refunded; burn still applies — no buyback accrual from skim.
        assertGt(musdc.balanceOf(alice), aliceUsdcBefore);
        (,,, uint256 pendBbAfter) = feeCollector.pending(address(musdc));
        assertEq(pendBbAfter, pendBbBefore);
        (,, uint128 skim,) = hook.orphanSkim();
        assertEq(skim, 0);
    }

    function test_sell_locked_even_with_spoofed_hookData() public {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(pxt);
        vm.startPrank(alice);
        IERC20(address(pxt)).approve(address(swapRouter), type(uint256).max);
        vm.expectRevert(); // WrappedError(SellsLocked) from PoolManager
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -(10 * WHOLE).toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(antiBot)
        );
        vm.stopPrank();
    }

    function test_sell_antibot_blocks_non_seller() public {
        vm.warp(sellUnlock);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(pxt);
        vm.startPrank(alice);
        IERC20(address(pxt)).approve(address(swapRouter), type(uint256).max);
        // Hook enforceTradingOpen reverts before Pxt settle (WrappedError).
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -(100 * WHOLE).toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice)
        );
        vm.stopPrank();
    }

    function test_sell_antibot_then_opens() public {
        vm.warp(sellUnlock);

        // beforeSwap enforceTradingOpen — first sell cannot clear mid-swap.
        bool zeroForOne = Currency.unwrap(key.currency0) == address(pxt);
        vm.startPrank(antiBot);
        IERC20(address(pxt)).approve(address(swapRouter), type(uint256).max);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -(100 * WHOLE).toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(antiBot)
        );
        vm.stopPrank();

        uint256 aliceBefore = musdc.balanceOf(alice);
        _clearAntiBot();
        assertTrue(hook.sellProtectionCleared());

        _sell(antiBot, 100 * WHOLE);
        _sell(alice, 50 * WHOLE);
        assertGt(musdc.balanceOf(alice), aliceBefore);
    }

    function test_open_trading_atomic_clear_and_sell() public {
        vm.warp(sellUnlock);

        uint256 amountIn = 100 * WHOLE;
        uint256 antiBotMusdcBefore = musdc.balanceOf(antiBot);
        uint256 aliceMusdcBefore = musdc.balanceOf(alice);

        vm.startPrank(alice);
        IERC20(address(pxt)).approve(address(swapRouter), type(uint256).max);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: Currency.unwrap(key.currency0) == address(pxt),
                amountSpecified: -(50 * WHOLE).toInt256(),
                sqrtPriceLimitX96: Currency.unwrap(key.currency0) == address(pxt)
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice)
        );
        vm.stopPrank();

        vm.startPrank(antiBot, antiBot);
        IERC20(address(pxt)).approve(address(openSell), amountIn);
        openSell.openWithExactInSell(key, amountIn, bytes(""));
        vm.stopPrank();

        assertTrue(pxt.sellProtectionCleared());
        assertGt(musdc.balanceOf(antiBot), antiBotMusdcBefore);

        _sell(alice, 50 * WHOLE);
        assertGt(musdc.balanceOf(alice), aliceMusdcBefore);
    }

    function test_open_trading_reverts_for_non_antibot() public {
        vm.warp(sellUnlock);
        vm.startPrank(alice);
        IERC20(address(pxt)).approve(address(openSell), 10 * WHOLE);
        vm.expectRevert(PhoenixAntiBotOpenSell.NotOperator.selector);
        openSell.openWithExactInSell(key, 10 * WHOLE, bytes(""));
        vm.stopPrank();
        assertFalse(pxt.sellProtectionCleared());
    }

    function test_sell_burns_pxt_and_skims_usdc() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        vm.warp(sellUnlock);
        _clearAntiBot();
        _sell(antiBot, 1 * WHOLE);

        uint256 sellAmount = 1_000 * WHOLE;
        uint256 expectBurn = (sellAmount * PxtFeeModel.SELL_BURN_BPS) / PxtFeeModel.BPS;

        uint256 supplyBefore = pxt.totalSupply();
        uint256 aliceMusdcBefore = musdc.balanceOf(alice);

        _sell(alice, sellAmount);

        assertEq(pxt.totalSupply(), supplyBefore - expectBurn);
        assertGt(musdc.balanceOf(alice), aliceMusdcBefore);

        (uint256 pendDon, uint256 pendMkt,, uint256 pendBb) = feeCollector.pending(address(musdc));
        uint256 usdcSkimmed = pendDon + pendMkt + pendBb;
        uint256 aliceUsdcNet = musdc.balanceOf(alice) - aliceMusdcBefore;
        uint256 usdcOutGross = aliceUsdcNet + usdcSkimmed;

        uint256 expectDon = (usdcOutGross * PxtFeeModel.SELL_DONATION_BPS) / PxtFeeModel.BPS;
        uint256 expectMkt = (usdcOutGross * PxtFeeModel.SELL_MARKETING_BPS) / PxtFeeModel.BPS;
        uint256 expectBb = (usdcOutGross * PxtFeeModel.SELL_USDC_FEE_BPS) / PxtFeeModel.BPS - expectDon - expectMkt;
        assertEq(pendDon, expectDon);
        assertEq(pendMkt, expectMkt);
        assertEq(pendBb, expectBb);

        feeCollector.collect();
        assertEq(musdc.balanceOf(donation), pendDon);
        assertEq(musdc.balanceOf(marketing), pendMkt);
        // Buyback stays pending for executeBuyback (not paid out by collect).
        (,,, uint256 pendBbAfter) = feeCollector.pending(address(musdc));
        assertEq(pendBbAfter, pendBb);
    }

    function test_sell_fee_exempt_refunds_usdc_still_burns() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        vm.warp(sellUnlock);
        _clearAntiBot();
        _sell(antiBot, 1 * WHOLE);

        vm.prank(admin);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.FeeExempt);

        uint256 sellAmount = 1_000 * WHOLE;
        uint256 expectBurn = (sellAmount * PxtFeeModel.SELL_BURN_BPS) / PxtFeeModel.BPS;
        uint256 supplyBefore = pxt.totalSupply();

        _sell(alice, sellAmount);

        assertEq(pxt.totalSupply(), supplyBefore - expectBurn);
        (uint256 pendDon, uint256 pendMkt,, uint256 pendBb) = feeCollector.pending(address(musdc));
        assertEq(pendDon, 0);
        assertEq(pendMkt, 0);
        assertEq(pendBb, 0);
    }

    function test_sell_antibot_feeExempt_clears_protection() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);

        vm.warp(sellUnlock);
        // clearSellProtection required before any hook sell.
        _clearAntiBot();
        assertTrue(hook.sellProtectionCleared());
        _sell(antiBot, 100 * WHOLE);
        _sell(alice, 50 * WHOLE);
    }

    function test_sell_penalty_skims_higher_buyback() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        vm.warp(sellUnlock);
        _clearAntiBot();
        _sell(antiBot, 1 * WHOLE);

        // >10% of alice's balance in the penalty window → 37.8% tier.
        uint256 sellAmount = 15_000 * WHOLE;
        uint256 expectBurn = (sellAmount * PxtFeeModel.PENALTY_BURN_BPS) / PxtFeeModel.BPS;

        uint256 supplyBefore = pxt.totalSupply();
        uint256 aliceMusdcBefore = musdc.balanceOf(alice);

        _sell(alice, sellAmount);

        assertEq(pxt.totalSupply(), supplyBefore - expectBurn);

        (uint256 pendDon, uint256 pendMkt,, uint256 pendBb) = feeCollector.pending(address(musdc));
        uint256 usdcSkimmed = pendDon + pendMkt + pendBb;
        uint256 aliceUsdcNet = musdc.balanceOf(alice) - aliceMusdcBefore;
        uint256 usdcOutGross = aliceUsdcNet + usdcSkimmed;

        uint256 expectDon = (usdcOutGross * PxtFeeModel.PENALTY_DONATION_BPS) / PxtFeeModel.BPS;
        uint256 expectMkt = (usdcOutGross * PxtFeeModel.PENALTY_MARKETING_BPS) / PxtFeeModel.BPS;
        uint256 expectBb = (usdcOutGross * PxtFeeModel.PENALTY_USDC_FEE_BPS) / PxtFeeModel.BPS - expectDon - expectMkt;
        assertEq(pendDon, expectDon);
        assertEq(pendMkt, expectMkt);
        assertEq(pendBb, expectBb);
        assertGt(pendBb, (usdcOutGross * PxtFeeModel.SELL_USDC_FEE_BPS) / PxtFeeModel.BPS);
    }

    /// @dev Exact-out settle is swapPxt + burn; attribution must use that size (not swap-only).
    function test_exact_out_sell_attributes_and_burns() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        _openSells();
        _sell(antiBot, 1 * WHOLE);

        uint256 usdcOut = 500 * WHOLE;
        uint256 supplyBefore = pxt.totalSupply();
        uint256 alicePxtBefore = pxt.balanceOf(alice);
        uint256 aliceMusdcBefore = musdc.balanceOf(alice);

        _sellExactOut(alice, usdcOut);

        // Completes without PendingSellMismatch; burn + base-tier USDC fees after rebate.
        assertLt(pxt.totalSupply(), supplyBefore);
        assertLt(pxt.balanceOf(alice), alicePxtBefore);
        assertGt(musdc.balanceOf(alice), aliceMusdcBefore);

        (uint256 pendDon, uint256 pendMkt,, uint256 pendBb) = feeCollector.pending(address(musdc));
        uint256 expectDon = (usdcOut * PxtFeeModel.SELL_DONATION_BPS) / PxtFeeModel.BPS;
        uint256 expectMkt = (usdcOut * PxtFeeModel.SELL_MARKETING_BPS) / PxtFeeModel.BPS;
        uint256 expectBb = (usdcOut * PxtFeeModel.SELL_USDC_FEE_BPS) / PxtFeeModel.BPS - expectDon - expectMkt;
        assertEq(pendDon, expectDon);
        assertEq(pendMkt, expectMkt);
        assertEq(pendBb, expectBb);
    }

    function test_exact_out_sell_penalty_tier() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        _openSells();
        _sell(antiBot, 1 * WHOLE);

        // Large exact-out vs alice's bag → penalty USDC skim kept (no rebate to base sell).
        uint256 usdcOut = 8_000 * WHOLE;
        uint256 aliceMusdcBefore = musdc.balanceOf(alice);

        _sellExactOut(alice, usdcOut);

        assertGt(musdc.balanceOf(alice), aliceMusdcBefore);

        (uint256 pendDon, uint256 pendMkt,, uint256 pendBb) = feeCollector.pending(address(musdc));
        uint256 expectDon = (usdcOut * PxtFeeModel.PENALTY_DONATION_BPS) / PxtFeeModel.BPS;
        uint256 expectMkt = (usdcOut * PxtFeeModel.PENALTY_MARKETING_BPS) / PxtFeeModel.BPS;
        uint256 expectBb = (usdcOut * PxtFeeModel.PENALTY_USDC_FEE_BPS) / PxtFeeModel.BPS - expectDon - expectMkt;
        assertEq(pendDon, expectDon);
        assertEq(pendMkt, expectMkt);
        assertEq(pendBb, expectBb);
    }

    function test_exact_out_fee_exempt_refunds_usdc_still_burns() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        _openSells();
        _sell(antiBot, 1 * WHOLE);

        vm.prank(admin);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.FeeExempt);

        uint256 usdcOut = 500 * WHOLE;
        uint256 supplyBefore = pxt.totalSupply();
        uint256 aliceMusdcBefore = musdc.balanceOf(alice);

        _sellExactOut(alice, usdcOut);

        assertLt(pxt.totalSupply(), supplyBefore);
        assertGt(musdc.balanceOf(alice), aliceMusdcBefore);
        (uint256 pendDon, uint256 pendMkt,, uint256 pendBb) = feeCollector.pending(address(musdc));
        assertEq(pendDon, 0);
        assertEq(pendMkt, 0);
        assertEq(pendBb, 0);
    }

    function test_partial_usdc_buyback() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        vm.warp(sellUnlock);
        _clearAntiBot();
        _sell(antiBot, 1 * WHOLE);

        _sell(alice, 1_000 * WHOLE);
        feeCollector.collect();

        (,,, uint256 pendBb) = feeCollector.pending(address(musdc));
        assertGt(pendBb, 1);
        uint256 half = pendBb / 2;

        feeCollector.executeBuyback(half, 0, block.timestamp + 1);
        (,,, uint256 pendAfter) = feeCollector.pending(address(musdc));
        assertEq(pendAfter, pendBb - half);
        assertGt(feeCollector.recyclePxt(), 0);
    }

    /// @dev Protocol buyback must not re-accrue the 2.7% buy skim (FeeCollector is swap sender).
    function test_buyback_skips_hook_buy_fee() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        vm.warp(sellUnlock);
        _clearAntiBot();
        _sell(antiBot, 1 * WHOLE);

        _sell(alice, 1_000 * WHOLE);
        feeCollector.collect();

        (uint256 donBefore, uint256 mktBefore,, uint256 pendBb) = feeCollector.pending(address(musdc));
        assertGt(pendBb, 1);

        uint256 spend = pendBb / 2;
        feeCollector.executeBuyback(spend, 0, block.timestamp + 1);

        (uint256 donAfter, uint256 mktAfter,, uint256 pendAfter) = feeCollector.pending(address(musdc));
        assertEq(pendAfter, pendBb - spend);
        // No new buy-fee donation/marketing from the buyback swap itself.
        assertEq(donAfter, donBefore);
        assertEq(mktAfter, mktBefore);
        assertGt(feeCollector.recyclePxt(), 0);
    }

    function test_recycle_band_cap_and_prune() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        vm.warp(sellUnlock);
        _clearAntiBot();

        assertEq(feeCollector.MAX_RECYCLE_BANDS(), 32);

        _sell(antiBot, 1 * WHOLE);
        _sell(alice, 2_000 * WHOLE);
        feeCollector.collect();
        (,,, uint256 pendBb) = feeCollector.pending(address(musdc));
        assertGt(pendBb, 0);
        feeCollector.executeBuyback(0, 0, block.timestamp + 1);
        assertEq(feeCollector.recycleBandCount(), 1);
        assertEq(feeCollector.pruneEmptyRecycleBands(), 0);
        assertEq(feeCollector.recycleBandCount(), 1);
        assertLe(feeCollector.recycleBandCount(), uint256(feeCollector.MAX_RECYCLE_BANDS()));
    }

    /// @dev Full registry + price into recycle bands → reuse must not mint quote-side / drain USDC.
    function test_recycle_reuse_reverts_when_bands_not_pxt_only() public {
        vm.startPrank(admin);
        feeCollector.setBuybackParams(1, 5_000);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        musdc.mint(alice, 50_000_000 * WHOLE);
        pxt.transfer(alice, 500_000 * WHOLE);
        vm.stopPrank();

        _openSells();
        _sell(antiBot, 1 * WHOLE);
        // Normal seller so USDC skims accrue (FeeExempt refunds sell skims).
        _sell(alice, 50_000 * WHOLE);
        feeCollector.collect();

        (uint256 pendDon0, uint256 pendMkt0,, uint256 pendBb0) = feeCollector.pending(address(musdc));
        assertGt(pendBb0, 0);

        uint256 maxBands = feeCollector.MAX_RECYCLE_BANDS();
        uint256 spendPer = pendBb0 / (maxBands + 2);
        assertGt(spendPer, 0);

        bool pxtIsToken0 = Currency.unwrap(key.currency0) == address(pxt);

        for (uint256 i = 0; i < maxBands; i++) {
            (, int24 tickBefore,,) = manager.getSlot0(key.toId());
            int24 floorBefore = PhoenixBuybackMath.floorToSpacing(tickBefore, TICK_SPACING);

            feeCollector.executeBuyback(spendPer, 0, block.timestamp + 1);
            assertEq(feeCollector.recycleBandCount(), i + 1);

            // Push spot toward the recycle side until the next ideal band would differ.
            uint256 guard;
            while (guard < 40) {
                _buy(alice, 50_000 * WHOLE);
                (, int24 tickAfter,,) = manager.getSlot0(key.toId());
                int24 floorAfter = PhoenixBuybackMath.floorToSpacing(tickAfter, TICK_SPACING);
                if (pxtIsToken0) {
                    if (floorAfter > floorBefore) break;
                } else if (floorAfter < floorBefore) {
                    break;
                }
                unchecked {
                    ++guard;
                }
            }
            require(guard < 40, "spot did not advance");
        }

        assertEq(feeCollector.recycleBandCount(), maxBands);

        // Cross remaining PXT-only bands so reuse has nowhere safe to mint.
        uint256 guard2;
        while (_hasPxtOnlyRecycleBand(pxtIsToken0) && guard2 < 80) {
            _buy(alice, 100_000 * WHOLE);
            unchecked {
                ++guard2;
            }
        }
        assertFalse(_hasPxtOnlyRecycleBand(pxtIsToken0));

        (uint256 pendDon, uint256 pendMkt,, uint256 pendBb) = feeCollector.pending(address(musdc));
        uint256 usdcBal = musdc.balanceOf(address(feeCollector));

        vm.expectRevert(PhoenixBuyback.RecycleBandNotPxtOnly.selector);
        feeCollector.executeBuyback(spendPer, 0, block.timestamp + 1);

        (uint256 pendDonAfter, uint256 pendMktAfter,, uint256 pendBbAfter) = feeCollector.pending(address(musdc));
        assertEq(pendDonAfter, pendDon);
        assertEq(pendMktAfter, pendMkt);
        assertEq(pendBbAfter, pendBb);
        assertEq(musdc.balanceOf(address(feeCollector)), usdcBal);
        // Donation/marketing pending from the initial sell must still be solvent on the collector.
        assertGe(usdcBal, pendDon0 + pendMkt0 + pendBbAfter);
    }

    function _hasPxtOnlyRecycleBand(bool pxtIsToken0) internal view returns (bool) {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        uint256 n = feeCollector.recycleBandCount();
        for (uint256 i = 0; i < n; i++) {
            (int24 lo, int24 hi) = feeCollector.recycleBands(i);
            if (PhoenixBuybackMath.isPxtOnlyBand(tick, lo, hi, pxtIsToken0)) return true;
        }
        return false;
    }

    function test_receive_accrued_fees_ignores_non_pxt_burn() public {
        uint256 donationAmt = 100 * WHOLE;
        uint256 marketingAmt = 50 * WHOLE;
        uint256 burnAmt = 25 * WHOLE;
        uint256 buybackAmt = 10 * WHOLE;

        vm.prank(admin);
        musdc.mint(address(hook), donationAmt + marketingAmt + burnAmt + buybackAmt);

        vm.startPrank(address(hook));
        musdc.approve(address(feeCollector), type(uint256).max);
        feeCollector.receiveAccruedFees(address(musdc), FeeKind.Sell, donationAmt, marketingAmt, burnAmt, buybackAmt);
        vm.stopPrank();

        (uint256 pendDon, uint256 pendMkt, uint256 pendBurn, uint256 pendBb) = feeCollector.pending(address(musdc));
        assertEq(pendDon, donationAmt);
        assertEq(pendMkt, marketingAmt);
        assertEq(pendBurn, 0);
        assertEq(pendBb, buybackAmt);
        assertEq(musdc.balanceOf(address(feeCollector)), donationAmt + marketingAmt + buybackAmt);
        assertEq(musdc.balanceOf(address(hook)), burnAmt);
    }

    function test_collect_clears_non_pxt_pending_burn() public {
        uint256 bogusBurn = 100 * WHOLE;
        uint256 donationDue = 50 * WHOLE;

        stdstore.target(address(feeCollector)).sig("pendingBurn(address)").with_key(address(musdc))
            .checked_write(bogusBurn);
        stdstore.target(address(feeCollector)).sig("pendingDonation(address)").with_key(address(musdc))
            .checked_write(donationDue);

        vm.prank(admin);
        musdc.mint(address(feeCollector), bogusBurn + donationDue);

        (,, uint256 burnBefore,) = feeCollector.pending(address(musdc));
        assertEq(burnBefore, bogusBurn);

        uint256 donationBalBefore = musdc.balanceOf(donation);
        feeCollector.collect();

        (uint256 pendDon, uint256 pendMkt, uint256 pendBurn,) = feeCollector.pending(address(musdc));
        assertEq(pendBurn, 0);
        assertEq(pendDon, 0);
        assertEq(pendMkt, 0);
        assertEq(musdc.balanceOf(donation), donationBalBefore + donationDue);
        // Bogus burn USDC remains on collector (buyback/other) rather than bricking collect.
        assertEq(musdc.balanceOf(address(feeCollector)), bogusBurn);
    }

    function test_pool_manager_settlement_is_fee_free_on_token() public view {
        assertEq(pxt.poolManager(), address(manager));
        assertTrue(pxt.isApprovedContractRecipient(address(manager)));
    }

    function test_lock_protocol_requires_hook_as_sell_attributor() public {
        LockProtocolReturnDelta locker = new LockProtocolReturnDelta();
        locker.requireSellAttributorIsHook(pxt, address(hook));
    }

    function test_lock_protocol_requires_matching_fee_wallets() public {
        LockProtocolReturnDelta locker = new LockProtocolReturnDelta();
        locker.requireMatchingFeeWallets(pxt, feeCollector);
    }

    function test_lock_protocol_rejects_mismatched_fee_wallets() public {
        address otherDonation = makeAddr("otherDonation");
        address otherMarketing = makeAddr("otherMarketing");
        PhoenixFeeCollector mismatched = new PhoenixFeeCollector(manager, pxt, otherDonation, otherMarketing, admin);

        LockProtocolReturnDelta locker = new LockProtocolReturnDelta();
        vm.expectRevert(LockProtocolReturnDelta.FeeWalletMismatch.selector);
        locker.requireMatchingFeeWallets(pxt, mismatched);
    }

    function test_lock_allows_buyback_slippage_below_buy_fee_bps() public {
        // Buyback swaps skip the hook buy skim, so maxBuybackSlippageBps need not exceed BUY_FEE_BPS.
        vm.startPrank(admin);
        feeCollector.setBuybackParams(10, 200);
        vm.stopPrank();

        assertEq(feeCollector.maxBuybackSlippageBps(), 200);
        assertLt(uint256(feeCollector.maxBuybackSlippageBps()), PxtFeeModel.BUY_FEE_BPS);
    }

    function test_buyback_succeeds_at_tight_slippage() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        vm.warp(sellUnlock);
        _clearAntiBot();
        _sell(antiBot, 1 * WHOLE);

        _sell(alice, 1_000 * WHOLE);
        feeCollector.collect();

        vm.prank(admin);
        // Tight band is OK now that buyback is buy-fee exempt.
        feeCollector.setBuybackParams(10, 100);

        (,,, uint256 pendBb) = feeCollector.pending(address(musdc));
        assertGt(pendBb, 1);
        feeCollector.executeBuyback(pendBb / 2, 0, block.timestamp + 1);
        (,,, uint256 pendAfter) = feeCollector.pending(address(musdc));
        assertEq(pendAfter, pendBb - pendBb / 2);
    }

    function test_lock_protocol_rejects_wrong_sell_attributor() public {
        LockProtocolReturnDelta locker = new LockProtocolReturnDelta();
        address stranger = makeAddr("wrongAttributor");
        vm.etch(stranger, hex"00");

        vm.prank(admin);
        pxt.setSellAttributor(ISellAttributor(stranger));

        vm.expectRevert(LockProtocolReturnDelta.SellAttributorMustBeHook.selector);
        locker.requireSellAttributorIsHook(pxt, address(hook));
    }

    function test_lock_renounce_keeps_collect_and_blocks_admin() public {
        address multisig = makeAddr("multisig");
        address stranger = makeAddr("stranger");

        (, uint128 positionLiq) = feeCollector.quoteBuyback();
        assertGt(positionLiq, 0);
        vm.prank(admin);
        feeCollector.setBuybackParams(10, 200);

        LockProtocolReturnDelta locker = new LockProtocolReturnDelta();
        locker.requireSellAttributorIsHook(pxt, address(hook));
        assertTrue(hook.liquidityProvider(address(feeCollector)));
        assertGt(feeCollector.maxBuybackSlippageBps(), 0);

        vm.startPrank(admin);
        pxt.grantRole(pxt.RECIPIENT_APPROVER_ROLE(), multisig);
        pxt.grantRole(pxt.DEFAULT_ADMIN_ROLE(), multisig);
        pxt.revokeRole(pxt.RECIPIENT_APPROVER_ROLE(), admin);
        pxt.renounceRole(pxt.DEFAULT_ADMIN_ROLE(), admin);

        feeCollector.renounceOwnership();
        hook.renounceOwnership();
        pxt.renounceOwnership();
        vm.stopPrank();

        assertEq(feeCollector.owner(), address(0));
        assertEq(hook.owner(), address(0));
        assertEq(pxt.owner(), address(0));
        assertTrue(pxt.hasRole(pxt.RECIPIENT_APPROVER_ROLE(), multisig));
        assertEq(address(pxt.sellAttributor()), address(hook));

        uint256 amountIn = 1_000 * WHOLE;
        _buy(alice, amountIn);
        uint256 expectDon = (amountIn * PxtFeeModel.BUY_DONATION_BPS) / PxtFeeModel.BPS;
        uint256 donationBefore = musdc.balanceOf(donation);

        vm.prank(stranger);
        feeCollector.collect();
        assertEq(musdc.balanceOf(donation), donationBefore + expectDon);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        feeCollector.setBuybackParams(1, 100);
        vm.stopPrank();
    }

    function _clearAntiBot() internal {
        vm.prank(address(openSell));
        pxt.clearSellProtection();
    }

    function _openSells() internal {
        vm.warp(sellUnlock);
        _clearAntiBot();
    }

    function _buy(address trader, uint256 amountIn) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(musdc);
        vm.startPrank(trader);
        musdc.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(trader)
        );
        vm.stopPrank();
    }

    function _sell(address trader, uint256 amountIn) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(pxt);
        vm.startPrank(trader);
        IERC20(address(pxt)).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(trader)
        );
        vm.stopPrank();
    }

    /// @dev Exact USDC out (positive amountSpecified); PXT in is unspecified (+ burn via hook delta).
    function _sellExactOut(address trader, uint256 usdcAmountOut) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(pxt);
        vm.startPrank(trader);
        IERC20(address(pxt)).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: usdcAmountOut.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(trader)
        );
        vm.stopPrank();
    }

    function _poolKey() internal view returns (PoolKey memory poolKey) {
        Currency c0;
        Currency c1;
        if (address(pxt) < address(musdc)) {
            c0 = Currency.wrap(address(pxt));
            c1 = Currency.wrap(address(musdc));
        } else {
            c0 = Currency.wrap(address(musdc));
            c1 = Currency.wrap(address(pxt));
        }
        poolKey = PoolKey({
            currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });
    }
}
