// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Pxt} from "../src/core/Pxt.sol";
import {DEFAULT_SELL_UNLOCK_TIMESTAMP} from "../src/core/PxtFeeModel.sol";
import {PhoenixV4ReturnDeltaHook} from "../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {HookMiner} from "../src/uniswap/v4/HookMiner.sol";
import {V4Addresses} from "../src/uniswap/v4/V4Addresses.sol";
import {PhoenixLauncher} from "./launch/PhoenixLauncher.sol";
import {PhoenixOrchestrator} from "./launch/PhoenixOrchestrator.sol";
import {PhoenixLaunchMath} from "./launch/PhoenixLaunchMath.sol";
import {PhoenixLaunchTypes} from "./launch/PhoenixLaunchTypes.sol";
import {
    PhoenixPxtDeployer,
    PhoenixHookDeployer,
    PhoenixCollectorDeployer,
    PhoenixOpenSellDeployer
} from "./launch/PhoenixChildDeployers.sol";

/// @notice Live TX1: deploy launcher + children, mine hook salt, `launch` (wire, no LP).
/// @dev Chain-agnostic. Uniswap v4 + USDC defaults for Arbitrum One (42161), Base (8453),
///      Base Sepolia (84532). Override with POOL_MANAGER / QUOTE_TOKEN_ADDRESS / etc.
///      No mock tokens, no `vm.deal`. Seed and lock are separate scripts.
contract LaunchProtocol is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Default $20 at 0.001 USDC/PXT → 20,000 PXT.
    uint256 internal constant DEFAULT_PXT_SEED_WHOLE = 20_000;
    uint256 internal constant DEFAULT_USDC_SEED_WHOLE = 20;

    struct ChainV4 {
        address poolManager;
        address quote;
        address positionManager;
        address universalRouter;
        address swapTest;
        address lpRouter;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address client = _launchOwner(deployerKey);
        address donation = vm.envAddress("DONATION_WALLET");
        address marketing = vm.envAddress("MARKETING_WALLET");
        require(donation != address(0) && marketing != address(0), "fee wallets required");

        uint256 sellUnlock = vm.envOr("SELL_UNLOCK_TIMESTAMP", DEFAULT_SELL_UNLOCK_TIMESTAMP);
        if (block.timestamp >= sellUnlock) revert("SELL_UNLOCK_TIMESTAMP is in the past");

        ChainV4 memory chain = _chainV4();
        address pm = _envOrAddr("POOL_MANAGER", chain.poolManager);
        address quote = _envOrAddr("QUOTE_TOKEN_ADDRESS", chain.quote);
        address posm = _envOrAddr("POSITION_MANAGER", chain.positionManager);
        address ur = _envOrAddr("UNIVERSAL_ROUTER", chain.universalRouter);
        address lpRouter = _envOrAddr("POOL_MODIFY_LIQUIDITY_TEST", chain.lpRouter);
        address swapTest = _envOrAddr("POOL_SWAP_TEST", chain.swapTest);
        require(pm != address(0), "POOL_MANAGER required");
        require(quote != address(0), "QUOTE_TOKEN_ADDRESS required");

        uint8 quoteDecimals = IERC20Metadata(quote).decimals();
        uint256 unit = 10 ** uint256(quoteDecimals);
        uint256 pxtSeed = vm.envOr("LP_SEED_PXT_WHOLE", DEFAULT_PXT_SEED_WHOLE) * unit;
        uint256 usdcSeed = vm.envOr("LP_SEED_USDC_WHOLE", DEFAULT_USDC_SEED_WHOLE) * unit;
        bytes32 salt = vm.envOr("LAUNCH_SALT", bytes32(uint256(1)));
        address operator = _operator(client);

        vm.startBroadcast(deployerKey);

        if (swapTest == address(0)) {
            swapTest = address(new PoolSwapTest(IPoolManager(pm)));
        }

        PhoenixPxtDeployer pxtDeployer = new PhoenixPxtDeployer();
        PhoenixHookDeployer hookDeployer = new PhoenixHookDeployer();
        PhoenixCollectorDeployer collectorDeployer = new PhoenixCollectorDeployer();
        PhoenixOpenSellDeployer openSellDeployer = new PhoenixOpenSellDeployer();
        PhoenixLauncher launcher = new PhoenixLauncher(
            address(pxtDeployer), address(hookDeployer), address(collectorDeployer), address(openSellDeployer)
        );

        address orchPredicted = launcher.predictOrchestrator(client, salt);
        bytes memory pxtInit =
            abi.encodePacked(type(Pxt).creationCode, abi.encode(orchPredicted, donation, marketing, sellUnlock));
        address pxtPredicted =
            HookMiner.computeAddress(address(pxtDeployer), uint256(launcher.pxtCreate2Salt(orchPredicted)), pxtInit);

        (address hookPredicted, bytes32 hookSalt) = HookMiner.find(
            address(hookDeployer),
            launcher.hookFlags(),
            type(PhoenixV4ReturnDeltaHook).creationCode,
            abi.encode(IPoolManager(pm), pxtPredicted, operator, orchPredicted)
        );

        PhoenixLaunchTypes.LaunchParams memory p;
        p.poolManager = IPoolManager(pm);
        p.quoteToken = quote;
        p.donation = donation;
        p.marketing = marketing;
        p.operator = operator;
        p.swapRouter = swapTest;
        p.lpRouter = lpRouter;
        p.positionManager = posm;
        p.universalRouter = ur;
        p.sellUnlockTimestamp = sellUnlock;
        p.pxtSeed = pxtSeed;
        p.usdcSeed = usdcSeed;
        p.sqrtPriceX96 = uint160(vm.envOr("SQRT_PRICE_X96", uint256(0)));
        p.hookSalt = hookSalt;
        p.recycleWidthSpacings = uint24(vm.envOr("BUYBACK_RECYCLE_WIDTH_SPACINGS", uint256(10)));
        p.maxBuybackSlippageBps = uint16(vm.envOr("BUYBACK_MAX_SLIPPAGE_BPS", uint256(200)));
        p.feeExempt = _addrList("FEE_EXEMPT_WALLETS");
        p.noPenalty = _addrList("NO_PENALTY_WALLETS");

        PhoenixOrchestrator orch =
            client == vm.addr(deployerKey) ? launcher.launch(salt, p) : launcher.launchFor(client, salt, p);

        vm.stopBroadcast();

        require(address(orch) == orchPredicted, "orch predict");
        require(address(orch.pxt()) == pxtPredicted, "pxt predict");
        require(address(orch.hook()) == hookPredicted, "hook predict");
        require(!orch.collector().seedLiquidityAdded(), "seed ran during wire");

        PoolKey memory key = PhoenixLaunchMath.poolKey(address(orch.pxt()), quote, address(orch.hook()));
        (uint160 spot,,,) = IPoolManager(pm).getSlot0(key.toId());
        require(spot == orch.sqrtPriceX96(), "sqrtPrice mismatch after initialize");

        _log(
            client,
            launcher,
            orch,
            pxtDeployer,
            hookDeployer,
            collectorDeployer,
            openSellDeployer,
            swapTest,
            pxtSeed,
            usdcSeed,
            hookSalt
        );
    }

    function _log(
        address client,
        PhoenixLauncher launcher,
        PhoenixOrchestrator orch,
        PhoenixPxtDeployer pxtDeployer,
        PhoenixHookDeployer hookDeployer,
        PhoenixCollectorDeployer collectorDeployer,
        PhoenixOpenSellDeployer openSellDeployer,
        address swapTest,
        uint256 pxtSeed,
        uint256 usdcSeed,
        bytes32 hookSalt
    ) internal view {
        Pxt token = orch.pxt();
        address quote = orch.quoteToken();
        console2.log("=== LaunchProtocol (TX1 wire) complete ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Admin:", client);
        console2.log("PhoenixPxtDeployer:", address(pxtDeployer));
        console2.log("PhoenixHookDeployer:", address(hookDeployer));
        console2.log("PhoenixCollectorDeployer:", address(collectorDeployer));
        console2.log("PhoenixOpenSellDeployer:", address(openSellDeployer));
        console2.log("PhoenixLauncher:", address(launcher));
        console2.log("PhoenixOrchestrator:", address(orch));
        console2.log("PXT:", address(token));
        console2.log("USDC:", quote);
        console2.log("PhoenixV4ReturnDeltaHook:", address(orch.hook()));
        console2.log("PhoenixFeeCollector:", address(orch.collector()));
        console2.log("PhoenixAntiBotOpenSell:", address(orch.openSell()));
        console2.log("PoolManager:", address(token.poolManager()));
        console2.log("PoolSwapTest:", swapTest);
        console2.log("Donation wallet:", token.DONATION_WALLET());
        console2.log("Marketing wallet:", token.MARKETING_WALLET());
        console2.log("Anti-bot seller (openSell helper):", token.antiBotSeller());
        console2.log("Anti-bot operator (funds open):", orch.openSell().operator());
        console2.log("Sell unlock timestamp:", token.sellUnlockTimestamp());
        console2.log("Block timestamp:", block.timestamp);
        console2.log("PXT seed (raw):", pxtSeed);
        console2.log("USDC seed (raw):", usdcSeed);
        console2.log("hookSalt:", uint256(hookSalt));
        console2.log("sqrtPriceX96:", orch.sqrtPriceX96());
        console2.log("Orchestrator PXT balance:", token.balanceOf(address(orch)));
        console2.log("Owner USDC balance:", IERC20(quote).balanceOf(client));
        console2.log("seedLiquidityAdded:", orch.collector().seedLiquidityAdded());
        (address c0, address c1) = _currencies(address(token), quote);
        console2.log("currency0:", c0);
        console2.log("currency1:", c1);
        console2.log("Next: make seed  (owner approves USDC + seeds LP), then make lock");
    }

    function _chainV4() internal view returns (ChainV4 memory c) {
        uint256 id = block.chainid;
        if (id == 42_161) {
            c.poolManager = V4Addresses.ARBITRUM_POOL_MANAGER;
            c.quote = V4Addresses.ARBITRUM_USDC;
            c.positionManager = V4Addresses.ARBITRUM_POSITION_MANAGER;
            c.universalRouter = V4Addresses.ARBITRUM_UNIVERSAL_ROUTER;
            return c;
        }
        if (id == 8453) {
            c.poolManager = V4Addresses.BASE_POOL_MANAGER;
            c.quote = V4Addresses.BASE_USDC;
            c.positionManager = V4Addresses.BASE_POSITION_MANAGER;
            c.universalRouter = V4Addresses.BASE_UNIVERSAL_ROUTER;
            return c;
        }
        if (id == 84_532) {
            c.poolManager = V4Addresses.BASE_SEPOLIA_POOL_MANAGER;
            c.positionManager = V4Addresses.BASE_SEPOLIA_POSITION_MANAGER;
            c.universalRouter = V4Addresses.BASE_SEPOLIA_UNIVERSAL_ROUTER;
            c.swapTest = V4Addresses.BASE_SEPOLIA_POOL_SWAP_TEST;
            c.lpRouter = V4Addresses.BASE_SEPOLIA_POOL_MODIFY_LIQUIDITY_TEST;
            return c;
        }
        revert("unsupported chainid: set POOL_MANAGER and QUOTE_TOKEN_ADDRESS");
    }

    function _launchOwner(uint256 deployerKey) private view returns (address client) {
        client = _envAddr("LAUNCH_OWNER");
        if (client != address(0)) return client;
        return vm.addr(deployerKey);
    }

    /// @dev Prefer OPEN_SELL_OPERATOR / ANTI_BOT_OPERATOR (EOA). ANTI_BOT_SELLER is the
    ///      openSell helper after env rewrite, so it is last-resort for a first launch only.
    function _operator(address client) private view returns (address operator) {
        operator = _envAddr("OPEN_SELL_OPERATOR");
        if (operator != address(0)) return operator;
        operator = _envAddr("ANTI_BOT_OPERATOR");
        if (operator != address(0)) return operator;
        operator = _envAddr("ANTI_BOT_SELLER");
        if (operator != address(0)) return operator;
        return client;
    }

    function _envAddr(string memory envKey) private view returns (address) {
        try vm.envAddress(envKey) returns (address configured) {
            return configured;
        } catch {
            return address(0);
        }
    }

    function _envOrAddr(string memory envKey, address orAddr) private view returns (address) {
        address configured = _envAddr(envKey);
        return configured == address(0) ? orAddr : configured;
    }

    function _currencies(address token, address quote) internal pure returns (address c0, address c1) {
        if (token < quote) return (token, quote);
        return (quote, token);
    }

    function _addrList(string memory envKey) internal view returns (address[] memory wallets) {
        try vm.envAddress(envKey, ",") returns (address[] memory configured) {
            return configured;
        } catch {
            return new address[](0);
        }
    }
}

