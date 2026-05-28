// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

import "./LendingManagerLib.sol";
import "./LendingManagerSnapshotLib.sol";
import "./LendingManagerTypes.sol";

library LendingManagerModeLib {
    error WrongRIMToken();
    error Mode1NeedsRIMAsset();
    error RIMAssetOnlyInMode1();
    error UnknownMode();
    error PositionsNotCleared();

    event UserModeSetting(address indexed user, uint8 _mode, address _userRIMAssetsAddress);

    function userModeSetting(
        mapping(address => LendingManagerTypes.LicensedAsset) storage licensedAssets,
        mapping(address => address[2]) storage assetsDepositAndLend,
        address[] storage assetsSerialNumber,
        mapping(address => uint8) storage userMode,
        mapping(address => address) storage userRIMAssetsAddress,
        address oracleAddr,
        uint8 mode,
        address userRIMAsset,
        address user
    ) public {
        LendingManagerLib.AssetSnapshot[] memory snapshots = LendingManagerSnapshotLib.loadAssetSnapshots(
            licensedAssets,
            assetsDepositAndLend,
            assetsSerialNumber
        );
        if (LendingManagerLib.totalLendingValue(snapshots, user, oracleAddr) != 0
            || LendingManagerLib.totalDepositValue(snapshots, user, oracleAddr) != 0) revert PositionsNotCleared();
        if (mode > 1 && !LendingManagerLib.modeIsRegistered(snapshots, mode)) revert UnknownMode();

        if (mode == 1) {
            if (licensedAssets[userRIMAsset].maxLendingAmountInRIM == 0) revert Mode1NeedsRIMAsset();
        } else {
            if (userRIMAsset != address(0)) revert RIMAssetOnlyInMode1();
        }

        userMode[user] = mode;
        userRIMAssetsAddress[user] = userRIMAsset;
        emit UserModeSetting(user, mode, userRIMAsset);
    }
}
