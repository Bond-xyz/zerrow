// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/islcoracle.sol";
import "./interfaces/iDepositOrLoanCoin.sol";
import "./interfaces/iDecimals.sol";

library LendingManagerLib {
    uint internal constant UPPER_SYSTEM_LIMIT = 10000;
    uint internal constant LIQUIDATION_CLOSE_FACTOR = 5000;
    uint internal constant ONE_YEAR = 31536000;

    struct AssetSnapshot {
        address asset;
        address depositCoin;
        address loanCoin;
        uint maximumLTV;
        uint homogeneousModeLTV;
        uint liquidationPenalty;
        uint maxLendingAmountInRIM;
        uint8 lendingModeNum;
    }

    function totalLendingValue(
        AssetSnapshot[] memory s,
        address user,
        address oracle
    ) external view returns (uint values) {
        for (uint i = 0; i < s.length; i++) {
            uint loanBal = IERC20(s[i].loanCoin).balanceOf(user);
            if (loanBal == 0) continue;
            values += loanBal * iSlcOracle(oracle).getPrice(s[i].asset) / 1 ether;
        }
    }

    function totalDepositValue(
        AssetSnapshot[] memory s,
        address user,
        address oracle
    ) external view returns (uint values) {
        for (uint i = 0; i < s.length; i++) {
            uint depositBal = IERC20(s[i].depositCoin).balanceOf(user);
            if (depositBal == 0) continue;
            values += depositBal * iSlcOracle(oracle).getPrice(s[i].asset) / 1 ether;
        }
    }

    function depositAndLendingValue(
        AssetSnapshot[] memory s,
        address user,
        uint8 mode,
        address oracle
    ) external view returns (uint _amountDeposit, uint _amountLending) {
        uint tempgetprice;
        for (uint i = 0; i < s.length; i++) {
            uint depositBal = iDepositOrLoanCoin(s[i].depositCoin).balanceOf(user);
            uint loanBal = iDepositOrLoanCoin(s[i].loanCoin).balanceOf(user);
            if (depositBal == 0 && loanBal == 0) continue;
            tempgetprice = iSlcOracle(oracle).getPrice(s[i].asset);
            if (mode > 1) {
                _amountDeposit += depositBal
                    * tempgetprice / 1 ether
                    * s[i].homogeneousModeLTV / UPPER_SYSTEM_LIMIT;
            } else {
                _amountDeposit += depositBal
                    * tempgetprice / 1 ether
                    * s[i].maximumLTV / UPPER_SYSTEM_LIMIT;
            }
            _amountLending += loanBal * tempgetprice / 1 ether;
        }
    }

    function healthFactor(
        AssetSnapshot[] memory s,
        address user,
        uint8 mode,
        address oracle
    ) external view returns (uint userHealthFactor) {
        uint _amountDeposit;
        uint _amountLending;
        uint tempgetprice;
        for (uint i = 0; i < s.length; i++) {
            uint depositBal = iDepositOrLoanCoin(s[i].depositCoin).balanceOf(user);
            uint loanBal = iDepositOrLoanCoin(s[i].loanCoin).balanceOf(user);
            if (depositBal == 0 && loanBal == 0) continue;
            tempgetprice = iSlcOracle(oracle).getPrice(s[i].asset);
            if (mode > 1) {
                _amountDeposit += depositBal
                    * tempgetprice / 1 ether
                    * s[i].homogeneousModeLTV / UPPER_SYSTEM_LIMIT;
            } else {
                _amountDeposit += depositBal
                    * tempgetprice / 1 ether
                    * s[i].maximumLTV / UPPER_SYSTEM_LIMIT;
            }
            _amountLending += loanBal * tempgetprice / 1 ether;
        }
        if (_amountLending > 0) {
            userHealthFactor = _amountDeposit * 1 ether / _amountLending;
        } else if (_amountDeposit >= 0) {
            userHealthFactor = 1000 ether;
        } else {
            userHealthFactor = 0 ether;
        }
    }

    function assetOverview(
        AssetSnapshot[] memory s,
        address user
    ) external view returns (
        address[] memory tokens,
        uint[] memory _amountDeposit,
        uint[] memory _amountLending
    ) {
        uint len = s.length;
        tokens = new address[](len);
        _amountDeposit = new uint[](len);
        _amountLending = new uint[](len);
        for (uint i = 0; i < len; i++) {
            tokens[i] = s[i].asset;
            _amountDeposit[i] = iDepositOrLoanCoin(s[i].depositCoin).balanceOf(user);
            _amountLending[i] = iDepositOrLoanCoin(s[i].loanCoin).balanceOf(user);
        }
    }

    function coinValues(
        uint latestDepositCoinValue,
        uint latestLendingCoinValue,
        uint latestDepositInterest,
        uint latestLendingInterest,
        uint latestTimeStamp
    ) external view returns (uint[2] memory currentValue) {
        uint tempVaule = (block.timestamp - latestTimeStamp) * 1 ether / (ONE_YEAR * UPPER_SYSTEM_LIMIT);
        currentValue[0] = latestDepositCoinValue + tempVaule * latestDepositInterest;
        currentValue[1] = latestLendingCoinValue + tempVaule * latestLendingInterest;
        if (currentValue[0] == 0) {
            currentValue[0] = 1 ether;
        }
        if (currentValue[1] == 0) {
            currentValue[1] = 1 ether;
        }
    }

    function modeIsRegistered(
        AssetSnapshot[] memory s,
        uint8 mode
    ) external pure returns (bool registered) {
        for (uint i = 0; i < s.length; i++) {
            if (s[i].lendingModeNum == mode) {
                return true;
            }
        }
    }

    struct LiquidationParams {
        address user;
        address liquidateToken;
        uint liquidateAmountNormalize;
        address depositToken;
        address liquidateLoanCoin;
        address depositDepositCoin;
        uint liquidationPenalty;
        address oracle;
        uint currentHF;
    }

    function previewLiquidation(
        LiquidationParams memory p
    ) external view returns (uint healthFactorBefore, uint seizedCollateralNormalize) {
        healthFactorBefore = p.currentHF;
        require(healthFactorBefore < 1 ether, "Lending Manager: Users Health Factor Need < 1 ether");

        uint amountLending = iDepositOrLoanCoin(p.liquidateLoanCoin).balanceOf(p.user);
        uint amountDeposit = iDepositOrLoanCoin(p.depositDepositCoin).balanceOf(p.user);
        require(amountLending > 0, "Lending Manager: No debt to liquidate");
        require(amountDeposit > 0, "Lending Manager: No collateral to seize");

        uint maxCloseAmount = amountLending * LIQUIDATION_CLOSE_FACTOR / UPPER_SYSTEM_LIMIT;
        if (maxCloseAmount == 0) {
            maxCloseAmount = amountLending;
        }
        require(p.liquidateAmountNormalize <= amountLending, "Lending Manager: Repay exceeds user debt");
        require(p.liquidateAmountNormalize <= maxCloseAmount, "Lending Manager: Repay exceeds close factor");

        uint debtPrice = iSlcOracle(p.oracle).getPrice(p.liquidateToken);
        uint collateralPrice = iSlcOracle(p.oracle).getPrice(p.depositToken);

        uint maxRepayByCollateral = amountDeposit * collateralPrice / 1 ether;
        maxRepayByCollateral = maxRepayByCollateral * UPPER_SYSTEM_LIMIT / (UPPER_SYSTEM_LIMIT + p.liquidationPenalty);
        maxRepayByCollateral = maxRepayByCollateral * 1 ether / debtPrice;
        require(maxRepayByCollateral > 0, "Lending Manager: Collateral exhausted");
        require(p.liquidateAmountNormalize <= maxRepayByCollateral, "Lending Manager: Repay exceeds collateral support");

        seizedCollateralNormalize = p.liquidateAmountNormalize
            * debtPrice
            * (UPPER_SYSTEM_LIMIT + p.liquidationPenalty)
            / (UPPER_SYSTEM_LIMIT * collateralPrice);
        require(amountDeposit >= seizedCollateralNormalize, "Lending Manager: Collateral amount NOT enough");
    }

    function requireHealthy(
        uint factor,
        uint8 mode,
        uint normalFloor,
        uint homoFloor
    ) external pure {
        if (mode > 1) {
            require(factor >= homoFloor, "Your Health Factor <= homogeneous Floor Of Health Factor, Cant redeem assets");
        } else {
            require(factor >= normalFloor, "Your Health Factor <= normal Floor Of Health Factor, Cant redeem assets");
        }
    }

    function validateAssetParams(
        uint _maxLTV,
        uint _liqPenalty,
        uint _bestLendingRatio,
        uint _homogeneousModeLTV,
        uint _bestDepositInterestRate,
        uint _reserveFactor
    ) external pure {
        require(
            _maxLTV <= 9500
            && _liqPenalty >= 100
            && _liqPenalty <= UPPER_SYSTEM_LIMIT / 5
            && _bestLendingRatio > 0
            && _bestLendingRatio <= 9000
            && _homogeneousModeLTV < UPPER_SYSTEM_LIMIT
            && _bestDepositInterestRate > 0
            && _bestDepositInterestRate <= 1000
            && _reserveFactor > 0
            && _reserveFactor <= UPPER_SYSTEM_LIMIT,
            "Lending Manager: Exceed UPPER_SYSTEM_LIMIT"
        );
    }

    error InsufficientFunds();
    error VaultInsufficient();

    function computeFlashLoanFee(
        uint borrowAmountNormalize,
        uint depositBalance,
        uint useTokenPrice,
        uint borrowTokenPrice,
        uint vaultAmount
    ) external pure returns (uint userNeedPaid) {
        uint userMaxPaid = depositBalance * useTokenPrice;
        userNeedPaid = borrowAmountNormalize * borrowTokenPrice / 100;
        if (userMaxPaid <= userNeedPaid) revert InsufficientFunds();
        userNeedPaid = userNeedPaid / useTokenPrice;
        if (vaultAmount <= userNeedPaid) revert VaultInsufficient();
    }

    function computeBadDebt(
        AssetSnapshot[] memory s,
        address user,
        address oracle
    ) external view returns (uint badDebtValue, uint[] memory burnAmounts) {
        uint depositValue;
        uint lendingValue;
        for (uint i = 0; i < s.length; i++) {
            uint price = iSlcOracle(oracle).getPrice(s[i].asset);
            depositValue += IERC20(s[i].depositCoin).balanceOf(user) * price / 1 ether;
            lendingValue += IERC20(s[i].loanCoin).balanceOf(user) * price / 1 ether;
        }

        burnAmounts = new uint[](s.length);
        if (depositValue != 0 || lendingValue == 0) {
            return (0, burnAmounts);
        }

        for (uint i = 0; i < s.length; i++) {
            uint bal = iDepositOrLoanCoin(s[i].loanCoin).balanceOf(user);
            if (bal > 0) {
                badDebtValue += bal * iSlcOracle(oracle).getPrice(s[i].asset) / 1 ether;
                burnAmounts[i] = bal;
            }
        }
    }
}