/// @notice Live TX2: launch owner approves quote token and seeds protocol LP.
contract SeedProtocol is Script {
    function run() external {
        uint256 clientKey = vm.envUint("PRIVATE_KEY");
        PhoenixOrchestrator orch = PhoenixOrchestrator(vm.envAddress("PHOENIX_ORCHESTRATOR"));
        address quote = orch.quoteToken();
        uint256 usdcAmt = orch.usdcSeed();
        address owner = vm.addr(clientKey);
        require(owner == orch.launchOwner(), "signer is not launchOwner");
        require(IERC20(quote).balanceOf(owner) >= usdcAmt, "owner needs LP_SEED quote tokens");

        vm.startBroadcast(clientKey);
        IERC20(quote).approve(address(orch), usdcAmt);
        PhoenixLaunchTypes.UsdcPermit memory permit;
        orch.seed(0, permit);
        vm.stopBroadcast();

        console2.log("=== SeedProtocol (TX2 LP) complete ===");
        console2.log("PhoenixOrchestrator:", address(orch));
        console2.log("seedLiquidityAdded:", orch.collector().seedLiquidityAdded());
        (, uint128 liq) = orch.collector().quoteBuyback();
        console2.log("positionLiquidity:", liq);
        console2.log("Owner quote left:", IERC20(quote).balanceOf(owner));
        console2.log("Orchestrator leftover PXT:", orch.pxt().balanceOf(address(orch)));
    }
}

/// @notice Live TX3: hand roles to RECIPIENT_APPROVER, authorize BUYBACK_CALLERS, renounce Ownable.
contract LockProtocol is Script {
    function run() external {
        uint256 clientKey = vm.envUint("PRIVATE_KEY");
        PhoenixOrchestrator orch = PhoenixOrchestrator(vm.envAddress("PHOENIX_ORCHESTRATOR"));
        address approver = vm.envAddress("RECIPIENT_APPROVER");
        address[] memory callers = vm.envAddress("BUYBACK_CALLERS", ",");
        require(vm.addr(clientKey) == orch.launchOwner(), "signer is not launchOwner");

        vm.startBroadcast(clientKey);
        orch.lock(approver, callers);
        vm.stopBroadcast();

        console2.log("=== LockProtocol (TX3) complete ===");
        console2.log("PXT owner:", orch.pxt().owner());
        console2.log("Hook owner:", orch.hook().owner());
        console2.log("FeeCollector owner:", orch.collector().owner());
        console2.log("RecipientApprover:", approver);
        console2.log("Owner leftover PXT:", orch.pxt().balanceOf(vm.addr(clientKey)));
        console2.log("locked:", orch.locked());
    }
}
