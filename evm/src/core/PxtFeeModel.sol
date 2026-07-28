// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Shared fee tiers, types, and pure math for PXT and V4 hook fee splits.

// Production default: 2027-03-01 00:00:00 UTC. Overridable at Pxt deploy for local testing.
uint256 constant DEFAULT_SELL_UNLOCK_TIMESTAMP = 1_803_744_000;

enum FeeKind {
    None,
    Buy,
    Sell,
    Transfer,
    Penalty
}

struct FeeBreakdown {
    FeeKind kind;
    uint256 feeBps;
    uint256 donation;
    uint256 marketing;
    uint256 burnAmount;
    uint256 buyback;
    uint256 totalFee;
    uint256 net;
}

error SellsLocked();
error AntiBotSellBlocked();
error ZeroAddress();

abstract contract PxtFeeEvents {
    event FeeCharged(address indexed from, address indexed to, FeeKind kind, uint256 feeBps, uint256 feeAmount);
}

library PxtFeeModel {
    uint256 internal constant BPS = 10_000;

    uint256 internal constant BUY_FEE_BPS = 270;
    uint256 internal constant TRANSFER_FEE_BPS = 270;
    uint256 internal constant SELL_FEE_BPS = 540;
    uint256 internal constant PENALTY_FEE_BPS = 3_780;

    uint256 internal constant BUY_DONATION_BPS = 145;

    uint256 internal constant SELL_DONATION_BPS = 125;
    uint256 internal constant SELL_MARKETING_BPS = 115;
    uint256 internal constant SELL_BURN_BPS = 185;
    uint256 internal constant SELL_BUYBACK_BPS = 115;
    /// @dev USDC skim legs only (burn is taken from PXT). Equals donation+marketing+buyback.
    uint256 internal constant SELL_USDC_FEE_BPS = SELL_DONATION_BPS + SELL_MARKETING_BPS + SELL_BUYBACK_BPS;

    uint256 internal constant PENALTY_DONATION_BPS = 125;
    uint256 internal constant PENALTY_MARKETING_BPS = 115;
    uint256 internal constant PENALTY_BURN_BPS = 185;
    uint256 internal constant PENALTY_BUYBACK_BPS = 3_355;
    /// @dev USDC skim legs only (burn is taken from PXT). Equals donation+marketing+buyback.
    uint256 internal constant PENALTY_USDC_FEE_BPS = PENALTY_DONATION_BPS + PENALTY_MARKETING_BPS + PENALTY_BUYBACK_BPS;

    uint256 internal constant PENALTY_THRESHOLD_BPS = 1_000;
    uint256 internal constant PENALTY_WINDOW = 24 hours;

    function noFee(uint256 amount) internal pure returns (FeeBreakdown memory) {
        return FeeBreakdown({
            kind: FeeKind.None,
            feeBps: 0,
            donation: 0,
            marketing: 0,
            burnAmount: 0,
            buyback: 0,
            totalFee: 0,
            net: amount
        });
    }

    /// @notice Buy (hook, USDC input) and transfer (PXT) share the same 1.45% / 1.25% split.
    /// @dev Marketing is the remainder so donation + marketing == amount * BUY_FEE_BPS / BPS.
    function splitBuy(uint256 amount) internal pure returns (uint256 donation, uint256 marketing) {
        uint256 total = (amount * BUY_FEE_BPS) / BPS;
        donation = (amount * BUY_DONATION_BPS) / BPS;
        marketing = total - donation;
    }

    /// @notice PXT burned on sell/penalty (1.85% of PXT sold).
    function splitSellBurn(uint256 feeBps, uint256 pxtAmount) internal pure returns (uint256 burnAmount) {
        if (feeBps == 0 || pxtAmount == 0) return 0;
        uint256 burnBps = feeBps == PENALTY_FEE_BPS ? PENALTY_BURN_BPS : SELL_BURN_BPS;
        return (pxtAmount * burnBps) / BPS;
    }

    /// @notice USDC skimmed from sell output: donation + marketing + buyback.
    /// @dev Buyback is the remainder so legs sum to amount * {SELL,PENALTY}_USDC_FEE_BPS / BPS.
    function splitSellUsdc(uint256 feeBps, uint256 usdcAmount)
        internal
        pure
        returns (uint256 donation, uint256 marketing, uint256 buyback)
    {
        if (feeBps == 0 || usdcAmount == 0) return (0, 0, 0);

        if (feeBps == PENALTY_FEE_BPS) {
            uint256 total = (usdcAmount * PENALTY_USDC_FEE_BPS) / BPS;
            donation = (usdcAmount * PENALTY_DONATION_BPS) / BPS;
            marketing = (usdcAmount * PENALTY_MARKETING_BPS) / BPS;
            buyback = total - donation - marketing;
        } else {
            uint256 total = (usdcAmount * SELL_USDC_FEE_BPS) / BPS;
            donation = (usdcAmount * SELL_DONATION_BPS) / BPS;
            marketing = (usdcAmount * SELL_MARKETING_BPS) / BPS;
            buyback = total - donation - marketing;
        }
    }
}
