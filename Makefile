# EVM targets for local Anvil (Base Sepolia fork).

EVM_DIR := evm
WEB_DIR := web
EVM_CLUSTER ?= anvil
EVM_ENV_FILE := $(EVM_DIR)/.env.$(EVM_CLUSTER)

BASE_SEPOLIA_RPC_URL ?= https://sepolia.base.org
# Upstream RPC used only when starting the fork (never localhost).
FORK_UPSTREAM_RPC_URL ?= $(BASE_SEPOLIA_RPC_URL)

ifneq (,$(wildcard $(EVM_ENV_FILE)))
include $(EVM_ENV_FILE)
export
endif

ANVIL_DEFAULT_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
# Anvil account #5 - first TESTER_RECIPIENTS address (non-FeeExempt for sell/buyback demos)
ANVIL_TESTER_KEY := 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba
SHARES_WALLET := 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
# Manual testers #5-#9 only (#4 Shares wallet receives rent USDC - not mint-funded)
TESTER_RECIPIENTS := 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc,0x976EA74026E726554dB657fA54763abd0C3a0aa9,0x14dC79964da2C08b23698B3D3cc7Ca32193d9955,0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f,0xa0Ee7A142d267C1f36714E4a8F75612F20a79720
TESTER_MUSDC_WHOLE := 10000
TESTER_PXT_WHOLE := 10000
TESTER_ETH_AMOUNT ?= 10ether
ANVIL_RPC_URL ?= http://127.0.0.1:8545
ANVIL_ACCOUNTS ?= 11

.PHONY: help evm-deps evm-build evm-clean evm-test evm-fmt anvil-base-sepolia-fork \
        bootstrap-anvil bootstrap-return-delta-anvil \
        swap-anvil open-trading-anvil warp-anvil-unlock lock-anvil lock-rd-anvil \
        set-wallet-statuses-anvil \
        status-anvil collect-fees-anvil execute-buyback-anvil demo-buyback-anvil \
        mint-musdc-anvil distribute-pxt-anvil fund-testers-anvil \
        fund-eth-anvil fund-all-eth-anvil \
        web-deps web-dev web-env \
        explorer explorer-stop

help:
	@echo "Local Anvil testing (Base Sepolia fork only):"
	@echo ""
	@echo "  make anvil-base-sepolia-fork              Start Anvil fork (chain 84532)"
	@echo "  make bootstrap-anvil                      Deploy PXT + PhoenixV4ReturnDeltaHook + FeeCollector"
	@echo "  make bootstrap-return-delta-anvil         Alias → bootstrap-anvil"
	@echo "  make set-wallet-statuses-anvil            Apply FEE_EXEMPT_WALLETS / NO_PENALTY_WALLETS (before lock)"
	@echo "  make lock-anvil                           Renounce stack; hand Pxt roles to RECIPIENT_APPROVER"
	@echo "  make lock-rd-anvil                        Alias → lock-anvil"
	@echo "  make status-anvil                         Spot, pending fees, buyback quote"
	@echo "  make warp-anvil-unlock                    Warp past sellUnlockTimestamp"
	@echo "  make open-trading-anvil                   Atomic clearSellProtection + anti-bot sell"
	@echo "  make swap-anvil                           Swap (DIRECTION=buy|sell AMOUNT_WHOLE=...)"
	@echo "  make collect-fees-anvil                   Pull LP fees → donation/marketing/burn"
	@echo "  make execute-buyback-anvil                Cash / LP buyback via FeeCollector"
	@echo "  make demo-buyback-anvil                   Full local buyback dry-run"
	@echo "  make fund-testers-anvil / distribute-pxt-anvil / web-dev"
	@echo ""
	@echo "  make evm-deps evm-build evm-test"

