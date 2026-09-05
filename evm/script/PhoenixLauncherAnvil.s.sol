// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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
import {PhoenixLaunchTypes} from "./launch/PhoenixLaunchTypes.sol";
import {PhoenixLaunchActions} from "./launch/PhoenixLaunchActions.sol";
import {
    PhoenixPxtDeployer,
    PhoenixHookDeployer,
    PhoenixCollectorDeployer,
    PhoenixOpenSellDeployer
} from "./launch/PhoenixChildDeployers.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Anvil Phase 1: launcher + orch + Pxt (admin owns supply) + mint mUSDC to admin.
contract CreateTokenAnvil is Script {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant DEFAULT_ANVIL_KEY_1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant DEFAULT_ANVIL_KEY_2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant DEFAULT_USDC_SEED_WHOLE = 210_000;

    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        address client = _launchOwner(deployerKey);
        address donation = _wallet("DONATION_WALLET", DEFAULT_ANVIL_KEY_1);
        address marketing = _wallet("MARKETING_WALLET", DEFAULT_ANVIL_KEY_2);
        uint256 sellUnlock = vm.envOr("SELL_UNLOCK_TIMESTAMP", DEFAULT_SELL_UNLOCK_TIMESTAMP);
        if (block.timestamp >= sellUnlock) revert("SELL_UNLOCK_TIMESTAMP is in the past");

        uint8 quoteDecimals = uint8(vm.envOr("QUOTE_DECIMALS", uint256(6)));
        uint256 unit = 10 ** uint256(quoteDecimals);
        uint256 usdcSeed = vm.envOr("LP_SEED_USDC_WHOLE", DEFAULT_USDC_SEED_WHOLE) * unit;
        bytes32 salt = vm.envOr("LAUNCH_SALT", bytes32(uint256(1)));

        vm.deal(client, 10 ether);

        vm.startBroadcast(deployerKey);
        MockERC20 musdc = _quote(quoteDecimals, vm.addr(deployerKey));
        musdc.mint(client, usdcSeed);

        PhoenixPxtDeployer pxtDeployer = new PhoenixPxtDeployer();
        PhoenixHookDeployer hookDeployer = new PhoenixHookDeployer();
        PhoenixLauncher launcher = new PhoenixLauncher(
            address(pxtDeployer),
            address(hookDeployer),
            address(new PhoenixCollectorDeployer()),
            address(new PhoenixOpenSellDeployer())
        );
        PhoenixOrchestrator orch =
            client == vm.addr(deployerKey) ? launcher.create(salt) : launcher.createFor(client, salt);

        bytes memory pxtInit =
            abi.encodePacked(type(Pxt).creationCode, abi.encode(client, donation, marketing, sellUnlock));
        address pxtPredicted =
            HookMiner.computeAddress(address(pxtDeployer), uint256(launcher.pxtCreate2Salt(address(orch))), pxtInit);

        Pxt token = orch.createToken(donation, marketing, sellUnlock);
        require(address(token) == pxtPredicted, "pxt predict");
        require(token.owner() == client, "admin must own Pxt");
        require(token.balanceOf(client) == token.TOTAL_SUPPLY(), "admin must hold supply");

        vm.stopBroadcast();

        console2.log("=== Phase 1 CreateTokenAnvil complete ===");
        console2.log("Admin:", client);
        console2.log("PhoenixLauncher:", address(launcher));
        console2.log("PhoenixOrchestrator:", address(orch));
        console2.log("PXT:", address(token));
        console2.log("USDC:", address(musdc));
        console2.log("mUSDC:", address(musdc));
        console2.log("Donation wallet:", donation);
        console2.log("Marketing wallet:", marketing);
        console2.log("Sell unlock timestamp:", sellUnlock);
        console2.log("Admin PXT balance:", token.balanceOf(client));
        console2.log("Client mUSDC balance:", musdc.balanceOf(client));
        console2.log("phase:", uint256(orch.phase()));
        console2.log("Next: make deploy-pool CLUSTER=anvil");
    }

    function _launchOwner(uint256 deployerKey) private view returns (address client) {
        client = _envAddr("LAUNCH_OWNER");
        if (client != address(0)) return client;
        return vm.addr(deployerKey);
    }

    function _quote(uint8 quoteDecimals, address owner) private returns (MockERC20 musdc) {
        address existing = _envAddr("QUOTE_TOKEN_ADDRESS");
        if (existing != address(0) && existing.code.length > 0) return MockERC20(existing);
        return new MockERC20("Mock USDC", "mUSDC", quoteDecimals, owner);
    }

    function _envAddr(string memory envKey) private view returns (address) {
        try vm.envAddress(envKey) returns (address configured) {
            return configured;
        } catch {
            return address(0);
        }
    }

    function _wallet(string memory envKey, uint256 defaultKey) internal view returns (address wallet) {
        wallet = vm.addr(defaultKey);
        try vm.envAddress(envKey) returns (address configured) {
            if (configured != address(0)) wallet = configured;
        } catch {}
    }
}

