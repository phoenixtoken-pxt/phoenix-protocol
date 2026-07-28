// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Pxt} from "../core/Pxt.sol";
import {FeeKind, ZeroAddress} from "../core/PxtFeeModel.sol";
import {PhoenixBuyback} from "./PhoenixBuyback.sol";

// Shared fee treasury for Phoenix hooks.
// Accrue via receiveAccruedFees (ReturnDelta USDC skims).
// LP / buyback / recycle live on PhoenixBuyback (this contract inherits it).
// collect() sweeps LP fee growth then pays donation / marketing / burn; buyback pending stays for executeBuyback.
// After payout, wallet/burn pending is reconciled down to on-hand ERC-20 (Uniswap rounding gap).
contract PhoenixFeeCollector is PhoenixBuyback {
    using SafeERC20 for IERC20;

    constructor(IPoolManager poolManager_, Pxt pxt_, address donation_, address marketing_, address admin_)
        PhoenixBuyback(poolManager_, pxt_, donation_, marketing_, admin_)
    {}

    function setHook(address hook_) external onlyOwner {
        if (hook_ == address(0)) revert ZeroAddress();
        if (hook != address(0)) revert HookAlreadySet();
        hook = hook_;
        emit HookSet(hook_);
    }

    /// @notice Return-delta: pull already-skimmed USDC (or other ERC-20) from the hook and book pending legs.
    /// @dev Caller must have approved `donation + marketing + burnAmount + buyback`.
    function receiveAccruedFees(
        address token,
        FeeKind kind,
        uint256 donation,
        uint256 marketing,
        uint256 burnAmount,
        uint256 buyback
    ) external onlyHook {
        if (token == address(0) || kind == FeeKind.None) return;
        // Only PXT is burnable via burnBalance; never book quote burn (would stall collect).
        if (token != address(pxt)) burnAmount = 0;
        uint256 total = donation + marketing + burnAmount + buyback;
        if (total == 0) return;

        IERC20(token).safeTransferFrom(msg.sender, address(this), total);

        if (donation > 0) pendingDonation[token] += donation;
        if (marketing > 0) pendingMarketing[token] += marketing;
        if (burnAmount > 0) pendingBurn[token] += burnAmount;
        if (buyback > 0) pendingBuyback[token] += buyback;

        emit FeeAccrued(token, kind, total, donation, marketing, burnAmount, buyback);
    }

    /// @notice Permissionless: pull Uniswap LP fees (seed + recycle bands) and pay wallets + burn.
    /// Pending buyback is left for `executeBuyback`.
    function collect() external nonReentrant returns (uint256 pulled0, uint256 pulled1) {
        if (!poolConfigured) revert PoolNotConfigured();

        PoolKey memory key = poolKey;
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        uint256 before0 = IERC20(token0).balanceOf(address(this));
        uint256 before1 = IERC20(token1).balanceOf(address(this));

        _pullLpFees();

        pulled0 = IERC20(token0).balanceOf(address(this)) - before0;
        pulled1 = IERC20(token1).balanceOf(address(this)) - before1;

        _payoutToken(token0, pulled0);
        _payoutToken(token1, pulled1);
    }

    function _payoutToken(address token, uint256 pulled) internal {
        uint256 donationDue = pendingDonation[token];
        uint256 marketingDue = pendingMarketing[token];
        uint256 burnDue = pendingBurn[token];

        // Quote (or any non-PXT) cannot be burned; drop the obligation so collect stays live.
        if (token != address(pxt) && burnDue > 0) {
            pendingBurn[token] = 0;
            burnDue = 0;
        }

        uint256 totalDue = donationDue + marketingDue + burnDue;

        uint256 bal = IERC20(token).balanceOf(address(this));

        if (bal == 0 || totalDue == 0) {
            emit FeesCollected(msg.sender, token, 0, 0, 0, 0, pulled);
            return;
        }

        // Prefer fulfilling burn first so sell/penalty PXT burn always runs when funds exist.
        uint256 burnPay = burnDue < bal ? burnDue : bal;
        uint256 remaining = bal - burnPay;

        uint256 walletsDue = donationDue + marketingDue;
        uint256 walletSpendable = remaining < walletsDue ? remaining : walletsDue;

        uint256 donationPay = 0;
        uint256 marketingPay = 0;
        if (walletsDue > 0 && walletSpendable > 0) {
            donationPay = (donationDue * walletSpendable) / walletsDue;
            marketingPay = (marketingDue * walletSpendable) / walletsDue;
            uint256 paid = donationPay + marketingPay;
            uint256 rem = walletSpendable - paid;
            if (rem > 0 && donationPay < donationDue) {
                uint256 add = rem < (donationDue - donationPay) ? rem : (donationDue - donationPay);
                donationPay += add;
                rem -= add;
            }
            if (rem > 0 && marketingPay < marketingDue) {
                uint256 add = rem < (marketingDue - marketingPay) ? rem : (marketingDue - marketingPay);
                marketingPay += add;
            }
        }

        pendingBurn[token] = burnDue - burnPay;
        pendingDonation[token] = donationDue - donationPay;
        pendingMarketing[token] = marketingDue - marketingPay;

        if (burnPay > 0) {
            _burnToken(token, burnPay);
        }
        if (donationPay > 0) IERC20(token).safeTransfer(donationWallet, donationPay);
        if (marketingPay > 0) IERC20(token).safeTransfer(marketingWallet, marketingPay);

        emit FeesCollected(msg.sender, token, donationPay, marketingPay, burnPay, 0, pulled);
        _reconcileWalletBurnPending(token);
    }

    /// @dev Cap donation/marketing/burn pending to on-hand balance (prefer burn). Buyback untouched.
    function _reconcileWalletBurnPending(address token) internal {
        uint256 don = pendingDonation[token];
        uint256 mkt = pendingMarketing[token];
        uint256 burn = pendingBurn[token];
        uint256 due = don + mkt + burn;
        if (due == 0) return;

        uint256 bal = IERC20(token).balanceOf(address(this));
        if (due <= bal) return;

        uint256 dueAfter;
        if (bal == 0) {
            pendingDonation[token] = 0;
            pendingMarketing[token] = 0;
            pendingBurn[token] = 0;
            dueAfter = 0;
        } else {
            uint256 burnKeep = burn < bal ? burn : bal;
            uint256 rest = bal - burnKeep;
            uint256 wallets = don + mkt;
            uint256 donKeep = 0;
            uint256 mktKeep = 0;
            if (wallets > 0 && rest > 0) {
                donKeep = (don * rest) / wallets;
                mktKeep = rest - donKeep;
            }
            pendingBurn[token] = burnKeep;
            pendingDonation[token] = donKeep;
            pendingMarketing[token] = mktKeep;
            dueAfter = burnKeep + donKeep + mktKeep;
        }

        emit AccrualReconciled(token, due, dueAfter);
    }
}