evm-deps:
	@if [ ! -d $(EVM_DIR)/lib/forge-std ]; then \
		mkdir -p $(EVM_DIR)/lib && \
		git clone --depth 1 https://github.com/foundry-rs/forge-std $(EVM_DIR)/lib/forge-std && \
		git clone --depth 1 https://github.com/OpenZeppelin/openzeppelin-contracts.git $(EVM_DIR)/lib/openzeppelin-contracts; \
	fi
	@if [ ! -d $(EVM_DIR)/lib/uniswap-hooks/src ]; then \
		git clone --depth 1 --branch v1.2.1 https://github.com/OpenZeppelin/uniswap-hooks.git $(EVM_DIR)/lib/uniswap-hooks; \
	fi
	@if [ ! -d $(EVM_DIR)/lib/v4-core/src ]; then \
		git clone --depth 1 https://github.com/Uniswap/v4-core $(EVM_DIR)/lib/v4-core; \
	fi
	@if [ ! -f $(EVM_DIR)/lib/v4-core/lib/solmate/src/auth/Owned.sol ]; then \
		cd $(EVM_DIR)/lib/v4-core && git submodule update --init --recursive; \
	fi
	@if [ ! -d $(EVM_DIR)/lib/v4-periphery/src ]; then \
		git clone --depth 1 https://github.com/Uniswap/v4-periphery $(EVM_DIR)/lib/v4-periphery; \
	fi
	@if [ ! -d $(EVM_DIR)/lib/v4-periphery/lib/v4-core/src ]; then \
		cd $(EVM_DIR)/lib/v4-periphery && git submodule update --init --recursive; \
	fi

evm-build: evm-deps
	cd $(EVM_DIR) && forge build

evm-clean:
	cd $(EVM_DIR) && forge clean

evm-test: evm-deps
	cd $(EVM_DIR) && forge test -vvv

evm-fmt:
	cd $(EVM_DIR) && forge fmt

anvil-base-sepolia-fork:
	@chmod +x $(EVM_DIR)/scripts/write-anvil-session.sh
	@bash $(EVM_DIR)/scripts/write-anvil-session.sh $(EVM_DIR)
	@url="$(FORK_UPSTREAM_RPC_URL)"; \
	case "$$url" in http://127.0.0.1:*|http://localhost:*) \
	  url="https://sepolia.base.org"; \
	  echo "Note: ignoring localhost fork URL from evm/.env.anvil; using $$url"; \
	esac; \
	test -n "$$url" || (echo "FORK_UPSTREAM_RPC_URL not set" && exit 1); \
	echo "Starting Anvil fork at live chain head (current Base Sepolia time)"; \
	anvil --fork-url $$url --chain-id 84532 --port 8545 --block-time 1 --accounts $(ANVIL_ACCOUNTS)

BOOTSTRAP_LOG := /tmp/pxt-bootstrap-fork.log

bootstrap-return-delta-anvil: bootstrap-anvil

bootstrap-anvil: evm-build
	@$(MAKE) --no-print-directory _bootstrap-anvil-inner \
		HOOK_MODE=return-delta \
		BOOTSTRAP_SCRIPT=script/BootstrapReturnDeltaFork.s.sol:BootstrapReturnDeltaFork

_bootstrap-anvil-inner:
	@test -n "$$(curl -sf -X POST -H 'Content-Type: application/json' \
		--data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_chainId\",\"params\":[],\"id\":1}' \
		http://127.0.0.1:8545 2>/dev/null)" || \
		(echo "Start Anvil first: make anvil-base-sepolia-fork" && exit 1)
	@test -f $(EVM_DIR)/.anvil-session.env || \
		(echo "Missing $(EVM_DIR)/.anvil-session.env - restart with make anvil-base-sepolia-fork" && exit 1)
	@test -n "$(BOOTSTRAP_SCRIPT)" || (echo "BOOTSTRAP_SCRIPT required" && exit 1)
	@test -n "$(HOOK_MODE)" || (echo "HOOK_MODE required" && exit 1)
	@chmod +x $(EVM_DIR)/scripts/write-fork-env.sh
	@bash -eo pipefail -c '\
	set -a && . $(EVM_DIR)/.anvil-session.env && set +a && \
	( cd $(EVM_DIR) && PRIVATE_KEY=$(or $(PRIVATE_KEY),$(ANVIL_DEFAULT_KEY)) \
		SELL_UNLOCK_TIMESTAMP=$$SELL_UNLOCK_TIMESTAMP \
		forge script $(BOOTSTRAP_SCRIPT) \
		--rpc-url anvil --broadcast --force -vvvv ) 2>&1 | tee $(BOOTSTRAP_LOG) && \
	mkdir -p $(WEB_DIR) && \
	HOOK_MODE=$(HOOK_MODE) bash $(EVM_DIR)/scripts/write-fork-env.sh \
		$(BOOTSTRAP_LOG) $(EVM_DIR)/.env.anvil $(WEB_DIR)/.env'

