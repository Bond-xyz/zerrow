// SPDX-License-Identifier: Business Source License 1.1
// First Release Time : 2025.03.30

pragma solidity 0.8.6;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/iLendingManager.sol";
import "./interfaces/iw0G.sol";
import "./interfaces/islcoracle.sol";
import "./interfaces/iDepositOrLoanCoin.sol";
import "./interfaces/iLendingCoreAlgorithm.sol";
import "./interfaces/iLstGimo.sol";
import "./interfaces/iDecimals.sol";

/// @custom:oz-upgrades-unsafe-allow constructor
contract lstInterface is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    address public lendingManager;
    address public W0G;
    address public oracleAddr;
    address public lCoreAddr;
    address public lstGimo;
    address public gToken;

    /// @notice Admin address for upgrade authorization
    address public admin;
    address public pendingAdmin;

    using SafeERC20 for IERC20;

    /// @dev Storage gap for future upgrades
    uint256[49] private __gap;

    /// @dev Disable initializer on implementation contract
    constructor() initializer {}

    /// @notice Replaces constructor for proxy deployment
    function initialize(
        address _lendingManager,
        address _W0G,
        address _lCoreAddr,
        address _oracleAddr,
        address _lstGimo,
        address _gToken
    ) public initializer {
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        lendingManager = _lendingManager;
        W0G = _W0G;
        oracleAddr = _oracleAddr;
        lCoreAddr = _lCoreAddr;
        lstGimo = _lstGimo;
        gToken = _gToken;
        admin = msg.sender;
    }

    /// @dev Required by UUPSUpgradeable
    function _authorizeUpgrade(address) internal override {
        require(msg.sender == admin, "not admin");
    }

    function transferAdmin(address _admin) external {
        require(msg.sender == admin, "not admin");
        require(_admin != address(0), "LST Interface: New admin cannot be zero");
        require(_admin != admin, "LST Interface: Cannot transfer to current admin");
        pendingAdmin = _admin;
    }

    function acceptAdmin(bool _TorF) external {
        require(msg.sender == pendingAdmin, "LST Interface: Permission FORBIDDEN");
        if (_TorF) {
            admin = pendingAdmin;
        }
        pendingAdmin = address(0);
    }

    //------------------------------------------------ View ----------------------------------------------------
    function licensedAssets(
        address token
    ) public view returns (iLendingManager.licensedAsset memory) {
        return iLendingManager(lendingManager).licensedAssets(token);
    }

    function viewUsersHealthFactor(
        address user
    ) public view returns (uint userHealthFactor) {
        return iLendingManager(lendingManager).viewUsersHealthFactor(user);
    }

    function assetsDepositAndLendAddrs(
        address token
    ) public view returns (address[2] memory depositAndLend) {
        return iLendingManager(lendingManager).assetsDepositAndLendAddrs(token);
    }
    function assetsDepositAndLendAmount(
        address token
    ) public view returns (uint[2] memory depositAndLendAmount) {
        address[2] memory depositAndLend = iLendingManager(lendingManager)
            .assetsDepositAndLendAddrs(token);
        depositAndLendAmount[0] = IERC20(depositAndLend[0]).totalSupply();
        depositAndLendAmount[1] = IERC20(depositAndLend[1]).totalSupply();
    }
    function lendAvailableAmount(address tokenWant)
        public
        view
        returns (uint availableAmount)
    {
        availableAmount = iLendingManager(lendingManager).VaultTokensAmount(
            tokenWant
        );
    }

    function lendAvailableAmount()
        public
        view
        returns (uint[] memory availableAmount)
    {
        uint[] memory assetPrice = licensedAssetPrice();
        uint assetLength = assetPrice.length;
        availableAmount = new uint[](assetLength);
        for (uint i = 0; i != assetLength; i++) {
            availableAmount[i] = iLendingManager(lendingManager)
                .VaultTokensAmount(assetsSerialNumber(i));
        }
    }

    function assetsReserveFactor(address token) public view returns(uint reserveFactor){
        return iLendingManager(lendingManager).assetsReserveFactor(token);
    }

    function assetsBaseInfo(
        address token
    )
        public
        view
        returns (
            uint maximumLTV,
            uint liquidationPenalty,
            uint maxLendingAmountInRIM,
            uint bestLendingRatio,
            uint lendingModeNum,
            uint homogeneousModeLTV,
            uint bestDepositInterestRate
        )
    {
        return iLendingManager(lendingManager).assetsBaseInfo(token);
    }

    function assetsTimeDependentParameter(
        address token
    )
        public
        view
        returns (
            uint latestDepositCoinValue,
            uint latestLendingCoinValue,
            uint latestDepositInterest,
            uint latestLendingInterest
        )
    {
        return
            iLendingManager(lendingManager).assetsTimeDependentParameter(token);
    }

    function licensedAssetPrice() public view returns(uint[] memory assetPrice){
        uint assetLength = iLendingManager(lendingManager).licensedAssetAmount();
        assetPrice = new uint[](assetLength);
        for(uint i=0;i!=assetLength;i++){
            assetPrice[i] = iSlcOracle(oracleAddr).getPrice(assetsSerialNumber(i));
        }
    }

    function licensedAssetOverview() public view returns(uint totalValueOfMortgagedAssets, uint totalValueOfLendedAssets){
        uint assetLength = iLendingManager(lendingManager).licensedAssetAmount();
        address[2] memory addrs;
        address addrA;
        uint tempPrice;
        for(uint i=0;i!=assetLength;i++){
            addrA = iLendingManager(lendingManager).assetsSerialNumber(i);
            addrs = iLendingManager(lendingManager).assetsDepositAndLendAddrs(addrA);
            tempPrice = iSlcOracle(oracleAddr).getPrice(addrA);
            totalValueOfMortgagedAssets += IERC20(addrs[0]).totalSupply() * iSlcOracle(oracleAddr).getPrice(addrA) / 1 ether;
            totalValueOfLendedAssets += IERC20(addrs[1]).totalSupply() * iSlcOracle(oracleAddr).getPrice(addrA) / 1 ether;
        }
    }

    function licensedRIMassetsInfo()
        public
        view
        returns (
            address[] memory allRIMtokens,
            uint[] memory allRIMtokensPrice,
            uint[] memory maxLendingAmountInRIM
        )
    {
        uint[] memory assetPrice = licensedAssetPrice();
        address[] memory assets = new address[](assetPrice.length);
        uint[] memory maxLendingAmount = new uint[](assetPrice.length);
        uint num = assetPrice.length;
        uint RIMnum;
        uint tempMax;
        for (uint i; i != num; i++) {
            (, , tempMax, , , , ) = assetsBaseInfo(assetsSerialNumber(i));
            if (tempMax > 0) {
                RIMnum += 1;
                assets[RIMnum - 1] = assetsSerialNumber(i);
                assetPrice[RIMnum - 1] = assetPrice[i];
                maxLendingAmount[RIMnum - 1] = tempMax;
            }
        }
        allRIMtokens = new address[](RIMnum);
        maxLendingAmountInRIM = new uint[](RIMnum);
        allRIMtokensPrice = new uint[](RIMnum);
        for (uint i; i != RIMnum; i++) {
            allRIMtokens[i] = assets[i];
            allRIMtokensPrice[i] = assetPrice[i];
            maxLendingAmountInRIM[i] = maxLendingAmount[i];
        }
    }
    function userDepositAndLendingValue(
        address user
    ) public view returns (uint _amountDeposit, uint _amountLending) {
        return iLendingManager(lendingManager).userDepositAndLendingValue(user);
    }
    function userAssetOverview(
        address user
    )
        public
        view
        returns (
            address[] memory tokens,
            uint[] memory _amountDeposit,
            uint[] memory _amountLending
        )
    {
        return iLendingManager(lendingManager).userAssetOverview(user);
    }
    function userAssetDetail(
        address user
    )
        public
        view
        returns (
            address[] memory tokens,
            uint[] memory _amountDeposit,
            uint[] memory _amountLending,
            uint[] memory _depositInterest,
            uint[] memory _lendingInterest,
            uint[] memory _availableAmount
        )
    {
        (tokens, _amountDeposit, _amountLending) = iLendingManager(
            lendingManager
        ).userAssetOverview(user);
        uint UserLendableLimit = viewUserLendableLimit(user);
        uint[] memory assetsPrice = licensedAssetPrice();
        _depositInterest = new uint[](tokens.length);
        _lendingInterest = new uint[](tokens.length);
        _availableAmount = new uint[](tokens.length);
        uint[] memory _availableAmount2 = lendAvailableAmount();
        for (uint i = 0; i != tokens.length; i++) {
            (
                ,
                ,
                _depositInterest[i],
                _lendingInterest[i]
            ) = assetsTimeDependentParameter(tokens[i]);
            if (assetsPrice[i] > 0) {
                _availableAmount[i] =
                    (UserLendableLimit * 1 ether) /
                    assetsPrice[i];
            } else {
                _availableAmount[i] = 0;
            }

            _availableAmount[i] = (
                _availableAmount[i] < _availableAmount2[i]
                    ? _availableAmount[i]
                    : _availableAmount2[i]
            );
        }
    }
    // operator mode:  assetsDeposit 0, withdrawDeposit 1, lendAsset 2, repayLoan 3
    function usersHealthFactorAndInterestEstimate(
        address user,
        address token,
        uint amount,
        uint operator
    )
        external
        view
        returns (uint userHealthFactor,
                 uint[2] memory newInterest,
                 uint _amountDeposit,
                 uint _amountLending)
    {
        uint tokenPrice = iSlcOracle(oracleAddr).getPrice(token);
        uint modeLTV;
        uint8 _userMode = iLendingManager(lendingManager).userMode(user);
        if(_userMode>1){
            modeLTV = licensedAssets(token).homogeneousModeLTV;
        }else{
            modeLTV = licensedAssets(token).maximumLTV;
        }

        (_amountDeposit, _amountLending) = iLendingManager(lendingManager)
            .userDepositAndLendingValue(user);
        if (operator == 0) {
            _amountDeposit +=
                (amount * tokenPrice) /
                1 ether;
        } else if (operator == 1) {
            _amountDeposit -=
                (amount * tokenPrice) /
                1 ether;
        } else if (operator == 2) {
            _amountLending +=
                (amount * tokenPrice) /
                1 ether;
        } else if (operator == 3) {
            _amountLending -=
                (amount * tokenPrice) /
                1 ether;
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
        address[2] memory depositAndLend = iLendingManager(lendingManager)
            .assetsDepositAndLendAddrs(token);
        uint lendingRatio;
        _amountDeposit = iDepositOrLoanCoin(depositAndLend[0]).totalSupply();
        _amountLending = iDepositOrLoanCoin(depositAndLend[1]).totalSupply();
        uint upperLimit = UPPER_SYSTEM_LIMIT() ;
        if (iDepositOrLoanCoin(depositAndLend[0]).totalSupply() > 0) {
            if (operator == 0) {
                _amountDeposit += amount * modeLTV / upperLimit;
            } else if (operator == 1) {
                if(_amountDeposit > amount * modeLTV / upperLimit){
                    _amountDeposit -= amount * modeLTV / upperLimit;
                }else{
                    _amountDeposit = 0;
                }
            } else if (operator == 2) {
                _amountLending += amount;
            } else if (operator == 3) {
                if(_amountLending > amount){
                    _amountLending -= amount;
                }else{
                    _amountLending = 0;
                }
            }
            if (_amountDeposit > 0) {
                lendingRatio = (_amountLending * upperLimit) / _amountDeposit;
            }else{
                lendingRatio = 0;
            }
        } else {
            lendingRatio = 0;
        }

        if (lendingRatio > upperLimit) {
            lendingRatio = upperLimit;
        }
        newInterest[0] = iLendingCoreAlgorithm(lCoreAddr).depositInterestRate(
            token,
            lendingRatio
        );
        uint reserveFactor = assetsReserveFactor(token);
        newInterest[1] = iLendingCoreAlgorithm(lCoreAddr).lendingInterestRate(
            token,
            lendingRatio,
            reserveFactor
        );
    }

    // User's Lendable Limit
    function viewUserLendableLimit(
        address user
    ) public view returns (uint userLendableLimit) {
        uint _amountDeposit;
        uint _amountLending;
        uint8 _userMode = iLendingManager(lendingManager).userMode(user);
        uint normalFloor = normalFloorOfHealthFactor();
        uint homogeneousFloor = homogeneousFloorOfHealthFactor();
        (_amountDeposit, _amountLending) = iLendingManager(lendingManager)
            .userDepositAndLendingValue(user);
        if (_userMode <= 1) {
            if (
                (_amountDeposit * 1 ether) / normalFloor >
                _amountLending
            ) {
                userLendableLimit =
                    (_amountDeposit * 1 ether) /
                    normalFloor -
                    _amountLending;
            } else {
                userLendableLimit = 0;
            }
        } else {
            if (
                (_amountDeposit * 1 ether) / homogeneousFloor >
                _amountLending
            ) {
                userLendableLimit =
                    (_amountDeposit * 1 ether) /
                    homogeneousFloor -
                    _amountLending;
            } else {
                userLendableLimit = 0;
            }
        }
    }

    function assetsSerialNumber(uint num) public view returns (address) {
        return iLendingManager(lendingManager).assetsSerialNumber(num);
    }
    function userMode(
        address user
    ) public view returns (uint8 mode, address userSetAssets) {
        mode = iLendingManager(lendingManager).userMode(user);
        userSetAssets = iLendingManager(lendingManager).userRIMAssetsAddress(
            user
        );
    }
    function ONE_YEAR() public view returns (uint) {
        return iLendingManager(lendingManager).ONE_YEAR();
    }
    function UPPER_SYSTEM_LIMIT() public view returns (uint) {
        return iLendingManager(lendingManager).UPPER_SYSTEM_LIMIT();
    }
    function normalFloorOfHealthFactor() public view returns (uint) {
        return iLendingManager(lendingManager).normalFloorOfHealthFactor();
    }
    function homogeneousFloorOfHealthFactor() public view returns (uint) {
        return iLendingManager(lendingManager).homogeneousFloorOfHealthFactor();
    }

    function userRIMAssetsLendingNetAmount(
        address user,
        address token
    ) public view returns (uint) {
        return
            iLendingManager(lendingManager).userRIMAssetsLendingNetAmount(
                user,
                token
            );
    }
    function riskIsolationModeLendingNetAmount(
        address token
    ) public view returns (uint) {
        return
            iLendingManager(lendingManager).riskIsolationModeLendingNetAmount(
                token
            );
    }

    function usersRiskDetails(
        address user
    )
        external
        view
        returns (
            uint userValueUsedRatio,
            uint userMaxUsedRatio,
            uint tokenLiquidateRatio
        )
    {
        uint[3] memory tempRustFactor;
        uint8 _mode;
        address _userRIMSetAssets;
        (_mode, _userRIMSetAssets) = userMode(user);

        address[] memory tokens;
        uint[] memory _amountDeposit;
        uint[] memory _amountLending;
        iLendingManager.licensedAsset memory usefulAsset;
        uint[] memory assetPrice = licensedAssetPrice();
        (tokens, _amountDeposit, _amountLending) = userAssetOverview(user);
        if (_mode == 1) {
            for (uint i = 0; i != tokens.length; i++) {
                if (tokens[i] == _userRIMSetAssets && _amountDeposit[i] > 0) {
                    userValueUsedRatio =
                        (((userRIMAssetsLendingNetAmount(
                            user,
                            _userRIMSetAssets
                        ) * 10000) / _amountDeposit[i]) * 1 ether) /
                        assetPrice[i];
                    usefulAsset = licensedAssets(tokens[i]);
                    userMaxUsedRatio =
                        (usefulAsset.maximumLTV * 1 ether) /
                        normalFloorOfHealthFactor();
                    tokenLiquidateRatio = usefulAsset.maximumLTV;
                    break;
                }
            }
        } else if (_mode == 0) {
            for (uint i = 0; i != tokens.length; i++) {
                usefulAsset = licensedAssets(tokens[i]);
                if (usefulAsset.lendingModeNum != 1) {
                    tempRustFactor[1] +=
                        (_amountDeposit[i] * assetPrice[i]) /
                        1 ether;
                    tempRustFactor[2] +=
                        (_amountLending[i] * assetPrice[i]) /
                        1 ether;
                    userMaxUsedRatio +=
                        (_amountDeposit[i] *
                            assetPrice[i] *
                            usefulAsset.maximumLTV) /
                        normalFloorOfHealthFactor() /
                        10000;
                    tokenLiquidateRatio +=
                        (((_amountDeposit[i] * assetPrice[i]) / 1 ether) *
                            usefulAsset.maximumLTV) /
                        10000;
                }
            }
            if (tempRustFactor[1] > 0) {
                userValueUsedRatio =
                    (tempRustFactor[2] * 10000) /
                    tempRustFactor[1];
                userMaxUsedRatio =
                    (userMaxUsedRatio * 10000) /
                    tempRustFactor[1];
                tokenLiquidateRatio =
                    (tokenLiquidateRatio * 10000) /
                    tempRustFactor[1];
            } else {
                userValueUsedRatio = 0;
                userMaxUsedRatio = 0;
                tokenLiquidateRatio = 0;
            }
        } else if (_mode > 1) {
            for (uint i = 0; i != tokens.length; i++) {
                usefulAsset = licensedAssets(tokens[i]);
                if (usefulAsset.lendingModeNum == _mode) {
                    tempRustFactor[1] +=
                        (_amountDeposit[i] * assetPrice[i]) /
                        1 ether;
                    tempRustFactor[2] +=
                        (_amountLending[i] * assetPrice[i]) /
                        1 ether;
                    userMaxUsedRatio +=
                        (_amountDeposit[i] *
                            assetPrice[i] *
                            usefulAsset.maximumLTV) /
                        homogeneousFloorOfHealthFactor() /
                        10000;
                    tokenLiquidateRatio +=
                        (((_amountDeposit[i] * assetPrice[i]) / 1 ether) *
                            usefulAsset.maximumLTV) /
                        10000;
                }
            }
            if (tempRustFactor[1] > 0) {
                userValueUsedRatio =
                    (tempRustFactor[2] * 10000) /
                    tempRustFactor[1];
                userMaxUsedRatio =
                    (userMaxUsedRatio * 10000) /
                    tempRustFactor[1];
                tokenLiquidateRatio =
                    (tokenLiquidateRatio * 10000) /
                    tempRustFactor[1];
            } else {
                userValueUsedRatio = 0;
                userMaxUsedRatio = 0;
                tokenLiquidateRatio = 0;
            }
        }
    }

    function userProfile(
        address user
    ) public view returns (int netWorth, int netApy) {
        uint[5] memory tempRustFactor;
        uint8 _mode;
        address _userRIMSetAssets;
        int fullWorth;
        (_mode, _userRIMSetAssets) = userMode(user);

        address[] memory tokens;
        uint[] memory _amountDeposit;
        uint[] memory _amountLending;
        uint[] memory assetPrice = licensedAssetPrice();
        (tokens, _amountDeposit, _amountLending) = userAssetOverview(user);
        uint depositInterest;
        uint lendingInterest;
        for (uint i = 0; i != tokens.length; i++) {
            tempRustFactor[0] = tempRustFactor[0] + _amountDeposit[i];
            tempRustFactor[1] =
                tempRustFactor[1] +
                (_amountDeposit[i] * assetPrice[i]) /
                1 ether;
            tempRustFactor[2] =
                tempRustFactor[2] +
                (_amountLending[i] * assetPrice[i]) /
                1 ether;
            (
                ,
                ,
                depositInterest,
                lendingInterest
            ) = assetsTimeDependentParameter(tokens[i]);
            tempRustFactor[3] =
                tempRustFactor[3] +
                (depositInterest * _amountDeposit[i] * assetPrice[i]) /
                1 ether;
            tempRustFactor[4] =
                tempRustFactor[4] +
                (lendingInterest * _amountLending[i] * assetPrice[i]) /
                1 ether;
        }
        netWorth = netWorth + int(tempRustFactor[1]) - int(tempRustFactor[2]);
        fullWorth = fullWorth + int(tempRustFactor[1]);
        if (tempRustFactor[0] == 0) {
            netApy = 0;
        } else {
            netApy = (int(tempRustFactor[3]) - int(tempRustFactor[4])) / fullWorth;
        }
    }

    function generalParametersOfAllAssets()
        public
        view
        returns (
            address[] memory tokens,
            uint[] memory totalSupplied,
            uint[] memory totalBorrowed,
            uint[] memory supplyApy,
            uint[] memory borrowApy,
            uint[] memory assetsPrice,
            uint8[] memory tokenMode
        )
    {
        (tokens, , ) = iLendingManager(lendingManager).userAssetOverview(
            address(0)
        );
        totalSupplied = new uint[](tokens.length);
        totalBorrowed = new uint[](tokens.length);
        supplyApy = new uint[](tokens.length);
        borrowApy = new uint[](tokens.length);
        assetsPrice = licensedAssetPrice();
        tokenMode = new uint8[](tokens.length);
        iLendingManager.licensedAsset memory usefulAsset;
        uint[2] memory tempAmounts;

        for (uint i = 0; i != tokens.length; i++) {
            (, , supplyApy[i], borrowApy[i]) = assetsTimeDependentParameter(
                tokens[i]
            );
            usefulAsset = licensedAssets(tokens[i]);
            tokenMode[i] = usefulAsset.lendingModeNum;
            tempAmounts = assetsDepositAndLendAmount(tokens[i]);
            totalSupplied[i] = tempAmounts[0];
            totalBorrowed[i] = tempAmounts[1];
        }
    }
    //-------------------------------token Liquidate Estimate-------------------------------------------
    function _refundTokenDelta(address tokenAddr, uint balanceBefore) internal {
        uint currentBalance = IERC20(tokenAddr).balanceOf(address(this));
        if (currentBalance > balanceBefore) {
            IERC20(tokenAddr).safeTransfer(
                msg.sender,
                currentBalance - balanceBefore
            );
        }
    }

    function _refundNativeDelta(uint nativeBefore) internal {
        uint currentNative = address(this).balance;
        if (currentNative > nativeBefore) {
            (bool success, ) = payable(msg.sender).call{
                value: currentNative - nativeBefore
            }("");
            require(success, "Native refund failed");
        }
    }

    function tokenLiquidateEstimate(address user,
                            address liquidateToken,
                            address depositToken) public view returns(uint[2] memory maxAmounts){
        if(viewUsersHealthFactor(user) >= 1 ether){
            uint[2] memory zero;
            return zero;
        }
        uint amountLending = iDepositOrLoanCoin(assetsDepositAndLendAddrs(liquidateToken)[1]).balanceOf(user);
        uint amountDeposit = iDepositOrLoanCoin(assetsDepositAndLendAddrs(depositToken)[0]).balanceOf(user);
        if (amountLending == 0 || amountDeposit == 0) {
            return maxAmounts;
        }

        uint liquidateTokenPrice = iSlcOracle(oracleAddr).getPrice(liquidateToken);
        uint depositTokenPrice = iSlcOracle(oracleAddr).getPrice(depositToken);
        uint upperSystemLimit = UPPER_SYSTEM_LIMIT();
        uint closeFactor = iLendingManager(lendingManager).LIQUIDATION_CLOSE_FACTOR();
        uint liquidationPenalty = licensedAssets(depositToken).liquidationPenalty;

        uint maxCloseAmount = amountLending * closeFactor / upperSystemLimit;
        if (maxCloseAmount == 0) {
            maxCloseAmount = amountLending;
        }

        uint maxRepayByCollateral = amountDeposit * depositTokenPrice / 1 ether;
        maxRepayByCollateral = maxRepayByCollateral
            * upperSystemLimit
            / (upperSystemLimit + liquidationPenalty);
        maxRepayByCollateral = maxRepayByCollateral * 1 ether / liquidateTokenPrice;

        uint maxRepayNormalized = maxCloseAmount < maxRepayByCollateral
            ? maxCloseAmount
            : maxRepayByCollateral;
        if (maxRepayNormalized > amountLending) {
            maxRepayNormalized = amountLending;
        }
        if (maxRepayNormalized == 0) {
            return maxAmounts;
        }

        uint maxSeizeNormalized = maxRepayNormalized
            * liquidateTokenPrice
            * (upperSystemLimit + liquidationPenalty)
            / (upperSystemLimit * depositTokenPrice);

        maxAmounts[0] =
            maxRepayNormalized *
            (10**iDecimals(liquidateToken).decimals()) /
            1 ether;
        maxAmounts[1] =
            maxSeizeNormalized *
            (10**iDecimals(depositToken).decimals()) /
            1 ether;
    }

    //=======================================stake for Gimo=============================================
    function gimoStake() public payable{
        iLstGimo(lstGimo).stake{value: msg.value}("zerrow");
    }
    function gimoUnstake(uint256 _lsdTokenAmount) public{
        iLstGimo(lstGimo).unstake(_lsdTokenAmount);
    }
    function getRate() public view returns (uint256){
        return iLstGimo(lstGimo).getRate();
    }
    function withdraw() public{
        iLstGimo(lstGimo).withdraw();
    }
    //-----------------------------------------loop for assets---------------------------------------------
    //  Assets single Lst Deposit
    function lstStake(address stakeToken) public payable nonReentrant {
        uint nativeBefore = address(this).balance - msg.value;
        uint stakeBalanceBefore = IERC20(stakeToken).balanceOf(address(this));

        if(stakeToken == gToken){
            iLstGimo(lstGimo).stake{value: msg.value}("zerrow");

        }else{
            revert("Need be a Lst Token");
        }
        _refundTokenDelta(stakeToken, stakeBalanceBefore);
        _refundNativeDelta(nativeBefore);
    }

    function lstStakeAndDeposit(address stakeToken) public payable nonReentrant {
        uint nativeBefore = address(this).balance - msg.value;
        uint stakeBalanceBefore = IERC20(stakeToken).balanceOf(address(this));

        if(stakeToken == gToken){
            iLstGimo(lstGimo).stake{value: msg.value}("zerrow");

        }else{
            revert("Need be a Lst Token");
        }
        uint amount = IERC20(stakeToken).balanceOf(address(this)) - stakeBalanceBefore;
        IERC20(stakeToken).approve(lendingManager, amount);
        iLendingManager(lendingManager).assetsDeposit( stakeToken, amount, msg.sender );
        _refundTokenDelta(stakeToken, stakeBalanceBefore);
        _refundNativeDelta(nativeBefore);
    }

    //  Assets loop Deposit, both Lst and Other high liqulity Coin
    function looperDeposit(address tokenAddr,
                           address stakeToken,
                           uint    amount,
                           uint    times,
                           uint    percentage) external payable nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(times == 1, "Looper limited to one iteration");
        require(percentage <= 10000, "Percentage must be <= 10000");
        uint currentAmount = amount;
        uint nativeBefore = address(this).balance - msg.value;
        uint tokenBefore = IERC20(tokenAddr).balanceOf(address(this));
        uint stakeBefore = IERC20(stakeToken).balanceOf(address(this));

        if (tokenAddr == W0G) {
            require(amount == msg.value,"Lending Interface: amount should == msg.value");
        } else {
            require(msg.value == 0, "Lending Interface: msg.value should == 0");
            IERC20(tokenAddr).safeTransferFrom(msg.sender, address(this), amount);
        }

        for(uint i = 0; i != times; i++){
            if (tokenAddr == W0G) {
                if(stakeToken == gToken) {
                    require(currentAmount <= address(this).balance,"Insufficient balance");
                    // Stake current amount
                    iLstGimo(lstGimo).stake{value: currentAmount}("zerrow");
                    // Get received gTokens
                    uint gTokenBalance = IERC20(gToken).balanceOf(address(this)) - stakeBefore;
                    require(gTokenBalance > 0, "No gTokens received");
                    // Approve and deposit gTokens
                    IERC20(gToken).approve(lendingManager, gTokenBalance);
                    iLendingManager(lendingManager).assetsDeposit( gToken, gTokenBalance, msg.sender);
                }else{
                    revert("Need be a 0g Lst Token");
                }
                // Calculate and validate lending amount
                uint lendAmount = (currentAmount * percentage) / 10000;
                require(lendAmount > 0, "Lending amount too small");
                iLendingManager(lendingManager).lendAsset(tokenAddr, lendAmount, msg.sender );
                // Update for next iteration
                currentAmount = lendAmount;
            }else if(tokenAddr == stakeToken) {
                require(currentAmount <= IERC20(tokenAddr).balanceOf(address(this)),"Insufficient balance");
                // Approve and deposit tokens
                IERC20(tokenAddr).approve(lendingManager, currentAmount);
                iLendingManager(lendingManager).assetsDeposit(tokenAddr, currentAmount, msg.sender);
                // Calculate and validate lending amount
                uint lendAmount = (currentAmount * percentage) / 10000;
                require(lendAmount > 0, "Lending amount too small");
                // Borrow only the computed recursive step, not the original amount,
                // otherwise the helper over-leverages the user in a single hop.
                iLendingManager(lendingManager).lendAsset( tokenAddr, lendAmount, msg.sender );
                // Update for next iteration
                currentAmount = lendAmount;
            }else{
                revert("Token Not allowed");
            }
        }

        if (tokenAddr != W0G) {
            _refundTokenDelta(tokenAddr, tokenBefore);
        }
        _refundTokenDelta(stakeToken, stakeBefore);
        _refundNativeDelta(nativeBefore);
    }
    // ======================== contract base methods =====================
    fallback() external payable {}
    receive() external payable {}
}
