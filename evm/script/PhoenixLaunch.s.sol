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
import {PhoenixFeeCollector} from "../src/fee/PhoenixFeeCollector.sol";
import {HookMiner} from "../src/uniswap/v4/HookMiner.sol";
import {V4Addresses} from "../src/uniswap/v4/V4Addresses.sol";
import {PhoenixAntiBotOpenSell} from "./PhoenixAntiBotOpenSell.sol";
import {PhoenixLauncher} from "./launch/PhoenixLauncher.sol";
import {PhoenixOrchestrator} from "./launch/PhoenixOrchestrator.sol";
import {PhoenixLaunchMath} from "./launch/PhoenixLaunchMath.sol";
import {PhoenixLaunchTypes} from "./launch/PhoenixLaunchTypes.sol";
import {PhoenixLaunchActions} from "./launch/PhoenixLaunchActions.sol";
import {
    PhoenixPxtDeployer,
    PhoenixHookDeployer,
    PhoenixCollectorDeployer,
    PhoenixOpenSellDeployer
} from "./launch/PhoenixChildDeployers.sol";

/// @dev Shared env / chain helpers for the 4-phase live ceremony.
abstract contract PhoenixLaunchBase is Script, PhoenixLaunchActions {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

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

    function _launchOwner(uint256 deployerKey) internal view returns (address client) {
        client = _envAddr("LAUNCH_OWNER");
        if (client != address(0)) return client;
        return vm.addr(deployerKey);
    }

    function _operator(address client) internal view returns (address operator) {
        operator = _envAddr("OPEN_SELL_OPERATOR");
        if (operator != address(0)) return operator;
        operator = _envAddr("ANTI_BOT_OPERATOR");
        if (operator != address(0)) return operator;
        return client;
    }

    function _envAddr(string memory envKey) internal view returns (address) {
        try vm.envAddress(envKey) returns (address configured) {
            return configured;
        } catch {
            return address(0);
        }
    }

    function _envOrAddr(string memory envKey, address orAddr) internal view returns (address) {
        address configured = _envAddr(envKey);
        return configured == address(0) ? orAddr : configured;
    }

    function _addrList(string memory envKey) internal view returns (address[] memory wallets) {
        try vm.envAddress(envKey, ",") returns (address[] memory configured) {
            return configured;
        } catch {
            return new address[](0);
        }
    }

    function _chainV4() internal view returns (ChainV4 memory c) {
        uint256 id = block.chainid;
        if (id == 42161) {
            c.poolManager = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
            c.quote = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
            c.positionManager = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;
            c.universalRouter = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;
        } else if (id == 8453) {
            c.poolManager = V4Addresses.BASE_POOL_MANAGER;
            c.quote = V4Addresses.BASE_USDC;
            c.positionManager = V4Addresses.BASE_POSITION_MANAGER;
            c.universalRouter = V4Addresses.BASE_UNIVERSAL_ROUTER;
        } else if (id == 84532) {
            c.poolManager = V4Addresses.BASE_SEPOLIA_POOL_MANAGER;
            c.positionManager = V4Addresses.BASE_SEPOLIA_POSITION_MANAGER;
            c.universalRouter = V4Addresses.BASE_SEPOLIA_UNIVERSAL_ROUTER;
            c.swapTest = V4Addresses.BASE_SEPOLIA_POOL_SWAP_TEST;
            c.lpRouter = V4Addresses.BASE_SEPOLIA_POOL_MODIFY_LIQUIDITY_TEST;
        }
    }

    function _currencies(address token, address quote) internal pure returns (address c0, address c1) {
        if (token < quote) return (token, quote);
        return (quote, token);
    }

    function _seedRaw() internal view returns (uint256 pxtSeed, uint256 usdcSeed, uint8 decimals) {
        address quote = _envOrAddr("QUOTE_TOKEN_ADDRESS", _chainV4().quote);
        require(quote != address(0), "QUOTE_TOKEN_ADDRESS required");
        decimals = IERC20Metadata(quote).decimals();
        uint256 unit = 10 ** uint256(decimals);
        pxtSeed = vm.envOr("LP_SEED_PXT_WHOLE", DEFAULT_PXT_SEED_WHOLE) * unit;
        usdcSeed = vm.envOr("LP_SEED_USDC_WHOLE", DEFAULT_USDC_SEED_WHOLE) * unit;
    }

    function _slot0Sqrt(IPoolManager pm, PoolKey memory key) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = pm.getSlot0(key.toId());
    }
}