swap-anvil: evm-build
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil _swap-anvil-inner

_swap-anvil-inner:
	@test -f $(EVM_DIR)/.env.anvil || (echo "Missing evm/.env.anvil - run make bootstrap-anvil" && exit 1)
	@test -n "$(PXT_ADDRESS)" || (echo "PXT_ADDRESS not set in evm/.env.anvil" && exit 1)
	@test -n "$(PHOENIX_HOOK)" || (echo "PHOENIX_HOOK not set" && exit 1)
	@test -n "$(QUOTE_TOKEN_ADDRESS)" || (echo "QUOTE_TOKEN_ADDRESS not set" && exit 1)
	cd $(EVM_DIR) && DIRECTION="$(or $(DIRECTION),buy)" AMOUNT_WHOLE="$(or $(AMOUNT_WHOLE),100)" \
		PRIVATE_KEY="$(or $(PRIVATE_KEY),$(ANVIL_DEFAULT_KEY))" \
		forge script script/Swap.s.sol:Swap \
		--rpc-url anvil --broadcast -vvvv

# Atomic anti-bot ceremony: clearSellProtection + Admin sell in one tx (AMOUNT_WHOLE default 100).
open-trading-anvil: evm-build
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil _open-trading-anvil-inner

_open-trading-anvil-inner:
	@test -f $(EVM_DIR)/.env.anvil || (echo "Missing evm/.env.anvil - run make bootstrap-anvil" && exit 1)
	@test -n "$(PXT_ADDRESS)" || (echo "PXT_ADDRESS not set in evm/.env.anvil" && exit 1)
	@test -n "$(PHOENIX_HOOK)" || (echo "PHOENIX_HOOK not set" && exit 1)
	@test -n "$(QUOTE_TOKEN_ADDRESS)" || (echo "QUOTE_TOKEN_ADDRESS not set" && exit 1)
	@test -n "$(ANTI_BOT_OPEN_SELL)" || (echo "ANTI_BOT_OPEN_SELL missing - re-run make bootstrap-anvil" && exit 1)
	cd $(EVM_DIR) && AMOUNT_WHOLE="$(or $(AMOUNT_WHOLE),100)" \
		PRIVATE_KEY="$(or $(PRIVATE_KEY),$(ANVIL_DEFAULT_KEY))" \
		forge script script/OpenTrading.s.sol:OpenTrading \
		--rpc-url anvil --broadcast -vvvv

warp-anvil-unlock:
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil _warp-anvil-unlock-inner

_warp-anvil-unlock-inner:
	@test -f $(EVM_DIR)/.env.anvil || (echo "Missing evm/.env.anvil - run make bootstrap-anvil" && exit 1)
	@bash $(EVM_DIR)/scripts/warp-anvil-unlock.sh $(EVM_DIR)/.env.anvil

