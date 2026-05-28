// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

import "./interfaces/iDepositOrLoanCoin.sol";
import "./LendingManagerTypes.sol";

library LendingManagerRIMLib {
    error WrongRIMToken();
    error WrongHomogeneousMode();
    error RIMBorrowLimitExceeded();

    function decrementDebt(
        mapping(address => address[2]) storage assetsDepositAndLend,
        mapping(address => mapping(address => uint)) storage userRIMAssetsLendingNetAmount,
        mapping(address => uint) storage riskIsolationModeLendingNetAmount,
        mapping(address => address) storage userRIMAssetsAddress,
        mapping(address => uint8) storage userMode,
        address riskIsolationModeAcceptAssets,
        address user,
        address token
    ) public {
        if (userMode[user] != 1 || token != riskIsolationModeAcceptAssets) {
            return;
        }
        address rimAsset = userRIMAssetsAddress[user];
        address loanCoin = assetsDepositAndLend[riskIsolationModeAcceptAssets][1];

        uint currentShares = iDepositOrLoanCoin(loanCoin).userOQCAmount(user);
        uint oldShares = userRIMAssetsLendingNetAmount[user][token];
        uint delta = oldShares > currentShares ? oldShares - currentShares : 0;

        userRIMAssetsLendingNetAmount[user][token] = currentShares;
        if (riskIsolationModeLendingNetAmount[rimAsset] >= delta) {
            riskIsolationModeLendingNetAmount[rimAsset] -= delta;
        } else {
            riskIsolationModeLendingNetAmount[rimAsset] = 0;
        }
    }

    function updateBorrow(
        mapping(address => LendingManagerTypes.LicensedAsset) storage licensedAssets,
        mapping(address => address[2]) storage assetsDepositAndLend,
        mapping(address => mapping(address => uint)) storage userRIMAssetsLendingNetAmount,
        mapping(address => uint) storage riskIsolationModeLendingNetAmount,
        mapping(address => address) storage userRIMAssetsAddress,
        address riskIsolationModeAcceptAssets,
        address user,
        address tokenAddr,
        uint amountNormalize,
        uint coinValue
    ) public {
        address rimAsset = userRIMAssetsAddress[user];
        uint maxRIM = licensedAssets[rimAsset].maxLendingAmountInRIM;
        if (tokenAddr != riskIsolationModeAcceptAssets) revert WrongRIMToken();

        address loanCoin = assetsDepositAndLend[riskIsolationModeAcceptAssets][1];
        uint currentShares = iDepositOrLoanCoin(loanCoin).userOQCAmount(user);
        uint sharesDelta = amountNormalize * 1 ether / coinValue;
        uint newShares = currentShares + sharesDelta;

        riskIsolationModeLendingNetAmount[rimAsset] = riskIsolationModeLendingNetAmount[rimAsset]
                                                     - userRIMAssetsLendingNetAmount[user][tokenAddr]
                                                     + newShares;
        userRIMAssetsLendingNetAmount[user][tokenAddr] = newShares;

        if (riskIsolationModeLendingNetAmount[rimAsset] * coinValue / 1 ether > maxRIM) revert RIMBorrowLimitExceeded();
    }

    function updateRepayment(
        mapping(address => LendingManagerTypes.LicensedAsset) storage licensedAssets,
        mapping(address => address[2]) storage assetsDepositAndLend,
        mapping(address => mapping(address => uint)) storage userRIMAssetsLendingNetAmount,
        mapping(address => uint) storage riskIsolationModeLendingNetAmount,
        mapping(address => address) storage userRIMAssetsAddress,
        address riskIsolationModeAcceptAssets,
        address user,
        address tokenAddr,
        uint amountNormalize,
        uint coinValue
    ) public {
        address rimAsset = userRIMAssetsAddress[user];
        if (licensedAssets[rimAsset].maxLendingAmountInRIM == 0) revert WrongRIMToken();
        if (tokenAddr != riskIsolationModeAcceptAssets) revert WrongRIMToken();

        address loanCoin = assetsDepositAndLend[riskIsolationModeAcceptAssets][1];
        uint currentShares = iDepositOrLoanCoin(loanCoin).userOQCAmount(user);
        uint sharesDelta = amountNormalize * 1 ether / coinValue;
        uint newShares = currentShares - sharesDelta;

        riskIsolationModeLendingNetAmount[rimAsset] = riskIsolationModeLendingNetAmount[rimAsset]
                                                     - userRIMAssetsLendingNetAmount[user][tokenAddr]
                                                     + newShares;
        userRIMAssetsLendingNetAmount[user][tokenAddr] = newShares;
    }

    function checkDepositMode(
        mapping(address => LendingManagerTypes.LicensedAsset) storage licensedAssets,
        address tokenAddr,
        uint8 mode,
        address userRIMAsset
    ) public view {
        if (mode == 0) {
            if (licensedAssets[tokenAddr].maxLendingAmountInRIM != 0) revert WrongRIMToken();
        } else if (mode == 1) {
            if (tokenAddr != userRIMAsset) revert WrongRIMToken();
        } else {
            if (licensedAssets[tokenAddr].lendingModeNum != mode) revert WrongHomogeneousMode();
        }
    }
}