/// @notice Phase 1: deploy launcher/orch (if needed) + Pxt. Supply + Ownable → admin.
contract CreateToken is PhoenixLaunchBase {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address client = _launchOwner(deployerKey);
        address donation = vm.envAddress("DONATION_WALLET");
        address marketing = vm.envAddress("MARKETING_WALLET");
        require(donation != address(0) && marketing != address(0), "fee wallets required");

        uint256 sellUnlock = vm.envOr("SELL_UNLOCK_TIMESTAMP", DEFAULT_SELL_UNLOCK_TIMESTAMP);
        if (block.timestamp >= sellUnlock) revert("SELL_UNLOCK_TIMESTAMP is in the past");
        bytes32 salt = vm.envOr("LAUNCH_SALT", bytes32(uint256(1)));

        vm.startBroadcast(deployerKey);

        PhoenixLauncher launcher;
        PhoenixOrchestrator orch;
        address existingOrch = _envAddr("PHOENIX_ORCHESTRATOR");
        address existingLauncher = _envAddr("PHOENIX_LAUNCHER");

        if (existingOrch != address(0) && existingOrch.code.length > 0) {
            orch = PhoenixOrchestrator(existingOrch);
            require(orch.launchOwner() == client, "orch launchOwner mismatch");
            launcher = PhoenixLauncher(orch.factory());
        } else {
            PhoenixPxtDeployer pxtDeployer = new PhoenixPxtDeployer();
            PhoenixHookDeployer hookDeployer = new PhoenixHookDeployer();
            PhoenixCollectorDeployer collectorDeployer = new PhoenixCollectorDeployer();
            PhoenixOpenSellDeployer openSellDeployer = new PhoenixOpenSellDeployer();
            launcher = new PhoenixLauncher(
                address(pxtDeployer), address(hookDeployer), address(collectorDeployer), address(openSellDeployer)
            );
            orch = client == vm.addr(deployerKey) ? launcher.create(salt) : launcher.createFor(client, salt);
            console2.log("PhoenixPxtDeployer:", address(pxtDeployer));
            console2.log("PhoenixHookDeployer:", address(hookDeployer));
            console2.log("PhoenixCollectorDeployer:", address(collectorDeployer));
            console2.log("PhoenixOpenSellDeployer:", address(openSellDeployer));
        }

        if (existingLauncher != address(0) && address(launcher) != existingLauncher) {
            // keep going — factory from orch is source of truth
        }

        address orchPredicted = launcher.predictOrchestrator(client, salt);
        require(address(orch) == orchPredicted || existingOrch != address(0), "orch predict");

        Pxt token;
        if (orch.phase() == PhoenixOrchestrator.Phase.None) {
            bytes memory pxtInit =
                abi.encodePacked(type(Pxt).creationCode, abi.encode(client, donation, marketing, sellUnlock));
            address pxtPredicted = HookMiner.computeAddress(
                address(orch.pxtDeployer()), uint256(launcher.pxtCreate2Salt(address(orch))), pxtInit
            );

            token = orch.createToken(donation, marketing, sellUnlock);
            require(address(token) == pxtPredicted, "pxt predict");
            require(token.balanceOf(client) == token.TOTAL_SUPPLY(), "admin must hold supply");
        } else {
            token = orch.pxt();
            require(address(token) != address(0), "missing pxt");
            console2.log("Resume: token already created");
        }

        require(token.owner() == client, "admin must own Pxt");

        vm.stopBroadcast();

        console2.log("=== Phase 1 CreateToken complete ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Admin:", client);
        console2.log("PhoenixLauncher:", address(launcher));
        console2.log("PhoenixOrchestrator:", address(orch));
        console2.log("PXT:", address(token));
        console2.log("Donation wallet:", donation);
        console2.log("Marketing wallet:", marketing);
        console2.log("Sell unlock timestamp:", sellUnlock);
        console2.log("Admin PXT balance:", token.balanceOf(client));
        console2.log("phase:", uint256(orch.phase()));
        console2.log("Next: transfer treasury to MAIN, then make deploy-pool CLUSTER=...");
    }
}