# Final ceremony: assert LP + floor + buyback cap, hand Pxt roles to RECIPIENT_APPROVER
# (multisig), renounce FeeCollector → Hook → Pxt Ownable. Collect/buyback stay permissionless;
# setApprovedContractRecipient stays on RECIPIENT_APPROVER_ROLE.
# Requires sellAttributor == hook. Optional env: BUYBACK_*, RECIPIENT_APPROVER (default Anvil #4)
# Apply wallet status lists first if needed: make set-wallet-statuses-anvil
ANVIL_RECIPIENT_APPROVER ?= 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
lock-rd-anvil: lock-anvil

set-wallet-statuses-anvil: evm-build
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil _set-wallet-statuses-anvil-inner

_set-wallet-statuses-anvil-inner:
	@test -f $(EVM_DIR)/.env.anvil || (echo "Missing evm/.env.anvil - run make bootstrap-anvil" && exit 1)
	@test -n "$(PXT_ADDRESS)" || (echo "PXT_ADDRESS missing - run make bootstrap-anvil" && exit 1)
	cd $(EVM_DIR) && PRIVATE_KEY="$(or $(PRIVATE_KEY),$(ANVIL_DEFAULT_KEY))" \
		forge script script/SetWalletStatuses.s.sol:SetWalletStatuses \
		--rpc-url anvil --broadcast -vvvv

lock-anvil: evm-build
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil _lock-anvil-inner

_lock-anvil-inner:
	@test -f $(EVM_DIR)/.env.anvil || (echo "Missing evm/.env.anvil - run make bootstrap-anvil" && exit 1)
	@test -n "$(FEE_COLLECTOR)" || (echo "FEE_COLLECTOR missing - run make bootstrap-anvil" && exit 1)
	@test -n "$(PHOENIX_HOOK)" || (echo "PHOENIX_HOOK missing" && exit 1)
	@test -n "$(PXT_ADDRESS)" || (echo "PXT_ADDRESS missing" && exit 1)
	cd $(EVM_DIR) && PRIVATE_KEY="$(or $(PRIVATE_KEY),$(ANVIL_DEFAULT_KEY))" \
		RECIPIENT_APPROVER="$(or $(RECIPIENT_APPROVER),$(ANVIL_RECIPIENT_APPROVER))" \
		forge script script/LockProtocolReturnDelta.s.sol:LockProtocolReturnDelta \
		--rpc-url anvil --broadcast -vvvv

status-anvil: evm-build
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil _status-anvil-inner

_status-anvil-inner:
	@test -f $(EVM_DIR)/.env.anvil || (echo "Missing evm/.env.anvil - run make bootstrap-anvil" && exit 1)
	@test -n "$(FEE_COLLECTOR)" || (echo "FEE_COLLECTOR missing - run make bootstrap-anvil" && exit 1)
	cd $(EVM_DIR) && forge script script/StatusAnvil.s.sol:StatusAnvil --rpc-url anvil -vv

collect-fees-anvil: evm-build
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil _collect-fees-anvil-inner

_collect-fees-anvil-inner:
	@test -f $(EVM_DIR)/.env.anvil || (echo "Missing evm/.env.anvil - run make bootstrap-anvil" && exit 1)
	@test -n "$(FEE_COLLECTOR)" || (echo "FEE_COLLECTOR missing - run make bootstrap-anvil" && exit 1)
	cd $(EVM_DIR) && PRIVATE_KEY="$(or $(PRIVATE_KEY),$(ANVIL_DEFAULT_KEY))" \
		forge script script/CollectFees.s.sol:CollectFees \
		--rpc-url anvil --broadcast -vvvv

execute-buyback-anvil: evm-build
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil _execute-buyback-anvil-inner

_execute-buyback-anvil-inner:
	@test -f $(EVM_DIR)/.env.anvil || (echo "Missing evm/.env.anvil - run make bootstrap-anvil" && exit 1)
	@test -n "$(FEE_COLLECTOR)" || (echo "FEE_COLLECTOR missing - run make bootstrap-anvil" && exit 1)
	cd $(EVM_DIR) && PRIVATE_KEY="$(or $(PRIVATE_KEY),$(ANVIL_DEFAULT_KEY))" \
		MIN_PXT_BOUGHT="$(or $(MIN_PXT_BOUGHT),0)" \
		DEADLINE_SECONDS="$(or $(DEADLINE_SECONDS),600)" \
		forge script script/ExecuteBuyback.s.sol:ExecuteBuyback \
		--rpc-url anvil --broadcast -vvvv

