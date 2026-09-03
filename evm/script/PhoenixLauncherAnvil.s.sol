// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Pxt} from "../src/core/Pxt.sol";
import {DEFAULT_SELL_UNLOCK_TIMESTAMP} from "../src/core/PxtFeeModel.sol";
import {PhoenixV4ReturnDeltaHook} from "../src/return-delta/PhoenixV4ReturnDeltaHook.sol";
import {HookMiner} from "../src/uniswap/v4/HookMiner.sol";
import {V4Addresses} from "../src/uniswap/v4/V4Addresses.sol";
import {PhoenixLauncher} from "./launch/PhoenixLauncher.sol";
import {PhoenixOrchestrator} from "./launch/PhoenixOrchestrator.sol";
import {PhoenixLaunchTypes} from "./launch/PhoenixLaunchTypes.sol";
import {
    PhoenixPxtDeployer,
    PhoenixHookDeployer,
    PhoenixCollectorDeployer,
    PhoenixOpenSellDeployer
} from "./launch/PhoenixChildDeployers.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice TX1: deploy launcher + mUSDC (local), mine hook salt, `launch` (wire, no LP).
contract LaunchPhoenix is Script {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant DEFAULT_ANVIL_KEY_1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant DEFAULT_ANVIL_KEY_2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    uint256 internal constant DEFAULT_PXT_SEED_WHOLE = 210_000_000;
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
        uint256 pxtSeed = vm.envOr("LP_SEED_PXT_WHOLE", DEFAULT_PXT_SEED_WHOLE) * unit;
        uint256 usdcSeed = vm.envOr("LP_SEED_USDC_WHOLE", DEFAULT_USDC_SEED_WHOLE) * unit;
        bytes32 salt = vm.envOr("LAUNCH_SALT", bytes32(uint256(1)));

        address pm = _envOrAddr("POOL_MANAGER", V4Addresses.BASE_SEPOLIA_POOL_MANAGER);
        address swapTest = _envOrAddr("POOL_SWAP_TEST", V4Addresses.BASE_SEPOLIA_POOL_SWAP_TEST);
        address lpRouter = _envOrAddr("POOL_MODIFY_LIQUIDITY_TEST", V4Addresses.BASE_SEPOLIA_POOL_MODIFY_LIQUIDITY_TEST);
        address posm = _envOrAddr("POSITION_MANAGER", V4Addresses.BASE_SEPOLIA_POSITION_MANAGER);
        address operator = _envAddr("ANTI_BOT_SELLER");
        if (operator == address(0)) operator = client;

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
        p.quoteToken = address(musdc);
        p.donation = donation;
        p.marketing = marketing;
        p.operator = operator;
        p.swapRouter = swapTest;
        p.lpRouter = lpRouter;
        p.positionManager = posm;
        p.universalRouter = _envOrAddr("UNIVERSAL_ROUTER", V4Addresses.BASE_SEPOLIA_UNIVERSAL_ROUTER);
        p.sellUnlockTimestamp = sellUnlock;
        p.pxtSeed = pxtSeed;
        p.usdcSeed = usdcSeed;
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

        _log(client, launcher, orch, musdc, pxtSeed, usdcSeed, hookSalt);
    }

    function _log(
        address client,
        PhoenixLauncher launcher,
        PhoenixOrchestrator orch,
        MockERC20 musdc,
        uint256 pxtSeed,
        uint256 usdcSeed,
        bytes32 hookSalt
    ) internal view {
        Pxt token = orch.pxt();
        console2.log("=== LaunchPhoenix (TX1 wire) complete ===");
        console2.log("Admin:", client);
        console2.log("PhoenixLauncher:", address(launcher));
        console2.log("PhoenixOrchestrator:", address(orch));
        console2.log("PXT:", address(token));
        console2.log("USDC:", address(musdc));
        console2.log("mUSDC:", address(musdc));
        console2.log("PhoenixV4ReturnDeltaHook:", address(orch.hook()));
        console2.log("PhoenixFeeCollector:", address(orch.collector()));
        console2.log("PhoenixAntiBotOpenSell:", address(orch.openSell()));
        console2.log("PoolManager:", address(token.poolManager()));
        console2.log("PoolSwapTest:", address(orch.openSell().swapRouter()));
        console2.log("Donation wallet:", token.DONATION_WALLET());
        console2.log("Marketing wallet:", token.MARKETING_WALLET());
        console2.log("Anti-bot seller (openSell helper):", token.antiBotSeller());
        console2.log("Anti-bot operator (funds open):", orch.openSell().operator());
        console2.log("Sell unlock timestamp:", token.sellUnlockTimestamp());
        console2.log("Block timestamp:", block.timestamp);
        console2.log("PXT seed (raw):", pxtSeed);
        console2.log("mUSDC seed (raw):", usdcSeed);
        console2.log("hookSalt:", uint256(hookSalt));
        console2.log("sqrtPriceX96:", orch.sqrtPriceX96());
        console2.log("Orchestrator PXT balance:", token.balanceOf(address(orch)));
        console2.log("Client mUSDC balance:", musdc.balanceOf(client));
        console2.log("seedLiquidityAdded:", orch.collector().seedLiquidityAdded());
        (address c0, address c1) = _currencies(token, address(musdc));
        console2.log("currency0:", c0);
        console2.log("currency1:", c1);
        console2.log("Next: owner approves USDC + seeds in the launch wizard (MetaMask), then lock");
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

    function _envOrAddr(string memory envKey, address orAddr) private view returns (address) {
        address configured = _envAddr(envKey);
        return configured == address(0) ? orAddr : configured;
    }

    function _currencies(Pxt token, address quote) internal pure returns (address c0, address c1) {
        if (address(token) < quote) return (address(token), quote);
        return (quote, address(token));
    }

    function _wallet(string memory envKey, uint256 defaultKey) internal view returns (address wallet) {
        wallet = vm.addr(defaultKey);
        try vm.envAddress(envKey) returns (address configured) {
            if (configured != address(0)) wallet = configured;
        } catch {}
    }

    function _addrList(string memory envKey) internal view returns (address[] memory wallets) {
        try vm.envAddress(envKey, ",") returns (address[] memory configured) {
            return configured;
        } catch {
            return new address[](0);
        }
    }
}