/// @notice Anvil Phase 2: deploy pool stack + configure + init spot (admin owns).
contract DeployPoolAnvil is Script, PhoenixLaunchActions {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant DEFAULT_PXT_SEED_WHOLE = 210_000_000;
    uint256 internal constant DEFAULT_USDC_SEED_WHOLE = 210_000;

    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        address client = _launchOwner(deployerKey);
        PhoenixOrchestrator orch = PhoenixOrchestrator(vm.envAddress("PHOENIX_ORCHESTRATOR"));
        require(orch.launchOwner() == client, "signer is not launchOwner");
        require(orch.phase() == PhoenixOrchestrator.Phase.TokenCreated, "need TokenCreated");

        address pm = _envOrAddr("POOL_MANAGER", V4Addresses.BASE_SEPOLIA_POOL_MANAGER);
        address quote = vm.envAddress("QUOTE_TOKEN_ADDRESS");
        address swapTest = _envOrAddr("POOL_SWAP_TEST", V4Addresses.BASE_SEPOLIA_POOL_SWAP_TEST);
        address lpRouter = _envOrAddr("POOL_MODIFY_LIQUIDITY_TEST", V4Addresses.BASE_SEPOLIA_POOL_MODIFY_LIQUIDITY_TEST);
        address posm = _envOrAddr("POSITION_MANAGER", V4Addresses.BASE_SEPOLIA_POSITION_MANAGER);
        address ur = _envOrAddr("UNIVERSAL_ROUTER", V4Addresses.BASE_SEPOLIA_UNIVERSAL_ROUTER);
        address operator = _envAddr("OPEN_SELL_OPERATOR");
        if (operator == address(0)) operator = _envAddr("ANTI_BOT_OPERATOR");
        if (operator == address(0)) operator = client;

        uint8 quoteDecimals = uint8(vm.envOr("QUOTE_DECIMALS", uint256(6)));
        uint256 unit = 10 ** uint256(quoteDecimals);
        uint256 pxtSeed = vm.envOr("LP_SEED_PXT_WHOLE", DEFAULT_PXT_SEED_WHOLE) * unit;
        uint256 usdcSeed = vm.envOr("LP_SEED_USDC_WHOLE", DEFAULT_USDC_SEED_WHOLE) * unit;

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
        p.recycleWidthSpacings = uint24(vm.envOr("BUYBACK_RECYCLE_WIDTH_SPACINGS", uint256(10)));
        p.maxBuybackSlippageBps = uint16(vm.envOr("BUYBACK_MAX_SLIPPAGE_BPS", uint256(200)));
        p.feeExempt = _addrList("FEE_EXEMPT_WALLETS");
        p.noPenalty = _addrList("NO_PENALTY_WALLETS");

        vm.startBroadcast(deployerKey);

        if (p.swapRouter == address(0)) {
            p.swapRouter = address(new PoolSwapTest(IPoolManager(pm)));
        }

        (, bytes32 hookSalt) = HookMiner.find(
            address(orch.hookDeployer()),
            PhoenixLaunchTypes.hookFlags(),
            type(PhoenixV4ReturnDeltaHook).creationCode,
            abi.encode(IPoolManager(pm), address(token), operator, client)
        );
        p.hookSalt = hookSalt;

        (PhoenixV4ReturnDeltaHook h, PhoenixFeeCollector fc, PhoenixAntiBotOpenSell os) = orch.deployPoolContracts(p);
        uint160 sqrtPrice = _configureAndInit(p, token, h, fc, os, client, orch.tickLower(), orch.tickUpper());
        orch.markPoolConfigured(sqrtPrice);

        vm.stopBroadcast();

        console2.log("=== Phase 2 DeployPoolAnvil complete ===");
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
        (address c0, address c1) = address(token) < quote ? (address(token), quote) : (quote, address(token));
        console2.log("currency0:", c0);
        console2.log("currency1:", c1);
        console2.log("phase:", uint256(orch.phase()));
        console2.log("Next: make seed CLUSTER=anvil");
    }

    function _launchOwner(uint256 deployerKey) private view returns (address client) {
        client = _envAddr("LAUNCH_OWNER");
        if (client != address(0)) return client;
        return vm.addr(deployerKey);
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

    function _addrList(string memory envKey) internal view returns (address[] memory wallets) {
        try vm.envAddress(envKey, ",") returns (address[] memory configured) {
            return configured;
        } catch {
            return new address[](0);
        }
    }
}

/// @notice Anvil Phase 3: admin seeds LP.
contract SeedPhoenix is Script, PhoenixLaunchActions {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        uint256 clientKey = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
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

        console2.log("=== Phase 3 SeedPhoenix complete ===");
        console2.log("PhoenixOrchestrator:", address(orch));
        console2.log("seedLiquidityAdded:", fc.seedLiquidityAdded());
        (, uint128 liq) = fc.quoteBuyback();
        console2.log("positionLiquidity:", liq);
        console2.log("Owner PXT left:", token.balanceOf(owner));
        console2.log("Owner quote left:", IERC20(quote).balanceOf(owner));
        console2.log("phase:", uint256(orch.phase()));
    }
}

/// @notice Anvil Phase 4: hand roles + renounce.
contract LockPhoenixOrchestrator is Script, PhoenixLaunchActions {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        uint256 clientKey = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
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

        console2.log("=== Phase 4 LockPhoenixOrchestrator complete ===");
        console2.log("PXT owner:", orch.pxt().owner());
        console2.log("Hook owner:", orch.hook().owner());
        console2.log("FeeCollector owner:", orch.collector().owner());
        console2.log("RecipientApprover:", approver);
        console2.log("Owner leftover PXT:", orch.pxt().balanceOf(owner));
        console2.log("locked:", orch.locked());
        console2.log("phase:", uint256(orch.phase()));
    }
}