/// @notice Phase 2: deploy LP stack + admin configures + initializes spot from LP_SEED_* ratio.
contract DeployPool is PhoenixLaunchBase {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address client = _launchOwner(deployerKey);
        PhoenixOrchestrator orch = PhoenixOrchestrator(vm.envAddress("PHOENIX_ORCHESTRATOR"));
        require(orch.launchOwner() == client, "signer is not launchOwner");
        PhoenixOrchestrator.Phase ph = orch.phase();
        require(
            ph == PhoenixOrchestrator.Phase.TokenCreated || ph == PhoenixOrchestrator.Phase.PoolContractsDeployed,
            "need TokenCreated or PoolContractsDeployed"
        );

        ChainV4 memory chain = _chainV4();
        address pm = _envOrAddr("POOL_MANAGER", chain.poolManager);
        address quote = _envOrAddr("QUOTE_TOKEN_ADDRESS", chain.quote);
        address posm = _envOrAddr("POSITION_MANAGER", chain.positionManager);
        address ur = _envOrAddr("UNIVERSAL_ROUTER", chain.universalRouter);
        address lpRouter = _envOrAddr("POOL_MODIFY_LIQUIDITY_TEST", chain.lpRouter);
        address swapTest = _envOrAddr("POOL_SWAP_TEST", chain.swapTest);
        require(pm != address(0) && quote != address(0), "pool/quote required");

        (uint256 pxtSeed, uint256 usdcSeed,) = _seedRaw();
        address operator = _operator(client);
        Pxt token = orch.pxt();

        PhoenixLaunchTypes.LaunchParams memory p;
        p.poolManager = IPoolManager(pm);
        p.quoteToken = quote;
        p.donation = orch.donation();
        p.marketing = orch.marketing();
        p.operator = operator;
        p.swapRouter = swapTest;
        p.lpRouter = lpRouter;
        p.positionManager = posm;
        p.universalRouter = ur;
        p.sellUnlockTimestamp = orch.sellUnlockTimestamp();
        p.pxtSeed = pxtSeed;
        p.usdcSeed = usdcSeed;
        p.sqrtPriceX96 = uint160(vm.envOr("SQRT_PRICE_X96", uint256(0)));
        p.recycleWidthSpacings = uint24(vm.envOr("BUYBACK_RECYCLE_WIDTH_SPACINGS", uint256(10)));
        p.maxBuybackSlippageBps = uint16(vm.envOr("BUYBACK_MAX_SLIPPAGE_BPS", uint256(200)));
        p.feeExempt = _addrList("FEE_EXEMPT_WALLETS");
        p.noPenalty = _addrList("NO_PENALTY_WALLETS");

        vm.startBroadcast(deployerKey);

        if (p.swapRouter == address(0)) {
            p.swapRouter = address(new PoolSwapTest(IPoolManager(pm)));
        }

        PhoenixV4ReturnDeltaHook h;
        PhoenixFeeCollector fc;
        PhoenixAntiBotOpenSell os;

        if (ph == PhoenixOrchestrator.Phase.TokenCreated) {
            (, bytes32 hookSalt) = HookMiner.find(
                address(orch.hookDeployer()),
                PhoenixLaunchTypes.hookFlags(),
                type(PhoenixV4ReturnDeltaHook).creationCode,
                abi.encode(IPoolManager(pm), address(token), operator, client)
            );
            p.hookSalt = hookSalt;
            (h, fc, os) = orch.deployPoolContracts(p);
        } else {
            h = orch.hook();
            fc = orch.collector();
            os = orch.openSell();
            console2.log("Resume: pool contracts already deployed - configuring");
        }

        int24 lo = orch.tickLower();
        int24 hi = orch.tickUpper();
        uint160 sqrtPrice = _configureAndInit(p, token, h, fc, os, client, lo, hi);
        orch.markPoolConfigured(sqrtPrice);

        vm.stopBroadcast();

        PoolKey memory key = PhoenixLaunchMath.poolKey(address(token), quote, address(h));
        uint160 spot = _slot0Sqrt(IPoolManager(pm), key);
        require(spot == sqrtPrice, "sqrtPrice mismatch");

        (address c0, address c1) = _currencies(address(token), quote);
        console2.log("=== Phase 2 DeployPool complete ===");
        console2.log("Admin:", client);
        console2.log("PXT:", address(token));
        console2.log("USDC:", quote);
        console2.log("PhoenixV4ReturnDeltaHook:", address(h));
        console2.log("PhoenixFeeCollector:", address(fc));
        console2.log("PhoenixAntiBotOpenSell:", address(os));
        console2.log("PoolManager:", pm);
        console2.log("PoolSwapTest:", p.swapRouter);
        console2.log("Anti-bot seller (openSell helper):", address(os));
        console2.log("Anti-bot operator (funds open):", os.operator());
        console2.log("PXT seed (raw):", pxtSeed);
        console2.log("USDC seed (raw):", usdcSeed);
        console2.log("sqrtPriceX96:", sqrtPrice);
        console2.log("currency0:", c0);
        console2.log("currency1:", c1);
        console2.log("Admin PXT balance:", token.balanceOf(client));
        console2.log("phase:", uint256(orch.phase()));
        console2.log("Next: fund admin with seed PXT+USDC ratio, then make seed CLUSTER=...");
    }
}

