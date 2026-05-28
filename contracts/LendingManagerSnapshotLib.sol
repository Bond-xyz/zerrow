// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

import "./LendingManagerLib.sol";
import "./LendingManagerTypes.sol";

library LendingManagerSnapshotLib {
    function loadAssetSnapshots(
        mapping(address => LendingManagerTypes.LicensedAsset) storage licensedAssets,
        mapping(address => address[2]) storage assetsDepositAndLend,
        address[] storage assetsSerialNumber
    ) public view returns (LendingManagerLib.AssetSnapshot[] memory snapshots) {
        uint assetLength = assetsSerialNumber.length;
        snapshots = new LendingManagerLib.AssetSnapshot[](assetLength);
        for (uint assetIndex = 0; assetIndex < assetLength; assetIndex++) {
            address asset = assetsSerialNumber[assetIndex];
            LendingManagerTypes.LicensedAsset storage licensedAsset = licensedAssets[asset];
            snapshots[assetIndex].asset = asset;
            snapshots[assetIndex].depositCoin = assetsDepositAndLend[asset][0];
            snapshots[assetIndex].loanCoin = assetsDepositAndLend[asset][1];
            snapshots[assetIndex].maximumLTV = licensedAsset.maximumLTV;
            snapshots[assetIndex].homogeneousModeLTV = licensedAsset.homogeneousModeLTV;
            snapshots[assetIndex].liquidationPenalty = licensedAsset.liquidationPenalty;
            snapshots[assetIndex].maxLendingAmountInRIM = licensedAsset.maxLendingAmountInRIM;
            snapshots[assetIndex].lendingModeNum = licensedAsset.lendingModeNum;
        }
    }
}