# Local-only dry-run: unlock → clear anti-bot → penalty sell as tester → collect → buyback.
demo-buyback-anvil:
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil _demo-buyback-anvil-inner

_demo-buyback-anvil-inner:
	@test -f $(EVM_DIR)/.env.anvil || (echo "Missing evm/.env.anvil - run make bootstrap-anvil" && exit 1)
	@test -n "$(FEE_COLLECTOR)" || (echo "FEE_COLLECTOR missing - run make bootstrap-anvil" && exit 1)
	@echo "=== demo-buyback-anvil (local fork only) ==="
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil warp-anvil-unlock
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil distribute-pxt-anvil \
		AMOUNT_WHOLE="$(or $(TESTER_PXT_WHOLE),10000)"
	@echo "--- open trading (atomic clear + Admin sell) ---"
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil open-trading-anvil AMOUNT_WHOLE=1
	@echo "--- tester penalty sell ( >10% of balance ) ---"
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil swap-anvil \
		DIRECTION=sell AMOUNT_WHOLE="$(or $(BUYBACK_SELL_WHOLE),2000)" \
		PRIVATE_KEY="$(ANVIL_TESTER_KEY)"
	@echo "--- status before collect ---"
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil status-anvil
	@echo "--- collect fees (burn/donation/marketing; buyback stays pending) ---"
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil collect-fees-anvil
	@echo "--- execute buyback ---"
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil execute-buyback-anvil
	@echo "--- status after buyback ---"
	@$(MAKE) --no-print-directory EVM_CLUSTER=anvil status-anvil
	@echo "=== demo-buyback-anvil done ==="

mint-musdc-anvil: evm-build
	@test -f $(EVM_ENV_FILE) || (echo "Missing $(EVM_ENV_FILE) - run make bootstrap-anvil" && exit 1)
	@if [ "$(FUND_ETH)" != "false" ]; then \
		ANVIL_RPC_URL="$(ANVIL_RPC_URL)" \
		FUND_ETH_AMOUNT="$(TESTER_ETH_AMOUNT)" \
		FUND_ETH_MODE=min \
		FUND_ETH_INCLUDE_PROTOCOL=false \
		FUND_ETH_INCLUDE_TESTERS=false \
		bash $(EVM_DIR)/scripts/fund-eth-anvil.sh \
			"$(or $(RECIPIENTS),$(TESTER_RECIPIENTS))"; \
	fi
	cd $(EVM_DIR) && RECIPIENTS="$(or $(RECIPIENTS),$(TESTER_RECIPIENTS))" \
		AMOUNT_WHOLE="$(or $(MUSDC_AMOUNT_WHOLE),$(TESTER_MUSDC_WHOLE))" \
		FUND_ETH=false \
		TOKEN_ADDRESS=$(QUOTE_TOKEN_ADDRESS) \
		forge script script/MintMockToken.s.sol:MintMockToken \
		--rpc-url anvil --broadcast -vvvv