/// @notice TX2: client approves mUSDC and seeds protocol LP.
contract SeedPhoenix is Script {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        uint256 clientKey = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        PhoenixOrchestrator orch = PhoenixOrchestrator(vm.envAddress("PHOENIX_ORCHESTRATOR"));
        address quote = orch.quoteToken();
        uint256 usdcAmt = orch.usdcSeed();

        vm.startBroadcast(clientKey);
        IERC20(quote).approve(address(orch), usdcAmt);
        PhoenixLaunchTypes.UsdcPermit memory permit;
        orch.seed(0, permit);
        vm.stopBroadcast();

        console2.log("=== SeedPhoenix (TX2 LP) complete ===");
        console2.log("PhoenixOrchestrator:", address(orch));
        console2.log("seedLiquidityAdded:", orch.collector().seedLiquidityAdded());
        (, uint128 liq) = orch.collector().quoteBuyback();
        console2.log("positionLiquidity:", liq);
        console2.log("Client mUSDC left:", IERC20(quote).balanceOf(vm.addr(clientKey)));
        console2.log("Orchestrator leftover PXT:", orch.pxt().balanceOf(address(orch)));
    }
}

/// @notice TX3: hand roles to RECIPIENT_APPROVER, authorize BUYBACK_CALLERS, renounce Ownable.
contract LockPhoenixOrchestrator is Script {
    uint256 internal constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        uint256 clientKey = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_KEY);
        PhoenixOrchestrator orch = PhoenixOrchestrator(vm.envAddress("PHOENIX_ORCHESTRATOR"));
        address approver = vm.envAddress("RECIPIENT_APPROVER");
        address[] memory callers = vm.envAddress("BUYBACK_CALLERS", ",");

        vm.startBroadcast(clientKey);
        orch.lock(approver, callers);
        vm.stopBroadcast();

        console2.log("=== LockPhoenixOrchestrator (TX3) complete ===");
        console2.log("PXT owner:", orch.pxt().owner());
        console2.log("Hook owner:", orch.hook().owner());
        console2.log("FeeCollector owner:", orch.collector().owner());
        console2.log("RecipientApprover:", approver);
        console2.log("Client leftover PXT:", orch.pxt().balanceOf(vm.addr(clientKey)));
        console2.log("locked:", orch.locked());
    }
}