/// @notice Phase 3: admin approves FeeCollector and seeds LP (must hold pxtSeed + usdcSeed).
contract SeedProtocol is PhoenixLaunchBase {
    function run() external {
        uint256 clientKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(clientKey);
        PhoenixOrchestrator orch = PhoenixOrchestrator(vm.envAddress("PHOENIX_ORCHESTRATOR"));
        require(owner == orch.launchOwner(), "signer is not launchOwner");
        require(orch.phase() == PhoenixOrchestrator.Phase.PoolConfigured, "need PoolConfigured");

        Pxt token = orch.pxt();
        PhoenixFeeCollector fc = orch.collector();
        address quote = orch.quoteToken();
        uint256 pxtAmt = orch.pxtSeed();
        uint256 usdcAmt = orch.usdcSeed();
        require(token.balanceOf(owner) >= pxtAmt, "owner needs LP_SEED PXT");
        require(IERC20(quote).balanceOf(owner) >= usdcAmt, "owner needs LP_SEED quote");

        vm.startBroadcast(clientKey);
        _seedAsOwner(token, fc, quote, pxtAmt, usdcAmt, orch.sqrtPriceX96(), orch.tickLower(), orch.tickUpper(), 0);
        orch.markSeeded();
        vm.stopBroadcast();

        console2.log("=== Phase 3 Seed complete ===");
        console2.log("PhoenixOrchestrator:", address(orch));
        console2.log("seedLiquidityAdded:", fc.seedLiquidityAdded());
        (, uint128 liq) = fc.quoteBuyback();
        console2.log("positionLiquidity:", liq);
        console2.log("Owner PXT left:", token.balanceOf(owner));
        console2.log("Owner quote left:", IERC20(quote).balanceOf(owner));
        console2.log("phase:", uint256(orch.phase()));
        console2.log("Next: make lock CLUSTER=...");
    }
}

/// @notice Phase 4: hand roles to RECIPIENT_APPROVER, renounce Ownable.
contract LockProtocol is PhoenixLaunchBase {
    function run() external {
        uint256 clientKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(clientKey);
        PhoenixOrchestrator orch = PhoenixOrchestrator(vm.envAddress("PHOENIX_ORCHESTRATOR"));
        address approver = vm.envAddress("RECIPIENT_APPROVER");
        address[] memory callers = vm.envAddress("BUYBACK_CALLERS", ",");
        require(owner == orch.launchOwner(), "signer is not launchOwner");
        require(orch.phase() == PhoenixOrchestrator.Phase.Seeded, "need Seeded");

        vm.startBroadcast(clientKey);
        _lockAsOwner(orch.pxt(), orch.hook(), orch.collector(), owner, approver, callers);
        orch.markLocked(approver);
        vm.stopBroadcast();

        console2.log("=== Phase 4 Lock complete ===");
        console2.log("PXT owner:", orch.pxt().owner());
        console2.log("Hook owner:", orch.hook().owner());
        console2.log("FeeCollector owner:", orch.collector().owner());
        console2.log("RecipientApprover:", approver);
        console2.log("Owner leftover PXT:", orch.pxt().balanceOf(owner));
        console2.log("locked:", orch.locked());
        console2.log("phase:", uint256(orch.phase()));
    }
}