distribute-pxt-anvil: evm-build
	@test -f $(EVM_ENV_FILE) || (echo "Missing $(EVM_ENV_FILE) - run make bootstrap-anvil" && exit 1)
	@if [ "$(FUND_ETH)" != "false" ]; then \
		ANVIL_RPC_URL="$(ANVIL_RPC_URL)" \
		FUND_ETH_AMOUNT="$(TESTER_ETH_AMOUNT)" \
		FUND_ETH_MODE=min \
		FUND_ETH_INCLUDE_PROTOCOL=false \
		FUND_ETH_INCLUDE_TESTERS=false \
		bash $(EVM_DIR)/scripts/fund-eth-anvil.sh \
			"$(or $(RECIPIENTS),$(TESTER_RECIPIENTS))"; \
	fi
	cd $(EVM_DIR) && RECIPIENTS="$(or $(RECIPIENTS),$(TESTER_RECIPIENTS))" \
		AMOUNT_WHOLE="$(or $(PXT_AMOUNT_WHOLE),$(TESTER_PXT_WHOLE))" \
		FUND_ETH=false \
		forge script script/Distribute.s.sol:Distribute \
		--rpc-url anvil --broadcast -vvvv

fund-testers-anvil: evm-build
	@test -f $(EVM_ENV_FILE) || (echo "Missing $(EVM_ENV_FILE) - run make bootstrap-anvil" && exit 1)
	@bash $(EVM_DIR)/scripts/reset-tester-eoas.sh \
		"$(or $(RECIPIENTS),$(TESTER_RECIPIENTS))" \
		"$(ANVIL_RPC_URL)"
	cd $(EVM_DIR) && RECIPIENTS="$(or $(RECIPIENTS),$(TESTER_RECIPIENTS))" \
		AMOUNT_WHOLE="$(or $(MUSDC_AMOUNT_WHOLE),$(TESTER_MUSDC_WHOLE))" \
		FUND_ETH=false \
		TOKEN_ADDRESS=$(QUOTE_TOKEN_ADDRESS) \
		forge script script/MintMockToken.s.sol:MintMockToken \
		--rpc-url anvil --broadcast -vvvv

fund-eth-anvil:
	@chmod +x $(EVM_DIR)/scripts/fund-eth-anvil.sh
	@FUND_ETH_AMOUNT="$(TESTER_ETH_AMOUNT)" \
		FUND_ETH_ALL=false \
		bash $(EVM_DIR)/scripts/fund-eth-anvil.sh

fund-all-eth-anvil:
	@chmod +x $(EVM_DIR)/scripts/fund-eth-anvil.sh
	@FUND_ETH_AMOUNT="$(or $(FUND_ETH_AMOUNT),$(TESTER_ETH_AMOUNT))" \
		FUND_ETH_ALL=true \
		ANVIL_ACCOUNTS="$(ANVIL_ACCOUNTS)" \
		bash $(EVM_DIR)/scripts/fund-eth-anvil.sh

web-deps:
	cd $(WEB_DIR) && npm install

web-env:
	@test -f $(EVM_ENV_FILE) || (echo "Missing $(EVM_ENV_FILE) - run make bootstrap-anvil" && exit 1)
	@chmod +x $(EVM_DIR)/scripts/write-web-env.sh
	@bash $(EVM_DIR)/scripts/write-web-env.sh $(EVM_ENV_FILE) $(WEB_DIR)/.env

web-dev: web-deps web-env
	@test -n "$$(grep '^VITE_PXT_ADDRESS=.' $(WEB_DIR)/.env 2>/dev/null)" || \
		(echo "PXT address missing in $(WEB_DIR)/.env - run make bootstrap-anvil" && exit 1)
	cd $(WEB_DIR) && npm run dev

# Local block explorer (Otterscan) against Anvil. Requires Docker + running Anvil.
EXPLORER_PORT ?= 5100
EXPLORER_NAME ?= pxt-otterscan

explorer:
	@chmod +x $(EVM_DIR)/scripts/run-otterscan.sh
	@ANVIL_RPC_URL="$(ANVIL_RPC_URL)" EXPLORER_PORT="$(EXPLORER_PORT)" \
		EXPLORER_NAME="$(EXPLORER_NAME)" bash $(EVM_DIR)/scripts/run-otterscan.sh

explorer-stop:
	@docker rm -f $(EXPLORER_NAME) >/dev/null 2>&1 && \
		echo "Stopped $(EXPLORER_NAME)" || echo "No container named $(EXPLORER_NAME)"
