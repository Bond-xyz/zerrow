// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

library LendingManagerTypes {
    struct LicensedAsset {
        address assetAddr;
        uint maximumLTV;
        uint liquidationPenalty;
        uint bestLendingRatio;
        uint bestDepositInterestRate;
        uint maxLendingAmountInRIM;
        uint reserveFactor;
        uint8 lendingModeNum;
        uint homogeneousModeLTV;
    }

    struct AssetInfo {
        uint latestDepositCoinValue;
        uint latestLendingCoinValue;
        uint latestDepositInterest;
        uint latestLendingInterest;
        uint latestTimeStamp;
    }
}
