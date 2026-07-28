// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {Pxt} from "../src/core/Pxt.sol";
import {PhoenixAntiBotOpenSell} from "./PhoenixAntiBotOpenSell.sol";
import {PhoenixV4ReturnDeltaHook} from "../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {PhoenixFeeCollector} from "../src/fee/PhoenixFeeCollector.sol";
import {HookMiner} from "../src/uniswap/v4/HookMiner.sol";
import {V4Addresses} from "../src/uniswap/v4/V4Addresses.sol";
import {DEFAULT_SELL_UNLOCK_TIMESTAMP} from "../src/core/PxtFeeModel.sol";
import {WalletStatusConfig} from "./WalletStatusConfig.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

// Return-delta bootstrap: hook skims USDC → FeeCollector (deferred collect / cash buyback).
// Pool LP fee is 0; seed LP via FeeCollector (allowlisted during sell lock). Public LP after unlock.
// Optional FEE_EXEMPT_WALLETS / NO_PENALTY_WALLETS (comma-separated) applied before lock.
// Defaults Anvil #3 to NoPenalty when those env vars are unset (local UI demo).
contract BootstrapReturnDeltaFork is WalletStatusConfig {
    using CurrencyLibrary for Currency;

    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant DEFAULT_ANVIL_KEY_1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant DEFAULT_ANVIL_KEY_2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    /// @dev Static 0 LP fee - economics live in return-delta skims on the hook.
    uint24 internal constant LP_FEE = 0;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -887_220;
    int24 internal constant TICK_UPPER = 887_220;

    /// @dev Seed at 0.001 USDC/PXT: 21B PXT ↔ 21M mUSDC (full-range).
    uint256 internal constant DEFAULT_PXT_SEED_WHOLE = 210_000_000;
    uint256 internal constant DEFAULT_USDC_SEED_WHOLE = 210_000;

    struct Deployed {
        Pxt pxt;
        PhoenixV4ReturnDeltaHook hook;
        PhoenixFeeCollector feeCollector;
        PhoenixAntiBotOpenSell openSell;
        MockERC20 musdc;
        IPoolManager poolManager;
        PoolModifyLiquidityTest lpRouter;
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
        uint256 adminKey = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        Deployed memory d = _deploy(adminKey);
        _logSummary(d);
    }

    function _deploy(uint256 adminKey) internal returns (Deployed memory d) {
        d.admin = vm.addr(adminKey);
        d.chainId = vm.envOr("FORK_CHAIN_ID", uint256(84_532));
        d.donation = _feeWallet("DONATION_WALLET", DEFAULT_ANVIL_KEY_1);
        d.marketing = _feeWallet("MARKETING_WALLET", DEFAULT_ANVIL_KEY_2);
        d.antiBotSeller = vm.envOr("ANTI_BOT_SELLER", d.admin);
        if (d.antiBotSeller == address(0)) {
            d.antiBotSeller = d.admin;
        }
        // `ANTI_BOT_SELLER` is the ops EOA/operator that funds openWithExactInSell.
        // On-chain antiBotSeller is set to PhoenixAntiBotOpenSell after deploy (no tx.origin).
        address antiBotOperator = d.antiBotSeller;

        address pmAddr = vm.envOr("POOL_MANAGER", V4Addresses.BASE_SEPOLIA_POOL_MANAGER);
        d.poolManager = IPoolManager(pmAddr);

        address lpRouterAddr =
            vm.envOr("POOL_MODIFY_LIQUIDITY_TEST", V4Addresses.BASE_SEPOLIA_POOL_MODIFY_LIQUIDITY_TEST);
        d.lpRouter = PoolModifyLiquidityTest(lpRouterAddr);

        uint256 sellUnlock = vm.envOr("SELL_UNLOCK_TIMESTAMP", DEFAULT_SELL_UNLOCK_TIMESTAMP);
        if (block.timestamp >= sellUnlock) {
            revert("SELL_UNLOCK_TIMESTAMP is in the past; set a future date in .anvil-session.env");
        }

        uint8 quoteDecimals = uint8(vm.envOr("QUOTE_DECIMALS", uint256(6)));
        uint160 hookFlags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        vm.startBroadcast(adminKey);

        d.pxt = new Pxt(d.admin, d.donation, d.marketing, sellUnlock);
        d.musdc = new MockERC20("Mock USDC", "mUSDC", quoteDecimals, d.admin);

        d.pxt.setPoolManager(address(d.poolManager));

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
        d.pxt.setWalletStatus(address(d.feeCollector), Pxt.WalletStatus.FeeExempt);
        d.pxt.setSellAttributor(d.hook);
        d.pxt.setApprovedContractRecipient(address(d.lpRouter), true);
        address swapTest = vm.envOr("POOL_SWAP_TEST", V4Addresses.BASE_SEPOLIA_POOL_SWAP_TEST);
        d.pxt.setApprovedContractRecipient(swapTest, true);
        address posm = vm.envOr("POSITION_MANAGER", V4Addresses.BASE_SEPOLIA_POSITION_MANAGER);
        d.pxt.setApprovedContractRecipient(posm, true);

        d.openSell = new PhoenixAntiBotOpenSell(d.pxt, PoolSwapTest(swapTest), antiBotOperator);
        d.pxt.setApprovedContractRecipient(address(d.openSell), true);
        d.pxt.setWalletStatus(address(d.openSell), Pxt.WalletStatus.FeeExempt);
        // Helper is the on-chain anti-bot: clearSellProtection only via msg.sender == helper.
        d.pxt.setAntiBotSeller(address(d.openSell));
        d.antiBotSeller = address(d.openSell);

        // Extra FeeExempt / NoPenalty from env (defaults Anvil #3 → NoPenalty for local UI).
        d.noPenalty = _applyWalletStatusesFromEnv(d.pxt, true);

        d.poolKey = _buildPoolKey(d.pxt, d.musdc, d.hook);
        d.hook.setOfficialPool(d.poolKey);

        uint8 decimals = quoteDecimals;
        uint256 unit = 10 ** uint256(decimals);
        d.pxtSeed = vm.envOr("LP_SEED_PXT_WHOLE", DEFAULT_PXT_SEED_WHOLE) * unit;
        d.usdcSeed = vm.envOr("LP_SEED_USDC_WHOLE", DEFAULT_USDC_SEED_WHOLE) * unit;

        d.sqrtPriceX96 = uint160(
            vm.envOr(
                "SQRT_PRICE_X96", uint256(_sqrtPriceForSpot(address(d.pxt), address(d.musdc), d.pxtSeed, d.usdcSeed))
            )
        );

        d.poolManager.initialize(d.poolKey, d.sqrtPriceX96);

        // Seed via FeeCollector (allowlisted during sell lock). Public LP opens after sell unlock.
        d.feeCollector.configurePool(d.poolKey, TICK_LOWER, TICK_UPPER, bytes32(0));

        d.musdc.mint(d.admin, d.usdcSeed);

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
        IERC20(address(d.musdc)).approve(address(d.feeCollector), type(uint256).max);
        d.feeCollector.addLiquidity(amount0, amount1, liquidity, abi.encode(address(d.feeCollector)));

        // Buyback params (frozen by make lock-rd-anvil / LockProtocolReturnDelta). Cash-only; seed LP never peeled.
        uint24 recycleWidth = uint24(vm.envOr("BUYBACK_RECYCLE_WIDTH_SPACINGS", uint256(10)));
        // Default 200 bps MEV band (spot-referenced; prefer keeper + minPxtBought in production).
        uint16 buybackSlip = uint16(vm.envOr("BUYBACK_MAX_SLIPPAGE_BPS", uint256(200)));
        d.feeCollector.setBuybackParams(recycleWidth, buybackSlip);

        vm.stopBroadcast();
    }

    function _buildPoolKey(Pxt pxt, MockERC20 musdc, PhoenixV4ReturnDeltaHook hook)
        internal
        pure
        returns (PoolKey memory key)
    {
        Currency c0;
        Currency c1;
        if (address(pxt) < address(musdc)) {
            c0 = Currency.wrap(address(pxt));
            c1 = Currency.wrap(address(musdc));
        } else {
            c0 = Currency.wrap(address(musdc));
            c1 = Currency.wrap(address(pxt));
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
        console2.log("=== Bootstrap (return-delta) complete ===");
        console2.log("Chain ID:", d.chainId);
        console2.log("Admin:", d.admin);
        console2.log("PXT:", address(d.pxt));
        console2.log("mUSDC:", address(d.musdc));
        console2.log("PhoenixV4ReturnDeltaHook:", address(d.hook));
        console2.log("PhoenixFeeCollector:", address(d.feeCollector));
        console2.log("PoolManager:", address(d.poolManager));
        console2.log("PoolModifyLiquidityTest:", address(d.lpRouter));
        console2.log("currency0:", Currency.unwrap(d.poolKey.currency0));
        console2.log("currency1:", Currency.unwrap(d.poolKey.currency1));
        console2.log("fee:", d.poolKey.fee);
        console2.log("tickSpacing:", uint256(int256(d.poolKey.tickSpacing)));
        console2.log("hooks:", address(d.poolKey.hooks));
        console2.log("sqrtPriceX96:", d.sqrtPriceX96);
        console2.log("PXT seed (raw):", d.pxtSeed);
        console2.log("mUSDC seed (raw):", d.usdcSeed);
        console2.log("Target spot USDC/PXT: 0.001");
        console2.log("Donation wallet:", d.donation);
        console2.log("Marketing wallet:", d.marketing);
        console2.log("NoPenalty wallet:", d.noPenalty);
        console2.log("Anti-bot seller (openSell helper):", d.antiBotSeller);
        console2.log("Anti-bot operator (funds open):", d.openSell.operator());
        console2.log("PhoenixAntiBotOpenSell:", address(d.openSell));
        console2.log("Sell unlock timestamp:", d.pxt.sellUnlockTimestamp());
        console2.log("Block timestamp:", block.timestamp);
        console2.log("Admin PXT balance:", d.pxt.balanceOf(d.admin));
        console2.log("Admin mUSDC balance:", d.musdc.balanceOf(d.admin));
    }

    function _feeWallet(string memory envKey, uint256 defaultAnvilKey) internal view returns (address wallet) {
        wallet = vm.addr(defaultAnvilKey);
        try vm.envAddress(envKey) returns (address configured) {
            if (configured != address(0)) wallet = configured;
        } catch {}
    }
}
