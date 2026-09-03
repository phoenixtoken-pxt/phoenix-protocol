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
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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

/// @dev MDSS: 6909-burn settle then matching ERC-20 deposit must not take the dump-tax rebate.
contract MdssMatchingDepositProbe is IUnlockCallback {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    PhoenixV4ReturnDeltaHook public immutable hook;
    Pxt public immutable pxt;

    constructor(IPoolManager manager_, PhoenixV4ReturnDeltaHook hook_, Pxt pxt_) {
        manager = manager_;
        hook = hook_;
        pxt = pxt_;
    }

    function attack(PoolKey calldata key, SwapParams calldata params, address claimHolder, address decoy) external {
        manager.unlock(abi.encode(key, params, claimHolder, decoy));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, SwapParams memory params, address claimHolder, address decoy) =
            abi.decode(rawData, (PoolKey, SwapParams, address, address));

        manager.swap(key, params, bytes(""));

        Currency pxtCur = Currency.wrap(address(pxt));
        int256 pxtDebt = manager.currencyDelta(address(this), pxtCur);
        require(pxtDebt < 0, "no pxt debt");
        pxtCur.settle(manager, claimHolder, uint256(-pxtDebt), true);

        uint256 pending = hook.pendingDexSellAmount();
        require(pending != 0, "no pending");
        IERC20(address(pxt)).transferFrom(decoy, address(manager), pending);

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
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
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
        feeCollector.setAuthorizedBuybackCaller(address(this), true);

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
        assertEq(f & Hooks.AFTER_ADD_LIQUIDITY_FLAG, Hooks.AFTER_ADD_LIQUIDITY_FLAG);
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

    /// @dev Shared lpRouter sender is never FeeCollector — admin cannot bypass via POSM (RAAAU).
    function test_lp_gate_blocks_router_even_for_admin() public {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            100 * WHOLE,
            100 * WHOLE
        );

        vm.startPrank(admin);
        musdc.mint(admin, 1_000 * WHOLE);
        pxt.transfer(admin, 1_000 * WHOLE);
        IERC20(address(pxt)).approve(address(lpRouter), type(uint256).max);
        musdc.approve(address(lpRouter), type(uint256).max);
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(uint256(99))
            }),
            abi.encode(admin)
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
        // LP settle is attested inbound, not a DEX sell — anti-bot need not be cleared.

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
        uint256 donationBefore = pxt.balanceOf(donation);
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
        assertEq(pxt.balanceOf(donation), donationBefore);
    }

    /// @dev Naked user→PoolManager (no swap / LP) pays the 2.7% transfer tax (PTTB).
    function test_transfer_to_pool_manager_without_swap_pays_tax() public {
        _openSells();
        uint256 amount = 100 * WHOLE;
        uint256 donationBefore = pxt.balanceOf(donation);
        uint256 marketingBefore = pxt.balanceOf(marketing);
        uint256 pmBefore = pxt.balanceOf(address(manager));

        vm.prank(alice);
        pxt.transfer(address(manager), amount);

        uint256 expectDon = (amount * PxtFeeModel.BUY_DONATION_BPS) / PxtFeeModel.BPS;
        uint256 expectMkt = (amount * PxtFeeModel.TRANSFER_FEE_BPS) / PxtFeeModel.BPS - expectDon;
        assertEq(pxt.balanceOf(address(manager)), pmBefore + amount - expectDon - expectMkt);
        assertEq(pxt.balanceOf(donation), donationBefore + expectDon);
        assertEq(pxt.balanceOf(marketing), marketingBefore + expectMkt);
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

    function test_addLiquidity_is_one_shot() public {
        assertTrue(feeCollector.seedLiquidityAdded());

        vm.prank(admin);
        vm.expectRevert(PhoenixBuyback.LiquidityAlreadySeeded.selector);
        feeCollector.addLiquidity(1, 1, 1, abi.encode(address(feeCollector)));
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

        (uint128 pxtIn, uint128 usdcOut, uint128 usdcSkim, address quote,) = hook.orphanSkim();
        assertGt(usdcSkim, 0);
        assertEq(quote, address(musdc));
        assertGt(pxtIn, 0);
        assertGt(usdcOut, 0);
        assertEq(musdc.balanceOf(address(hook)), hookUsdcBefore + usdcSkim);
        (,,, uint256 pendBbMid) = feeCollector.pending(address(musdc));
        assertEq(pendBbMid, pendBbBefore); // not yet accrued

        hook.finalizeOrphanedSell();

        (,, uint128 skimLeft,,) = hook.orphanSkim();
        assertEq(skimLeft, 0);
        assertEq(musdc.balanceOf(address(hook)), hookUsdcBefore);
        (,,, uint256 pendBbAfter) = feeCollector.pending(address(musdc));
        assertGt(pendBbAfter, pendBbBefore);
    }

    /// @dev Claim settle + matching ERC-20 deposit cannot impersonate the seller (MDSS).
    function test_matching_deposit_after_6909_settle_reverts() public {
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
        vm.stopPrank();

        uint256 claims = manager.balanceOf(alice, uint256(uint160(address(pxt))));
        uint256 sellAmount = claims / 2;
        assertGt(sellAmount, 0);

        address decoy = makeAddr("decoy");
        vm.startPrank(admin);
        pxt.transfer(decoy, 100_000 * WHOLE);
        vm.stopPrank();

        MdssMatchingDepositProbe probe = new MdssMatchingDepositProbe(manager, hook, pxt);
        vm.prank(alice);
        manager.setOperator(address(probe), true);
        vm.prank(decoy);
        IERC20(address(pxt)).approve(address(probe), type(uint256).max);

        bool sellZfo = Currency.unwrap(key.currency0) == address(pxt);
        SwapParams memory params = SwapParams({
            zeroForOne: sellZfo,
            amountSpecified: -sellAmount.toInt256(),
            sqrtPriceLimitX96: sellZfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.expectRevert(PhoenixV4ReturnDeltaHook.SellAlreadySettled.selector);
        probe.attack(key, params, alice, decoy);
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

        (,, uint128 skim,,) = hook.orphanSkim();
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

        (,, uint128 skim,,) = hook.orphanSkim();
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
        (,, uint128 skim,,) = hook.orphanSkim();
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

    /// @dev Same-tx PoolManager→seller PXT (flash take) must not inflate the dump-window snapshot.
    function test_dump_window_excludes_same_tx_pool_manager_credit() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        _openSells();
        _sell(antiBot, 1 * WHOLE);

        uint256 flash = 1_000_000 * WHOLE;
        vm.prank(admin);
        pxt.transfer(address(manager), flash);

        uint256 aliceBefore = pxt.balanceOf(alice);
        vm.prank(address(manager));
        pxt.transfer(alice, flash);

        _sell(alice, 1 * WHOLE);
        (,, uint256 snap) = hook.sellWindows(alice);
        assertEq(snap, aliceBefore);
    }

    /// @dev After holdings drop, later sells use the smaller bag (not the first-sale snapshot).
    function test_dump_window_ratchets_down_when_balance_drops() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        _openSells();
        _sell(antiBot, 1 * WHOLE);

        _sell(alice, 1 * WHOLE);
        (,, uint256 snap0) = hook.sellWindows(alice);
        assertGt(snap0, 50_000 * WHOLE);

        address buddy = makeAddr("dumpBuddy");
        uint256 sendOut = 80_000 * WHOLE;
        vm.prank(alice);
        pxt.transfer(buddy, sendOut);

        uint256 aliceLeft = pxt.balanceOf(alice);
        uint256 secondSell = (aliceLeft * 15) / 100;
        assertGt(secondSell, 0);
        // 15% of remaining is still << 10% of the original ~100k snapshot.
        assertLt(secondSell * PxtFeeModel.BPS, snap0 * PxtFeeModel.PENALTY_THRESHOLD_BPS);

        (uint256 don0, uint256 mkt0,, uint256 bb0) = feeCollector.pending(address(musdc));
        uint256 aliceMusdcBefore = musdc.balanceOf(alice);
        _sell(alice, secondSell);

        (,, uint256 snap1) = hook.sellWindows(alice);
        assertEq(snap1, aliceLeft);

        (uint256 pendDon, uint256 pendMkt,, uint256 pendBb) = feeCollector.pending(address(musdc));
        uint256 usdcSkimmed = (pendDon - don0) + (pendMkt - mkt0) + (pendBb - bb0);
        uint256 usdcOutGross = musdc.balanceOf(alice) - aliceMusdcBefore + usdcSkimmed;
        uint256 expectBb =
            (usdcOutGross * PxtFeeModel.PENALTY_USDC_FEE_BPS) / PxtFeeModel.BPS
            - (usdcOutGross * PxtFeeModel.PENALTY_DONATION_BPS) / PxtFeeModel.BPS
            - (usdcOutGross * PxtFeeModel.PENALTY_MARKETING_BPS) / PxtFeeModel.BPS;
        assertEq(pendBb - bb0, expectBb);
        assertGt(pendBb - bb0, (usdcOutGross * PxtFeeModel.SELL_USDC_FEE_BPS) / PxtFeeModel.BPS);
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
        uint256 gross =
            usdcOut + (usdcOut * PxtFeeModel.SELL_USDC_FEE_BPS) / (PxtFeeModel.BPS - PxtFeeModel.SELL_USDC_FEE_BPS);
        uint256 expectDon = (gross * PxtFeeModel.SELL_DONATION_BPS) / PxtFeeModel.BPS;
        uint256 expectMkt = (gross * PxtFeeModel.SELL_MARKETING_BPS) / PxtFeeModel.BPS;
        uint256 expectBb = (gross * PxtFeeModel.SELL_USDC_FEE_BPS) / PxtFeeModel.BPS - expectDon - expectMkt;
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
        uint256 gross =
            usdcOut + (usdcOut * PxtFeeModel.PENALTY_USDC_FEE_BPS)
            / (PxtFeeModel.BPS - PxtFeeModel.PENALTY_USDC_FEE_BPS);
        uint256 expectDon = (gross * PxtFeeModel.PENALTY_DONATION_BPS) / PxtFeeModel.BPS;
        uint256 expectMkt = (gross * PxtFeeModel.PENALTY_MARKETING_BPS) / PxtFeeModel.BPS;
        uint256 expectBb = (gross * PxtFeeModel.PENALTY_USDC_FEE_BPS) / PxtFeeModel.BPS - expectDon - expectMkt;
        assertEq(pendDon, expectDon);
        assertEq(pendMkt, expectMkt);
        assertEq(pendBb, expectBb);
        // Published 35.95% of total USDC flow, not 35.95% of the net exact-out (RIFM).
        assertGt(pendDon + pendMkt + pendBb, (usdcOut * PxtFeeModel.PENALTY_USDC_FEE_BPS) / PxtFeeModel.BPS);
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

    /// @dev Exact-in sell at a tight limit must burn/fee the fill, not the requested size (RIFM).
    function test_exact_in_sell_partial_fill_burns_actual() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        _openSells();
        _sell(antiBot, 1 * WHOLE);

        vm.startPrank(admin);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.FeeExempt);
        pxt.transfer(alice, 5_000_000 * WHOLE);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.Normal);
        vm.stopPrank();

        uint256 request = 5_000_000 * WHOLE;
        uint256 requestBurn = (request * PxtFeeModel.SELL_BURN_BPS) / PxtFeeModel.BPS;
        uint256 supplyBefore = pxt.totalSupply();
        uint256 aliceBefore = pxt.balanceOf(alice);

        bool zeroForOne = Currency.unwrap(key.currency0) == address(pxt);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 limitTick = zeroForOne ? tick - TICK_SPACING : tick + TICK_SPACING;
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);

        vm.startPrank(alice);
        IERC20(address(pxt)).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -request.toInt256(), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice)
        );
        vm.stopPrank();

        uint256 burned = supplyBefore - pxt.totalSupply();
        uint256 spent = aliceBefore - pxt.balanceOf(alice);
        assertLt(spent, request);
        assertLt(burned, requestBurn);
        uint256 poolPxt = spent - burned;
        assertEq(burned, (poolPxt * PxtFeeModel.SELL_BURN_BPS) / (PxtFeeModel.BPS - PxtFeeModel.SELL_BURN_BPS));
    }

    /// @dev Exact-out buy: 2.7% of total USDC paid, not 2.7% of the pool leg (RIFM).
    function test_exact_out_buy_grosses_up_usdc_fee() public {
        uint256 pxtOut = 1_000 * WHOLE;
        uint256 aliceMusdcBefore = musdc.balanceOf(alice);
        uint256 alicePxtBefore = pxt.balanceOf(alice);

        bool zeroForOne = Currency.unwrap(key.currency0) == address(musdc);
        vm.startPrank(alice);
        musdc.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: pxtOut.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice)
        );
        vm.stopPrank();

        uint256 usdcPaid = aliceMusdcBefore - musdc.balanceOf(alice);
        (uint256 pendDon, uint256 pendMkt,,) = feeCollector.pending(address(musdc));
        uint256 fee = pendDon + pendMkt;
        uint256 poolUsdc = usdcPaid - fee;
        uint256 gross = poolUsdc + (poolUsdc * PxtFeeModel.BUY_FEE_BPS) / (PxtFeeModel.BPS - PxtFeeModel.BUY_FEE_BPS);
        uint256 expectDon = (gross * PxtFeeModel.BUY_DONATION_BPS) / PxtFeeModel.BPS;
        uint256 expectMkt = (gross * PxtFeeModel.BUY_FEE_BPS) / PxtFeeModel.BPS - expectDon;
        assertEq(pendDon, expectDon);
        assertEq(pendMkt, expectMkt);
        assertGt(fee, (poolUsdc * PxtFeeModel.BUY_FEE_BPS) / PxtFeeModel.BPS);
        assertEq(pxt.balanceOf(alice), alicePxtBefore + pxtOut);
    }

    function test_unauthorized_buyback_reverts() public {
        _accrueBuybackPending();

        address stranger = makeAddr("buybackStranger");
        vm.prank(stranger);
        vm.expectRevert(PhoenixBuyback.UnauthorizedBuybackCaller.selector);
        feeCollector.executeBuyback(1, 0, block.timestamp + 1);
    }

    function test_constructor_authorizes_admin_as_buyback_caller() public view {
        assertTrue(feeCollector.isAuthorizedBuybackCaller(admin));
        assertTrue(feeCollector.hasRole(feeCollector.BUYBACK_EXECUTOR_APPROVER_ROLE(), admin));
    }

    function test_setAuthorizedBuybackCaller_requires_approver_role() public {
        address ops = makeAddr("buybackOps");
        address multisig = makeAddr("buybackMultisig");
        bytes32 approverRole = feeCollector.BUYBACK_EXECUTOR_APPROVER_ROLE();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, approverRole)
        );
        feeCollector.setAuthorizedBuybackCaller(ops, true);

        vm.startPrank(admin);
        feeCollector.grantRole(approverRole, multisig);
        feeCollector.grantRole(feeCollector.DEFAULT_ADMIN_ROLE(), multisig);
        feeCollector.revokeRole(approverRole, admin);
        feeCollector.renounceRole(feeCollector.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, approverRole)
        );
        feeCollector.setAuthorizedBuybackCaller(ops, true);

        vm.prank(multisig);
        feeCollector.setAuthorizedBuybackCaller(ops, true);
        assertTrue(feeCollector.isAuthorizedBuybackCaller(ops));
    }

    function test_buyback_approver_role_survives_ownable_renounce() public {
        address multisig = makeAddr("buybackMultisig");
        address keeper = makeAddr("buybackKeeper");
        bytes32 approverRole = feeCollector.BUYBACK_EXECUTOR_APPROVER_ROLE();

        vm.startPrank(admin);
        feeCollector.grantRole(approverRole, multisig);
        feeCollector.grantRole(feeCollector.DEFAULT_ADMIN_ROLE(), multisig);
        feeCollector.revokeRole(approverRole, admin);
        feeCollector.renounceRole(feeCollector.DEFAULT_ADMIN_ROLE(), admin);
        feeCollector.renounceOwnership();
        vm.stopPrank();

        assertEq(feeCollector.owner(), address(0));
        assertTrue(feeCollector.hasRole(approverRole, multisig));

        vm.prank(multisig);
        feeCollector.setAuthorizedBuybackCaller(keeper, true);
        assertTrue(feeCollector.isAuthorizedBuybackCaller(keeper));

        uint256 pendBb = _accrueBuybackPending();
        _rollBuybackRef();
        vm.prank(keeper);
        feeCollector.executeBuyback(pendBb / 2, 0, block.timestamp + 1);
    }

    function test_revoked_buyback_caller_cannot_execute() public {
        address ops = makeAddr("buybackOps");
        vm.prank(admin);
        feeCollector.setAuthorizedBuybackCaller(ops, true);

        uint256 pendBb = _accrueBuybackPending();

        _rollBuybackRef();
        vm.prank(ops);
        feeCollector.executeBuyback(pendBb / 2, 0, block.timestamp + 1);

        vm.prank(admin);
        feeCollector.setAuthorizedBuybackCaller(ops, false);
        assertFalse(feeCollector.isAuthorizedBuybackCaller(ops));

        vm.prank(ops);
        vm.expectRevert(PhoenixBuyback.UnauthorizedBuybackCaller.selector);
        feeCollector.executeBuyback(1, 0, block.timestamp + 1);
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

        _rollBuybackRef();
        feeCollector.executeBuyback(half, 0, block.timestamp + 1);
        (,,, uint256 pendAfter) = feeCollector.pending(address(musdc));
        assertEq(pendAfter, pendBb - half);
        assertGt(feeCollector.recyclePxt(), 0);
    }

    /// @dev Price-limit partial fill must debit pending by actual USDC spent, not requested budget.
    function test_buyback_partial_fill_keeps_pending() public {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        vm.warp(sellUnlock);
        _clearAntiBot();
        _sell(antiBot, 1 * WHOLE);
        _sell(alice, 100_000 * WHOLE);
        feeCollector.collect();
        (,,, uint256 pendBb) = feeCollector.pending(address(musdc));
        assertGt(pendBb, 100 * WHOLE);

        vm.prank(admin);
        feeCollector.setBuybackParams(10, 1);

        _rollBuybackRef();
        (uint256 spent,) = feeCollector.executeBuyback(0, 0, block.timestamp + 1);
        (,,, uint256 pendAfter) = feeCollector.pending(address(musdc));

        assertGt(spent, 0);
        assertLt(spent, pendBb);
        assertEq(pendAfter, pendBb - spent);
        assertGt(pendAfter, 0);
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
        _rollBuybackRef();
        feeCollector.executeBuyback(spend, 0, block.timestamp + 1);

        (uint256 donAfter, uint256 mktAfter,, uint256 pendAfter) = feeCollector.pending(address(musdc));
        assertEq(pendAfter, pendBb - spend);
        // No new buy-fee donation/marketing from the buyback swap itself.
        assertEq(donAfter, donBefore);
        assertEq(mktAfter, mktBefore);
        assertGt(feeCollector.recyclePxt(), 0);
    }

    function test_recycle_mints_after_spot_moves() public {
        vm.startPrank(admin);
        feeCollector.setBuybackParams(1, 5_000);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        musdc.mint(alice, 50_000_000 * WHOLE);
        pxt.transfer(alice, 500_000 * WHOLE);
        vm.stopPrank();

        _openSells();
        _sell(antiBot, 1 * WHOLE);
        _sell(alice, 50_000 * WHOLE);
        feeCollector.collect();

        (uint256 pendDon0, uint256 pendMkt0,, uint256 pendBb0) = feeCollector.pending(address(musdc));
        assertGt(pendBb0, 0);

        uint256 spendPer = pendBb0 / 4;
        assertGt(spendPer, 0);

        bool pxtIsToken0 = Currency.unwrap(key.currency0) == address(pxt);
        (, int24 tickBefore,,) = manager.getSlot0(key.toId());
        int24 floorBefore = PhoenixBuybackMath.floorToSpacing(tickBefore, TICK_SPACING);

        _rollBuybackRef();
        feeCollector.executeBuyback(spendPer, 0, block.timestamp + 1);
        int24 firstLo = feeCollector.lastRecycleTickLower();
        int24 firstHi = feeCollector.lastRecycleTickUpper();
        uint256 recycleAfterFirst = feeCollector.recyclePxt();
        assertGt(recycleAfterFirst, 0);
        (, int24 tickAfterMint,,) = manager.getSlot0(key.toId());
        assertTrue(PhoenixBuybackMath.isPxtOnlyBand(tickAfterMint, firstLo, firstHi, pxtIsToken0));

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

        (uint256 pendDon, uint256 pendMkt,, uint256 pendBb) = feeCollector.pending(address(musdc));
        uint256 usdcBal = musdc.balanceOf(address(feeCollector));

        _rollBuybackRef();
        feeCollector.executeBuyback(spendPer, 0, block.timestamp + 1);

        (uint256 pendDonAfter, uint256 pendMktAfter,, uint256 pendBbAfter) = feeCollector.pending(address(musdc));
        assertEq(pendDonAfter, pendDon);
        assertEq(pendMktAfter, pendMkt);
        assertEq(pendBbAfter, pendBb - spendPer);
        assertGt(feeCollector.recyclePxt(), recycleAfterFirst);
        // Donation/marketing pending from the initial sell must still be solvent on the collector.
        assertGe(musdc.balanceOf(address(feeCollector)), pendDon0 + pendMkt0 + pendBbAfter);
        assertGe(usdcBal, pendDon0 + pendMkt0 + pendBb);
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

    function test_collect_reserves_pending_buyback() public {
        uint256 donationAmt = 10 * WHOLE;
        uint256 marketingAmt = 10 * WHOLE;
        uint256 buybackAmt = 80 * WHOLE;

        vm.prank(admin);
        musdc.mint(address(hook), donationAmt + marketingAmt + buybackAmt);

        vm.startPrank(address(hook));
        musdc.approve(address(feeCollector), type(uint256).max);
        feeCollector.receiveAccruedFees(address(musdc), FeeKind.Sell, donationAmt, marketingAmt, 0, buybackAmt);
        vm.stopPrank();

        deal(address(musdc), address(feeCollector), 50 * WHOLE);

        uint256 donationBefore = musdc.balanceOf(donation);
        uint256 marketingBefore = musdc.balanceOf(marketing);
        feeCollector.collect();

        assertEq(musdc.balanceOf(donation), donationBefore);
        assertEq(musdc.balanceOf(marketing), marketingBefore);
        (uint256 pendDon, uint256 pendMkt, uint256 pendBurn, uint256 pendBb) = feeCollector.pending(address(musdc));
        assertEq(pendDon, 0);
        assertEq(pendMkt, 0);
        assertEq(pendBurn, 0);
        assertEq(pendBb, 50 * WHOLE);
        assertEq(musdc.balanceOf(address(feeCollector)), 50 * WHOLE);
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

    function test_lock_protocol_requires_pxt_fee_collector() public {
        LockProtocolReturnDelta locker = new LockProtocolReturnDelta();
        locker.requirePxtFeeCollector(pxt, address(feeCollector));
    }

    function test_lock_protocol_rejects_mismatched_pxt_fee_collector() public {
        Pxt fresh = new Pxt(admin, donation, marketing, sellUnlock);
        address wrongCollector = makeAddr("wrongCollector");
        vm.etch(wrongCollector, hex"00");

        vm.prank(admin);
        fresh.setFeeCollector(wrongCollector);

        LockProtocolReturnDelta locker = new LockProtocolReturnDelta();
        vm.expectRevert(LockProtocolReturnDelta.FeeCollectorMismatch.selector);
        locker.requirePxtFeeCollector(fresh, address(feeCollector));
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
        _rollBuybackRef();
        feeCollector.executeBuyback(pendBb / 2, 0, block.timestamp + 1);
        (,,, uint256 pendAfter) = feeCollector.pending(address(musdc));
        assertEq(pendAfter, pendBb - pendBb / 2);
    }

    function test_lock_protocol_rejects_wrong_sell_attributor() public {
        Pxt fresh = new Pxt(admin, donation, marketing, sellUnlock);
        LockProtocolReturnDelta locker = new LockProtocolReturnDelta();
        address stranger = makeAddr("wrongAttributor");
        vm.etch(stranger, hex"00");

        vm.prank(admin);
        fresh.setSellAttributor(ISellAttributor(stranger));

        vm.expectRevert(LockProtocolReturnDelta.SellAttributorMustBeHook.selector);
        locker.requireSellAttributorIsHook(fresh, address(hook));
    }

    function test_lock_renounce_keeps_collect_and_blocks_admin() public {
        address multisig = makeAddr("multisig");
        address stranger = makeAddr("stranger");
        address keeper = makeAddr("postLockKeeper");

        (, uint128 positionLiq) = feeCollector.quoteBuyback();
        assertGt(positionLiq, 0);
        vm.prank(admin);
        feeCollector.setBuybackParams(10, 200);

        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        vm.warp(sellUnlock);
        _clearAntiBot();

        LockProtocolReturnDelta locker = new LockProtocolReturnDelta();
        locker.requireSellAttributorIsHook(pxt, address(hook));
        assertEq(address(hook.feeCollector()), address(feeCollector));
        assertGt(feeCollector.maxBuybackSlippageBps(), 0);

        vm.startPrank(admin);
        pxt.grantRole(pxt.RECIPIENT_APPROVER_ROLE(), multisig);
        pxt.grantRole(pxt.DEFAULT_ADMIN_ROLE(), multisig);
        pxt.revokeRole(pxt.RECIPIENT_APPROVER_ROLE(), admin);
        pxt.renounceRole(pxt.DEFAULT_ADMIN_ROLE(), admin);

        feeCollector.grantRole(feeCollector.BUYBACK_EXECUTOR_APPROVER_ROLE(), multisig);
        feeCollector.grantRole(feeCollector.DEFAULT_ADMIN_ROLE(), multisig);
        feeCollector.setAuthorizedBuybackCaller(keeper, true);
        feeCollector.setAuthorizedBuybackCaller(admin, false);
        feeCollector.revokeRole(feeCollector.BUYBACK_EXECUTOR_APPROVER_ROLE(), admin);
        feeCollector.renounceRole(feeCollector.DEFAULT_ADMIN_ROLE(), admin);

        feeCollector.renounceOwnership();
        hook.renounceOwnership();
        pxt.renounceOwnership();
        vm.stopPrank();

        assertEq(feeCollector.owner(), address(0));
        assertEq(hook.owner(), address(0));
        assertEq(pxt.owner(), address(0));
        assertTrue(pxt.hasRole(pxt.RECIPIENT_APPROVER_ROLE(), multisig));
        assertTrue(feeCollector.hasRole(feeCollector.BUYBACK_EXECUTOR_APPROVER_ROLE(), multisig));
        assertTrue(feeCollector.hasRole(feeCollector.DEFAULT_ADMIN_ROLE(), multisig));
        assertFalse(feeCollector.isAuthorizedBuybackCaller(admin));
        assertTrue(feeCollector.isAuthorizedBuybackCaller(keeper));
        assertEq(address(pxt.sellAttributor()), address(hook));

        uint256 amountIn = 1_000 * WHOLE;
        _buy(alice, amountIn);
        uint256 expectDon = (amountIn * PxtFeeModel.BUY_DONATION_BPS) / PxtFeeModel.BPS;
        uint256 donationBefore = musdc.balanceOf(donation);

        vm.prank(stranger);
        feeCollector.collect();
        assertEq(musdc.balanceOf(donation), donationBefore + expectDon);

        vm.prank(stranger);
        vm.expectRevert(PhoenixBuyback.UnauthorizedBuybackCaller.selector);
        feeCollector.executeBuyback(1, 0, block.timestamp + 1);

        vm.prank(admin);
        vm.expectRevert(PhoenixBuyback.UnauthorizedBuybackCaller.selector);
        feeCollector.executeBuyback(1, 0, block.timestamp + 1);

        _sell(alice, 500 * WHOLE);
        feeCollector.collect();
        (,,, uint256 pendBb) = feeCollector.pending(address(musdc));
        assertGt(pendBb, 0);

        _rollBuybackRef();
        vm.prank(keeper);
        feeCollector.executeBuyback(pendBb / 2, 0, block.timestamp + 1);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        feeCollector.setBuybackParams(1, 100);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                admin,
                feeCollector.BUYBACK_EXECUTOR_APPROVER_ROLE()
            )
        );
        feeCollector.setAuthorizedBuybackCaller(keeper, false);
        vm.stopPrank();
    }

    function test_buyback_requires_prior_block_spot() public {
        _accrueBuybackPending();
        assertEq(feeCollector.frozenSqrtPriceX96(), 0);
        assertGt(uint256(feeCollector.pendingSqrtPriceX96()), 0);

        vm.expectRevert(PhoenixBuyback.BuybackPriceNotWarmed.selector);
        feeCollector.executeBuyback(1, 0, block.timestamp + 1);
    }

    function test_buyback_uses_frozen_previous_block_spot() public {
        uint256 pendBb = _accrueBuybackPending();
        uint160 pendingBefore = feeCollector.pendingSqrtPriceX96();
        assertGt(uint256(pendingBefore), 0);
        assertEq(feeCollector.frozenSqrtPriceX96(), 0);

        _rollBuybackRef();
        feeCollector.executeBuyback(pendBb / 2, 0, block.timestamp + 1);
        assertEq(feeCollector.frozenSqrtPriceX96(), pendingBefore);
        assertGt(feeCollector.recyclePxt(), 0);
    }

    /// @dev Same-block JIT / spot move cannot retarget min-out or sqrtLimit (JLVE).
    function test_buyback_rejects_same_block_spot_manipulation() public {
        uint256 pendBb = _accrueBuybackPending();
        _rollBuybackRef();

        vm.prank(admin);
        musdc.mint(alice, 2_000_000 * WHOLE);
        _buy(alice, 2_000_000 * WHOLE);

        uint160 frozen = feeCollector.frozenSqrtPriceX96();
        (uint160 live,,,) = manager.getSlot0(key.toId());
        assertGt(uint256(frozen), 0);
        assertTrue(live != frozen);

        vm.expectRevert();
        feeCollector.executeBuyback(pendBb / 2, 0, block.timestamp + 1);
    }

    function _rollBuybackRef() internal {
        vm.roll(block.number + 1);
    }

    function _accrueBuybackPending() internal returns (uint256 pendBb) {
        vm.prank(admin);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        vm.warp(sellUnlock);
        _clearAntiBot();
        _sell(antiBot, 1 * WHOLE);
        _sell(alice, 1_000 * WHOLE);
        feeCollector.collect();
        (,,, pendBb) = feeCollector.pending(address(musdc));
        assertGt(pendBb, 0);
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
