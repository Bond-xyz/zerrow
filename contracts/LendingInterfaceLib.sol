// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/iLendingManager.sol";
import "./interfaces/islcoracle.sol";
import "./interfaces/iDepositOrLoanCoin.sol";
import "./interfaces/iLendingCoreAlgorithm.sol";
import "./interfaces/iDecimals.sol";

library LendingInterfaceLib {

    struct RiskCtx {
        address mgr;
        address oracle;
        uint8 mode;
        address userRIMSetAssets;
        uint normalFloor;
        uint homoFloor;
    }

    function computeUsersRiskDetails(
        address user,
        address mgr,
        address oracle
    ) external view returns (
        uint userValueUsedRatio,
        uint userMaxUsedRatio,
        uint tokenLiquidateRatio
    ) {
        RiskCtx memory ctx;
        ctx.mgr = mgr;
        ctx.oracle = oracle;
        ctx.mode = iLendingManager(mgr).userMode(user);
        ctx.userRIMSetAssets = iLendingManager(mgr).userRIMAssetsAddress(user);
        ctx.normalFloor = iLendingManager(mgr).normalFloorOfHealthFactor();
        ctx.homoFloor = iLendingManager(mgr).homogeneousFloorOfHealthFactor();

        uint assetLength = iLendingManager(mgr).licensedAssetAmount();
        uint[] memory assetPrice = new uint[](assetLength);
        for (uint i = 0; i < assetLength; i++) {
            assetPrice[i] = iSlcOracle(oracle).getPrice(iLendingManager(mgr).assetsSerialNumber(i));
        }

        address[] memory tokens;
        uint[] memory _amountDeposit;
        uint[] memory _amountLending;
        (tokens, _amountDeposit, _amountLending) = iLendingManager(mgr).userAssetOverview(user);

        if (ctx.mode == 1) {
            return _riskMode1(user, tokens, _amountDeposit, assetPrice, ctx);
        } else if (ctx.mode == 0) {
            return _riskMode0(tokens, _amountDeposit, _amountLending, assetPrice, ctx);
        } else {
            return _riskModeHomogeneous(tokens, _amountDeposit, _amountLending, assetPrice, ctx);
        }
    }

    function _riskMode1(
        address user,
        address[] memory tokens,
        uint[] memory _amountDeposit,
        uint[] memory assetPrice,
        RiskCtx memory ctx
    ) internal view returns (uint userValueUsedRatio, uint userMaxUsedRatio, uint tokenLiquidateRatio) {
        for (uint i = 0; i != tokens.length; i++) {
            if (tokens[i] == ctx.userRIMSetAssets && _amountDeposit[i] > 0) {
                uint rimAmount = iLendingManager(ctx.mgr).userRIMAssetsLendingNetAmount(user, ctx.userRIMSetAssets);
                userValueUsedRatio = (((rimAmount * 10000) / _amountDeposit[i]) * 1 ether) / assetPrice[i];
                iLendingManager.licensedAsset memory usefulAsset = iLendingManager(ctx.mgr).licensedAssets(tokens[i]);
                userMaxUsedRatio = (usefulAsset.maximumLTV * 1 ether) / ctx.normalFloor;
                tokenLiquidateRatio = usefulAsset.maximumLTV;
                break;
            }
        }
    }

    function _riskMode0(
        address[] memory tokens,
        uint[] memory _amountDeposit,
        uint[] memory _amountLending,
        uint[] memory assetPrice,
        RiskCtx memory ctx
    ) internal view returns (uint userValueUsedRatio, uint userMaxUsedRatio, uint tokenLiquidateRatio) {
        uint[3] memory t;
        for (uint i = 0; i != tokens.length; i++) {
            iLendingManager.licensedAsset memory a = iLendingManager(ctx.mgr).licensedAssets(tokens[i]);
            if (a.lendingModeNum != 1) {
                t[1] += (_amountDeposit[i] * assetPrice[i]) / 1 ether;
                t[2] += (_amountLending[i] * assetPrice[i]) / 1 ether;
                userMaxUsedRatio += (_amountDeposit[i] * assetPrice[i] * a.maximumLTV) / ctx.normalFloor / 10000;
                tokenLiquidateRatio += (((_amountDeposit[i] * assetPrice[i]) / 1 ether) * a.maximumLTV) / 10000;
            }
        }
        if (t[1] > 0) {
            userValueUsedRatio = (t[2] * 10000) / t[1];
            userMaxUsedRatio = (userMaxUsedRatio * 10000) / t[1];
            tokenLiquidateRatio = (tokenLiquidateRatio * 10000) / t[1];
        }
    }

    function _riskModeHomogeneous(
        address[] memory tokens,
        uint[] memory _amountDeposit,
        uint[] memory _amountLending,
        uint[] memory assetPrice,
        RiskCtx memory ctx
    ) internal view returns (uint userValueUsedRatio, uint userMaxUsedRatio, uint tokenLiquidateRatio) {
        uint[3] memory t;
        for (uint i = 0; i != tokens.length; i++) {
            iLendingManager.licensedAsset memory a = iLendingManager(ctx.mgr).licensedAssets(tokens[i]);
            if (a.lendingModeNum == ctx.mode) {
                t[1] += (_amountDeposit[i] * assetPrice[i]) / 1 ether;
                t[2] += (_amountLending[i] * assetPrice[i]) / 1 ether;
                userMaxUsedRatio += (_amountDeposit[i] * assetPrice[i] * a.maximumLTV) / ctx.homoFloor / 10000;
                tokenLiquidateRatio += (((_amountDeposit[i] * assetPrice[i]) / 1 ether) * a.maximumLTV) / 10000;
            }
        }
        if (t[1] > 0) {
            userValueUsedRatio = (t[2] * 10000) / t[1];
            userMaxUsedRatio = (userMaxUsedRatio * 10000) / t[1];
            tokenLiquidateRatio = (tokenLiquidateRatio * 10000) / t[1];
        }
    }

    function computeUserProfile(
        address user,
        address mgr,
        address oracle
    ) external view returns (int netWorth, int netApy) {
        uint[5] memory f;
        int fullWorth;

        uint assetLength = iLendingManager(mgr).licensedAssetAmount();
        uint[] memory assetPrice = new uint[](assetLength);
        for (uint i = 0; i < assetLength; i++) {
            assetPrice[i] = iSlcOracle(oracle).getPrice(iLendingManager(mgr).assetsSerialNumber(i));
        }

        address[] memory tokens;
        uint[] memory _amountDeposit;
        uint[] memory _amountLending;
        (tokens, _amountDeposit, _amountLending) = iLendingManager(mgr).userAssetOverview(user);
        for (uint i = 0; i != tokens.length; i++) {
            f[0] = f[0] + _amountDeposit[i];
            f[1] = f[1] + (_amountDeposit[i] * assetPrice[i]) / 1 ether;
            f[2] = f[2] + (_amountLending[i] * assetPrice[i]) / 1 ether;
            uint depositInterest;
            uint lendingInterest;
            (, , depositInterest, lendingInterest) = iLendingManager(mgr).assetsTimeDependentParameter(tokens[i]);
            f[3] = f[3] + (depositInterest * _amountDeposit[i] * assetPrice[i]) / 1 ether;
            f[4] = f[4] + (lendingInterest * _amountLending[i] * assetPrice[i]) / 1 ether;
        }
        netWorth = netWorth + int(f[1]) - int(f[2]);
        fullWorth = fullWorth + int(f[1]);
        if (f[0] == 0) {
            netApy = 0;
        } else {
            netApy = (int(f[3]) - int(f[4])) / fullWorth;
        }
    }

    struct EstimateCtx {
        address mgr;
        address oracle;
        address lCoreAddr;
        uint tokenPrice;
        uint modeLTV;
        uint8 userMode;
        uint upperLimit;
    }

    function computeHealthFactorEstimate(
        address user,
        address token,
        uint amount,
        uint operator,
        address mgr,
        address oracle,
        address lCoreAddr
    ) external view returns (
        uint userHealthFactor,
        uint[2] memory newInterest,
        uint _amountDeposit,
        uint _amountLending
    ) {
        EstimateCtx memory c;
        c.mgr = mgr;
        c.oracle = oracle;
        c.lCoreAddr = lCoreAddr;
        c.tokenPrice = iSlcOracle(oracle).getPrice(token);
        c.userMode = iLendingManager(mgr).userMode(user);
        c.upperLimit = iLendingManager(mgr).UPPER_SYSTEM_LIMIT();

        {
            iLendingManager.licensedAsset memory la = iLendingManager(mgr).licensedAssets(token);
            c.modeLTV = c.userMode > 1 ? la.homogeneousModeLTV : la.maximumLTV;
        }

        (_amountDeposit, _amountLending) = iLendingManager(mgr).userDepositAndLendingValue(user);
        {
            uint normalizedAmount = amount * 1 ether / (10 ** iDecimals(token).decimals());
            uint weightedDepositValue = normalizedAmount * c.tokenPrice / 1 ether * c.modeLTV / c.upperLimit;
            uint lendingValue = normalizedAmount * c.tokenPrice / 1 ether;
            if (operator == 0) {
                _amountDeposit += weightedDepositValue;
            } else if (operator == 1) {
                _amountDeposit -= weightedDepositValue;
            } else if (operator == 2) {
                _amountLending += lendingValue;
            } else if (operator == 3) {
                _amountLending -= lendingValue;
            }
        }
        if (_amountLending > 0) {
            userHealthFactor = (_amountDeposit * 1 ether) / _amountLending;
        } else if (_amountDeposit >= 0) {
            userHealthFactor = 1000 ether;
        } else {
            userHealthFactor = 0 ether;
        }
        if (userHealthFactor > 1000 ether) {
            userHealthFactor = 1000 ether;
        }

        address[2] memory depositAndLend = iLendingManager(mgr).assetsDepositAndLendAddrs(token);
        _amountDeposit = iDepositOrLoanCoin(depositAndLend[0]).totalSupply();
        _amountLending = iDepositOrLoanCoin(depositAndLend[1]).totalSupply();

        uint lendingRatio;
        if (_amountDeposit > 0) {
            if (operator == 0) {
                _amountDeposit += amount * c.modeLTV / c.upperLimit;
            } else if (operator == 1) {
                uint adj = amount * c.modeLTV / c.upperLimit;
                _amountDeposit = _amountDeposit > adj ? _amountDeposit - adj : 0;
            } else if (operator == 2) {
                _amountLending += amount;
            } else if (operator == 3) {
                _amountLending = _amountLending > amount ? _amountLending - amount : 0;
            }
            if (_amountDeposit > 0) {
                lendingRatio = (_amountLending * c.upperLimit) / _amountDeposit;
            }
        }

        if (lendingRatio > c.upperLimit) {
            lendingRatio = c.upperLimit;
        }
        newInterest[0] = iLendingCoreAlgorithm(c.lCoreAddr).depositInterestRate(token, lendingRatio);
        uint reserveFactor = iLendingManager(mgr).assetsReserveFactor(token);
        newInterest[1] = iLendingCoreAlgorithm(c.lCoreAddr).lendingInterestRate(token, lendingRatio, reserveFactor);
    }

    function computeGeneralParameters(
        address mgr,
        address oracle
    ) external view returns (
        address[] memory tokens,
        uint[] memory totalSupplied,
        uint[] memory totalBorrowed,
        uint[] memory supplyApy,
        uint[] memory borrowApy,
        uint[] memory assetsPrice,
        uint8[] memory tokenMode
    ) {
        (tokens, , ) = iLendingManager(mgr).userAssetOverview(address(0));
        totalSupplied = new uint[](tokens.length);
        totalBorrowed = new uint[](tokens.length);
        supplyApy = new uint[](tokens.length);
        borrowApy = new uint[](tokens.length);
        uint assetLength = iLendingManager(mgr).licensedAssetAmount();
        assetsPrice = new uint[](assetLength);
        for (uint i = 0; i < assetLength; i++) {
            assetsPrice[i] = iSlcOracle(oracle).getPrice(iLendingManager(mgr).assetsSerialNumber(i));
        }
        tokenMode = new uint8[](tokens.length);

        for (uint i = 0; i != tokens.length; i++) {
            (, , supplyApy[i], borrowApy[i]) = iLendingManager(mgr).assetsTimeDependentParameter(tokens[i]);
            iLendingManager.licensedAsset memory usefulAsset = iLendingManager(mgr).licensedAssets(tokens[i]);
            tokenMode[i] = usefulAsset.lendingModeNum;
            address[2] memory depositAndLend = iLendingManager(mgr).assetsDepositAndLendAddrs(tokens[i]);
            totalSupplied[i] = IERC20(depositAndLend[0]).totalSupply();
            totalBorrowed[i] = IERC20(depositAndLend[1]).totalSupply();
        }
    }
}
