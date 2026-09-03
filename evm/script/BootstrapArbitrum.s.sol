// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Pxt} from "../src/core/Pxt.sol";
import {PhoenixAntiBotOpenSell} from "./PhoenixAntiBotOpenSell.sol";
import {PhoenixV4ReturnDeltaHook} from "../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {PhoenixFeeCollector} from "../src/fee/PhoenixFeeCollector.sol";
import {HookMiner} from "../src/uniswap/v4/HookMiner.sol";
import {V4Addresses} from "../src/uniswap/v4/V4Addresses.sol";
import {DEFAULT_SELL_UNLOCK_TIMESTAMP} from "../src/core/PxtFeeModel.sol";
import {WalletStatusConfig} from "./WalletStatusConfig.sol";

/// @notice Live Arbitrum One bootstrap: real USDC, deploy PoolSwapTest, seed LP, do NOT lock.
/// @dev Same wiring as BootstrapReturnDeltaFork: official pool, FeeCollector seed, one-shot
///      collector/attributor, FeeExempt collector before addLiquidity (STCBT), afterAddLiquidity
///      hook flag (PTTB). Lock is a separate LockProtocolReturnDelta step.
/// Env: PRIVATE_KEY, POOL_MANAGER, QUOTE_TOKEN_ADDRESS, LP_SEED_*_WHOLE, SELL_UNLOCK_TIMESTAMP,
///      DONATION_WALLET, MARKETING_WALLET. Optional FEE_EXEMPT_WALLETS / NO_PENALTY_WALLETS /
///      BUYBACK_CALLERS.
contract BootstrapArbitrum is Script, WalletStatusConfig {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 internal constant LP_FEE = 0;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -887_220;
    int24 internal constant TICK_UPPER = 887_220;

    /// @dev Default $20 at 0.001 USDC/PXT → 20,000 PXT.
    uint256 internal constant DEFAULT_PXT_SEED_WHOLE = 20_000;
    uint256 internal constant DEFAULT_USDC_SEED_WHOLE = 20;

    struct Deployed {
        Pxt pxt;
        PhoenixV4ReturnDeltaHook hook;
        PhoenixFeeCollector feeCollector;
        PhoenixAntiBotOpenSell openSell;
        PoolSwapTest swapRouter;
        IERC20 usdc;
        IPoolManager poolManager;
        PoolKey poolKey;
        address donation;
        address marketing;
        address noPenalty;
        address admin;
        address antiBotSeller;
        uint256 chainId;
        uint160 sqrtPriceX96;
        uint256 pxtSeed;
        uint256 usdcSeed;
    }

    function run() external {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        Deployed memory d = _deploy(adminKey);
        _logSummary(d);
    }

    function _deploy(uint256 adminKey) internal returns (Deployed memory d) {
        d.admin = vm.addr(adminKey);
        d.chainId = block.chainid;
        require(d.chainId == 42_161, "BootstrapArbitrum: expected Arbitrum One (42161)");

        d.donation = vm.envAddress("DONATION_WALLET");
        d.marketing = vm.envAddress("MARKETING_WALLET");
        require(d.donation != address(0) && d.marketing != address(0), "fee wallets required");

        address antiBotOperator = vm.envOr("ANTI_BOT_SELLER", d.admin);
        if (antiBotOperator == address(0)) antiBotOperator = d.admin;

        address pmAddr = vm.envOr("POOL_MANAGER", V4Addresses.ARBITRUM_POOL_MANAGER);
        d.poolManager = IPoolManager(pmAddr);

        address usdcAddr = vm.envOr("QUOTE_TOKEN_ADDRESS", V4Addresses.ARBITRUM_USDC);
        d.usdc = IERC20(usdcAddr);
        uint8 quoteDecimals = IERC20Metadata(usdcAddr).decimals();
        require(quoteDecimals == 6, "USDC decimals != 6");

        uint256 sellUnlock = vm.envOr("SELL_UNLOCK_TIMESTAMP", DEFAULT_SELL_UNLOCK_TIMESTAMP);
        if (block.timestamp >= sellUnlock) {
            revert("SELL_UNLOCK_TIMESTAMP is in the past");
        }

        // Must match PhoenixV4ReturnDeltaHook.flags() / getHookPermissions (PTTB afterAddLiquidity).
        uint160 hookFlags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        uint256 unit = 10 ** uint256(quoteDecimals);
        d.pxtSeed = vm.envOr("LP_SEED_PXT_WHOLE", DEFAULT_PXT_SEED_WHOLE) * unit;
        d.usdcSeed = vm.envOr("LP_SEED_USDC_WHOLE", DEFAULT_USDC_SEED_WHOLE) * unit;

        vm.startBroadcast(adminKey);

        require(d.usdc.balanceOf(d.admin) >= d.usdcSeed, "admin needs LP_SEED USDC");

        d.pxt = new Pxt(d.admin, d.donation, d.marketing, sellUnlock);
        require(d.pxt.balanceOf(d.admin) >= d.pxtSeed, "admin PXT seed");

        d.pxt.setPoolManager(address(d.poolManager));

        // PoolSwapTest is not deployed on Arbitrum mainnet — deploy our own for anti-bot open + swaps.
        d.swapRouter = new PoolSwapTest(d.poolManager);

        (address hookAddr, bytes32 salt) = HookMiner.find(
            HookMiner.CREATE2_DEPLOYER,
            hookFlags,
            type(PhoenixV4ReturnDeltaHook).creationCode,
            abi.encode(d.poolManager, d.pxt, antiBotOperator, d.admin)
        );
        d.hook = new PhoenixV4ReturnDeltaHook{salt: salt}(d.poolManager, d.pxt, antiBotOperator, d.admin);
        require(address(d.hook) == hookAddr, "hook address mismatch");

        d.feeCollector = new PhoenixFeeCollector(d.poolManager, d.pxt, d.donation, d.marketing, d.admin);
        d.feeCollector.setHook(address(d.hook));
        d.hook.setFeeCollector(d.feeCollector);
        d.pxt.setFeeCollector(address(d.feeCollector));

        d.pxt.setApprovedContractRecipient(address(d.hook), true);
        d.pxt.setWalletStatus(address(d.hook), Pxt.WalletStatus.FeeExempt);
        d.pxt.setApprovedContractRecipient(address(d.feeCollector), true);
        // STCBT: inbound owner→collector seed is taxed unless the collector is FeeExempt.
        d.pxt.setWalletStatus(address(d.feeCollector), Pxt.WalletStatus.FeeExempt);
        d.pxt.setSellAttributor(d.hook);
        d.pxt.setApprovedContractRecipient(address(d.swapRouter), true);

        address posm = vm.envOr("POSITION_MANAGER", V4Addresses.ARBITRUM_POSITION_MANAGER);
        d.pxt.setApprovedContractRecipient(posm, true);
        address ur = vm.envOr("UNIVERSAL_ROUTER", V4Addresses.ARBITRUM_UNIVERSAL_ROUTER);
        d.pxt.setApprovedContractRecipient(ur, true);

        d.openSell = new PhoenixAntiBotOpenSell(d.pxt, d.swapRouter, antiBotOperator);
        d.pxt.setApprovedContractRecipient(address(d.openSell), true);
        d.pxt.setWalletStatus(address(d.openSell), Pxt.WalletStatus.FeeExempt);
        d.pxt.setAntiBotSeller(address(d.openSell));
        d.antiBotSeller = address(d.openSell);

        d.noPenalty = _applyWalletStatusesFromEnv(d.pxt, false);

        d.poolKey = _buildPoolKey(address(d.pxt), usdcAddr, d.hook);
        d.hook.setOfficialPool(d.poolKey);

        d.sqrtPriceX96 = uint160(
            vm.envOr("SQRT_PRICE_X96", uint256(_sqrtPriceForSpot(address(d.pxt), usdcAddr, d.pxtSeed, d.usdcSeed)))
        );

        d.poolManager.initialize(d.poolKey, d.sqrtPriceX96);
        (uint160 spot,,,) = d.poolManager.getSlot0(d.poolKey.toId());
        require(spot == d.sqrtPriceX96, "sqrtPrice mismatch after initialize");

        d.feeCollector.configurePool(d.poolKey, TICK_LOWER, TICK_UPPER, bytes32(0));

        (uint256 amount0, uint256 amount1) = _orderedAmounts(d.poolKey, address(d.pxt), d.pxtSeed, d.usdcSeed);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            d.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            amount0,
            amount1
        );
        require(liquidity > 0, "zero liquidity");

        IERC20(address(d.pxt)).approve(address(d.feeCollector), type(uint256).max);
        d.usdc.approve(address(d.feeCollector), type(uint256).max);
        d.feeCollector.addLiquidity(amount0, amount1, liquidity, abi.encode(address(d.feeCollector)));

        uint24 recycleWidth = uint24(vm.envOr("BUYBACK_RECYCLE_WIDTH_SPACINGS", uint256(10)));
        uint16 buybackSlip = uint16(vm.envOr("BUYBACK_MAX_SLIPPAGE_BPS", uint256(200)));
        d.feeCollector.setBuybackParams(recycleWidth, buybackSlip);

        _applyBuybackCallersFromEnv(d.feeCollector, address(0));

        // Intentionally NOT locking / renouncing — Arbitrum test deploy keeps admin control.
        // Production: make lock-anvil equivalent via LockProtocolReturnDelta + RECIPIENT_APPROVER.

        vm.stopBroadcast();
    }

    function _buildPoolKey(address pxt, address usdc, PhoenixV4ReturnDeltaHook hook)
        internal
        pure
        returns (PoolKey memory key)
    {
        Currency c0;
        Currency c1;
        if (pxt < usdc) {
            c0 = Currency.wrap(pxt);
            c1 = Currency.wrap(usdc);
        } else {
            c0 = Currency.wrap(usdc);
            c1 = Currency.wrap(pxt);
        }
        key = PoolKey({
            currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });
    }

    function _orderedAmounts(PoolKey memory key, address pxt, uint256 pxtAmt, uint256 usdcAmt)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (Currency.unwrap(key.currency0) == pxt) {
            return (pxtAmt, usdcAmt);
        }
        return (usdcAmt, pxtAmt);
    }

    function _sqrtPriceForSpot(address pxt, address usdc, uint256 pxtAmt, uint256 usdcAmt)
        internal
        pure
        returns (uint160)
    {
        uint256 amount0;
        uint256 amount1;
        if (pxt < usdc) {
            amount0 = pxtAmt;
            amount1 = usdcAmt;
        } else {
            amount0 = usdcAmt;
            amount1 = pxtAmt;
        }
        return _encodeSqrtRatioX96(amount1, amount0);
    }

    function _encodeSqrtRatioX96(uint256 amount1, uint256 amount0) internal pure returns (uint160) {
        require(amount0 > 0 && amount1 > 0, "zero amount");
        uint256 ratioX192 = (amount1 << 192) / amount0;
        uint256 sqrtX96 = _sqrt(ratioX192);
        require(sqrtX96 <= type(uint160).max, "sqrt overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(sqrtX96);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        uint256 xx = x;
        uint256 r = 1;
        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x8) r <<= 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        uint256 r1 = x / r;
        return (r < r1 ? r : r1);
    }

    function _logSummary(Deployed memory d) internal view {
        console2.log("=== Bootstrap Arbitrum (test, unlocked) complete ===");
        console2.log("Chain ID:", d.chainId);
        console2.log("Admin:", d.admin);
        console2.log("PXT:", address(d.pxt));
        console2.log("USDC:", address(d.usdc));
        console2.log("PhoenixV4ReturnDeltaHook:", address(d.hook));
        console2.log("PhoenixFeeCollector:", address(d.feeCollector));
        console2.log("PoolManager:", address(d.poolManager));
        console2.log("PoolSwapTest:", address(d.swapRouter));
        console2.log("currency0:", Currency.unwrap(d.poolKey.currency0));
        console2.log("currency1:", Currency.unwrap(d.poolKey.currency1));
        console2.log("fee:", d.poolKey.fee);
        console2.log("tickSpacing:", uint256(int256(d.poolKey.tickSpacing)));
        console2.log("hooks:", address(d.poolKey.hooks));
        console2.log("sqrtPriceX96:", d.sqrtPriceX96);
        console2.log("PXT seed (raw):", d.pxtSeed);
        console2.log("USDC seed (raw):", d.usdcSeed);
        console2.log("Target spot USDC/PXT: 0.001");
        console2.log("Donation wallet:", d.donation);
        console2.log("Marketing wallet:", d.marketing);
        console2.log("NoPenalty wallet:", d.noPenalty);
        console2.log("Anti-bot seller (openSell helper):", d.antiBotSeller);
        console2.log("Anti-bot operator (funds open):", d.openSell.operator());
        console2.log("PhoenixAntiBotOpenSell:", address(d.openSell));
        console2.log("sellAttributor:", address(d.pxt.sellAttributor()));
        console2.log("seedLiquidityAdded:", d.feeCollector.seedLiquidityAdded());
        console2.log("maxBuybackSlippageBps:", d.feeCollector.maxBuybackSlippageBps());
        console2.log("Sell unlock timestamp:", d.pxt.sellUnlockTimestamp());
        console2.log("Block timestamp:", block.timestamp);
        console2.log("Admin PXT balance:", d.pxt.balanceOf(d.admin));
        console2.log("Admin USDC balance:", d.usdc.balanceOf(d.admin));
        console2.log("LOCKED: false (admin Ownable retained for test)");
    }
}
