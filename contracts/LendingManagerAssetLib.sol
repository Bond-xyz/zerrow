// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/iCoinFactory.sol";
import "./LendingManagerLib.sol";
import "./LendingManagerTypes.sol";

library LendingManagerAssetLib {
    struct AssetParams {
        uint maxLTV;
        uint liqPenalty;
        uint maxLendingAmountInRIM;
        uint bestLendingRatio;
        uint reserveFactor;
        uint8 lendingModeNum;
        uint homogeneousModeLTV;
        uint bestDepositInterestRate;
    }

    error AssetAlreadyRegistered();
    error AssetNotRegistered();
    error TooManyAssets();
    error OutstandingPositions();

    event LicensedAssetsSetup(
        address indexed _asset,
        uint _maxLTV,
        uint _liqPenalty,
        uint _maxLendingAmountInRIM,
        uint _bestLendingRatio,
        uint reserveFactor,
        uint8 _lendingModeNum,
        uint _homogeneousModeLTV,
        uint _bestDepositInterestRate
    );
    event LicensedAssetsDeregistered(address indexed _asset);

    function deregister(
        mapping(address => LendingManagerTypes.LicensedAsset) storage licensedAssets,
        mapping(address => address[2]) storage assetsDepositAndLend,
        mapping(address => LendingManagerTypes.AssetInfo) storage assetInfos,
        address[] storage assetsSerialNumber,
        address asset
    ) public {
        if (licensedAssets[asset].assetAddr != asset) revert AssetNotRegistered();
        if (IERC20(assetsDepositAndLend[asset][0]).totalSupply() != 0
            || IERC20(assetsDepositAndLend[asset][1]).totalSupply() != 0) revert OutstandingPositions();

        delete licensedAssets[asset];
        delete assetsDepositAndLend[asset];
        delete assetInfos[asset];

        for (uint assetIndex = 0; assetIndex < assetsSerialNumber.length; assetIndex++) {
            if (assetsSerialNumber[assetIndex] == asset) {
                assetsSerialNumber[assetIndex] = assetsSerialNumber[assetsSerialNumber.length - 1];
                assetsSerialNumber.pop();
                break;
            }
        }
        emit LicensedAssetsDeregistered(asset);
    }

    function registerFromCalldata(
        mapping(address => LendingManagerTypes.LicensedAsset) storage licensedAssets,
        mapping(address => address[2]) storage assetsDepositAndLend,
        address[] storage assetsSerialNumber,
        address coinFactory,
        bytes calldata callData
    ) public {
        (address asset, AssetParams memory params, bool isNew) = _decodeRegisterCalldata(callData);
        LendingManagerLib.validateAssetParams(
            params.maxLTV,
            params.liqPenalty,
            params.bestLendingRatio,
            params.homogeneousModeLTV,
            params.bestDepositInterestRate,
            params.reserveFactor
        );
        if (licensedAssets[asset].assetAddr != address(0)) revert AssetAlreadyRegistered();
        if (assetsSerialNumber.length >= 49) revert TooManyAssets();

        assetsSerialNumber.push(asset);
        _setAssetParams(licensedAssets, asset, params);

        if (isNew) {
            assetsDepositAndLend[asset] = iCoinFactory(coinFactory).createDeAndLoCoin(asset);
        } else {
            address depositCoin = iCoinFactory(coinFactory).getDepositCoin(asset);
            address loanCoin = iCoinFactory(coinFactory).getLoanCoin(asset);
            require(depositCoin != address(0), "Lending Manager: deposit coin not found");
            require(loanCoin != address(0), "Lending Manager: loan coin not found");
            assetsDepositAndLend[asset][0] = depositCoin;
            assetsDepositAndLend[asset][1] = loanCoin;
        }
    }

    function resetFromCalldata(
        mapping(address => LendingManagerTypes.LicensedAsset) storage licensedAssets,
        bytes calldata callData
    ) public {
        (address asset, AssetParams memory params) = _decodeAssetParams(callData);
        if (licensedAssets[asset].assetAddr != asset) revert AssetNotRegistered();
        LendingManagerLib.validateAssetParams(
            params.maxLTV,
            params.liqPenalty,
            params.bestLendingRatio,
            params.homogeneousModeLTV,
            params.bestDepositInterestRate,
            params.reserveFactor
        );
        _setAssetParams(licensedAssets, asset, params);
    }

    function _decodeRegisterCalldata(
        bytes calldata callData
    ) private pure returns (address asset, AssetParams memory params, bool isNew) {
        (asset, params) = _decodeAssetParams(callData);
        assembly {
            isNew := calldataload(add(callData.offset, 292))
        }
    }

    function _decodeAssetParams(
        bytes calldata callData
    ) private pure returns (address asset, AssetParams memory params) {
        assembly {
            asset := calldataload(add(callData.offset, 4))
            params := mload(0x40)
            mstore(0x40, add(params, 0x100))
            mstore(params, calldataload(add(callData.offset, 36)))
            mstore(add(params, 32), calldataload(add(callData.offset, 68)))
            mstore(add(params, 64), calldataload(add(callData.offset, 100)))
            mstore(add(params, 96), calldataload(add(callData.offset, 132)))
            mstore(add(params, 128), calldataload(add(callData.offset, 164)))
            mstore(add(params, 160), calldataload(add(callData.offset, 196)))
            mstore(add(params, 192), calldataload(add(callData.offset, 228)))
            mstore(add(params, 224), calldataload(add(callData.offset, 260)))
        }
    }

    function _setAssetParams(
        mapping(address => LendingManagerTypes.LicensedAsset) storage licensedAssets,
        address asset,
        AssetParams memory params
    ) private {
        LendingManagerTypes.LicensedAsset storage licensedAsset = licensedAssets[asset];
        licensedAsset.assetAddr = asset;
        licensedAsset.maximumLTV = params.maxLTV;
        licensedAsset.liquidationPenalty = params.liqPenalty;
        licensedAsset.maxLendingAmountInRIM = params.maxLendingAmountInRIM;
        licensedAsset.bestLendingRatio = params.bestLendingRatio;
        licensedAsset.lendingModeNum = params.lendingModeNum;
        licensedAsset.homogeneousModeLTV = params.homogeneousModeLTV;
        licensedAsset.bestDepositInterestRate = params.bestDepositInterestRate;
        licensedAsset.reserveFactor = params.reserveFactor;

        emit LicensedAssetsSetup(
            asset,
            params.maxLTV,
            params.liqPenalty,
            params.maxLendingAmountInRIM,
            params.bestLendingRatio,
            params.reserveFactor,
            params.lendingModeNum,
            params.homogeneousModeLTV,
            params.bestDepositInterestRate
        );
    }
}
