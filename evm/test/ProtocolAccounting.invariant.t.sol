// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {Pxt} from "../src/core/Pxt.sol";
import {PhoenixAntiBotOpenSell} from "../script/PhoenixAntiBotOpenSell.sol";
import {PhoenixV4ReturnDeltaHook} from "../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {PhoenixFeeCollector} from "../src/fee/PhoenixFeeCollector.sol";
import {HookMiner} from "../src/uniswap/v4/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Random buy / sell / claim-sell / collect / buyback / finalize after trading opens.
contract ProtocolAccountingHandler is Test {
    using SafeCast for uint256;

    uint256 internal constant WHOLE = 1e6;

    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    Pxt public immutable pxt;
    MockERC20 public immutable musdc;
    PhoenixV4ReturnDeltaHook public immutable hook;
    PhoenixFeeCollector public immutable feeCollector;
    PoolKey public key;
    address public immutable alice;

    constructor(
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        Pxt pxt_,
        MockERC20 musdc_,
        PhoenixV4ReturnDeltaHook hook_,
        PhoenixFeeCollector feeCollector_,
        PoolKey memory key_,
        address alice_
    ) {
        manager = manager_;
        swapRouter = swapRouter_;
        pxt = pxt_;
        musdc = musdc_;
        hook = hook_;
        feeCollector = feeCollector_;
        key = key_;
        alice = alice_;
    }

    function buy(uint256 amountIn) external {
        amountIn = bound(amountIn, WHOLE, 5_000 * WHOLE);
        uint256 bal = musdc.balanceOf(alice);
        if (bal < amountIn) amountIn = bal;
        if (amountIn < WHOLE) return;

        bool zeroForOne = Currency.unwrap(key.currency0) == address(musdc);
        vm.startPrank(alice);
        musdc.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice)
        );
        vm.stopPrank();
    }

    function sell(uint256 amountIn) external {
        amountIn = bound(amountIn, WHOLE, 2_000 * WHOLE);
        uint256 bal = pxt.balanceOf(alice);
        // Leave room for 1.85% burn haircut on exact-in.
        if (bal < amountIn + amountIn / 50) return;

        bool zeroForOne = Currency.unwrap(key.currency0) == address(pxt);
        vm.startPrank(alice);
        IERC20(address(pxt)).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice)
        );
        vm.stopPrank();
    }

    /// @dev Buy into ERC-6909 claims then sell claims (orphan skim path).
    function claimSell(uint256 buyAmount, uint256 sellFrac) external {
        buyAmount = bound(buyAmount, WHOLE, 2_000 * WHOLE);
        if (musdc.balanceOf(alice) < buyAmount) return;

        bool buyZfo = Currency.unwrap(key.currency0) == address(musdc);
        vm.startPrank(alice);
        musdc.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: buyZfo,
                amountSpecified: -buyAmount.toInt256(),
                sqrtPriceLimitX96: buyZfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            abi.encode(alice)
        );

        uint256 claimId = uint256(uint160(address(pxt)));
        uint256 claims = manager.balanceOf(alice, claimId);
        if (claims < WHOLE) {
            vm.stopPrank();
            return;
        }
        sellFrac = bound(sellFrac, 1, 4);
        uint256 sellAmount = claims / sellFrac;
        if (sellAmount == 0) {
            vm.stopPrank();
            return;
        }

        // PoolSwapTest burns claims from `sender`; approve it as ERC-6909 operator.
        manager.setOperator(address(swapRouter), true);

        bool sellZfo = Currency.unwrap(key.currency0) == address(pxt);
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

    function finalizeOrphan() external {
        (,, uint128 skim,) = hook.orphanSkim();
        if (skim == 0) return;
        hook.finalizeOrphanedSell();
    }

    function collect() external {
        feeCollector.collect();
    }

    function buyback(uint256 usdcAmount) external {
        (,,, uint256 pendBb) = feeCollector.pending(address(musdc));
        if (pendBb == 0) return;
        usdcAmount = bound(usdcAmount, 0, pendBb);
        // Promote last-block swap spot into the buyback ref (Foundry often stays on one block).
        vm.roll(block.number + 1);
        // Price impact after prior swaps can trip protocol slippage — skip those paths.
        try feeCollector.executeBuyback(usdcAmount, 0, block.timestamp + 1 hours) {} catch {}
    }
}

contract ProtocolAccountingInvariantTest is StdInvariant, Test {
    using SafeCast for uint256;

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
    ProtocolAccountingHandler internal handler;

    uint256 internal initialSupply;
    uint128 internal seedPositionLiq;

    address internal admin = makeAddr("admin");
    address internal donation = makeAddr("donation");
    address internal marketing = makeAddr("marketing");
    address internal alice = makeAddr("alice");
    address internal antiBot = makeAddr("antiBot");

    function setUp() public {
        uint256 sellUnlock = block.timestamp + 30 days;

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

        openSell = new PhoenixAntiBotOpenSell(pxt, swapRouter, antiBot);
        pxt.setApprovedContractRecipient(address(openSell), true);
        pxt.setWalletStatus(address(openSell), Pxt.WalletStatus.FeeExempt);
        pxt.setAntiBotSeller(address(openSell));

        key = _poolKey();
        hook.setOfficialPool(key);
        feeCollector.configurePool(key, TICK_LOWER, TICK_UPPER, bytes32(0));

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

        (, uint128 positionLiq) = feeCollector.quoteBuyback();
        seedPositionLiq = positionLiq;
        feeCollector.setBuybackParams(10, 200);

        musdc.mint(alice, 1_000_000 * WHOLE);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.FeeExempt);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.FeeExempt);
        pxt.transfer(alice, 500_000 * WHOLE);
        pxt.transfer(antiBot, 100_000 * WHOLE);
        pxt.setWalletStatus(alice, Pxt.WalletStatus.Normal);
        pxt.setWalletStatus(antiBot, Pxt.WalletStatus.Normal);
        vm.stopPrank();

        // Open public trading once for the campaign.
        vm.warp(sellUnlock);
        vm.prank(address(openSell));
        pxt.clearSellProtection();

        initialSupply = pxt.totalSupply();

        handler = new ProtocolAccountingHandler(manager, swapRouter, pxt, musdc, hook, feeCollector, key, alice);
        vm.prank(admin);
        feeCollector.setAuthorizedBuybackCaller(address(handler), true);
        targetContract(address(handler));
    }

    function invariant_totalSupply_never_increases() public view {
        assertLe(pxt.totalSupply(), initialSupply);
    }

    function invariant_hook_usdc_covers_orphan_skim() public view {
        (,, uint128 skim,) = hook.orphanSkim();
        assertGe(musdc.balanceOf(address(hook)), uint256(skim));
    }

    function invariant_fee_collector_wallet_burn_pending_backed() public view {
        _assertWalletBurnBacked(address(musdc));
        _assertWalletBurnBacked(address(pxt));
    }

    function invariant_seed_lp_unchanged() public view {
        // Cash-only buyback never peels the seeded full-range position.
        (, uint128 positionLiq) = feeCollector.quoteBuyback();
        assertEq(positionLiq, seedPositionLiq);
    }

    function _assertWalletBurnBacked(address token) internal view {
        (uint256 don, uint256 mkt, uint256 burn,) = feeCollector.pending(token);
        uint256 due = don + mkt + burn;
        assertLe(due, IERC20(token).balanceOf(address(feeCollector)));
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
