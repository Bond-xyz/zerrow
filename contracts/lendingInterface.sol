// SPDX-License-Identifier: Business Source License 1.1
// First Release Time : 2025.03.30

pragma solidity 0.8.6;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/iLendingManager.sol";
import "./interfaces/iwA0GI.sol";
import "./interfaces/islcoracle.sol";
import "./interfaces/iDepositOrLoanCoin.sol";
import "./interfaces/iLendingCoreAlgorithm.sol";
import "./interfaces/iDecimals.sol";

/// @custom:oz-upgrades-unsafe-allow constructor
contract lendingInterface is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    address public lendingManager;
    address public A0GI;
    address public oracleAddr;
    address public lCoreAddr;

    /// @notice Admin address for upgrade authorization
    address public admin;

    using SafeERC20 for IERC20;

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;

    /// @dev Disable initializer on implementation contract
    constructor() initializer {}

    /// @notice Replaces constructor for proxy deployment
    function initialize(
        address _manager,
        address _a0gi,
        address _oracle,
        address _core
    ) public initializer {
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        lendingManager = _manager;
        A0GI = _a0gi;
        oracleAddr = _oracle;
        lCoreAddr = _core;
        admin = msg.sender;
    }

    /// @dev Required by UUPSUpgradeable
    function _authorizeUpgrade(address) internal override {
        require(msg.sender == admin, "not admin");
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
    function lendAvailableAmount()
        public
        view
        returns (uint[] memory availableAmount)
    {
        uint[] memory assetPrice = licensedAssetPrice();
        uint assetLength = assetPrice.length;
        availableAmount = new uint[](assetLength);
        uint[2] memory depositAndLendAmount;
        for (uint i = 0; i != assetLength; i++) {
            depositAndLendAmount = assetsDepositAndLendAmount(assetsSerialNumber(i));
            if (depositAndLendAmount[0] > depositAndLendAmount[1]) {
                availableAmount[i] =
                    depositAndLendAmount[0] -
                    depositAndLendAmount[1];
            } else {
                availableAmount[i] = 0;
            }
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

    //------------------------------------------------Operation----------------------------------------------------
    function userModeSetting(
        uint8 _mode,
        address _userRIMAssetsAddress
    ) external {
        iLendingManager(lendingManager).userModeSetting(
            _mode,
            _userRIMAssetsAddress,
            msg.sender
        );
    }
    //  Assets Deposit
    function assetsDeposit(address tokenAddr, uint amount) external nonReentrant{
        IERC20(tokenAddr).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(tokenAddr).approve(lendingManager, amount);
        iLendingManager(lendingManager).assetsDeposit(
            tokenAddr,
            amount,
            msg.sender
        );
        if (IERC20(tokenAddr).balanceOf(address(this)) > 0) {
            IERC20(tokenAddr).safeTransfer(
                msg.sender,
                IERC20(tokenAddr).balanceOf(address(this))
            );
        }
    }
    // Withdrawal of deposits
    function withdrawDeposit(address tokenAddr, uint amount) external nonReentrant{
        iLendingManager(lendingManager).withdrawDeposit(
            tokenAddr,
            amount,
            msg.sender
        );
        if (IERC20(tokenAddr).balanceOf(address(this)) > 0) {
            IERC20(tokenAddr).safeTransfer(
                msg.sender,
                IERC20(tokenAddr).balanceOf(address(this))
            );
        }
    }
    // lend Asset
    function lendAsset(address tokenAddr, uint amount) external nonReentrant{
        iLendingManager(lendingManager).lendAsset(
            tokenAddr,
            amount,
            msg.sender
        );
        if (IERC20(tokenAddr).balanceOf(address(this)) > 0) {
            IERC20(tokenAddr).safeTransfer(
                msg.sender,
                IERC20(tokenAddr).balanceOf(address(this))
            );
        }
    }
    // repay Loan
    function repayLoan(address tokenAddr, uint amount) external nonReentrant{
        IERC20(tokenAddr).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(tokenAddr).approve(lendingManager, amount);
        iLendingManager(lendingManager).repayLoan(
            tokenAddr,
            amount,
            msg.sender
        );
        if (IERC20(tokenAddr).balanceOf(address(this)) > 0) {
            IERC20(tokenAddr).safeTransfer(
                msg.sender,
                IERC20(tokenAddr).balanceOf(address(this))
            );
        }
    }
    //-----------------------------------------Operation 2 can use 0g---------------------------------------------
    //  Assets Deposit
    function assetsDeposit2(address tokenAddr, uint amount) external payable nonReentrant{
        if (tokenAddr == A0GI) {
            require(
                amount <= msg.value,
                "Lending Interface: amount should == msg.value"
            );
            iwA0GI(A0GI).deposit{value: amount}();
        } else {
            require(msg.value == 0, "Lending Interface: msg.value should == 0");
            IERC20(tokenAddr).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
        }

        IERC20(tokenAddr).approve(lendingManager, amount);
        iLendingManager(lendingManager).assetsDeposit(
            tokenAddr,
            amount,
            msg.sender
        );
        if (IERC20(A0GI).balanceOf(address(this)) > 0) {
            iwA0GI(A0GI).withdraw(IERC20(A0GI).balanceOf(address(this)));
        }
        if (IERC20(tokenAddr).balanceOf(address(this)) > 0) {
            IERC20(tokenAddr).safeTransfer(
                msg.sender,
                IERC20(tokenAddr).balanceOf(address(this))
            );
        }
        if (address(this).balance > 0) {
            address payable receiver = payable(msg.sender);
            (bool success, ) = receiver.call{value: address(this).balance}("");
            require(success, "Lending Interface: 0g Transfer Failed");
        }
    }
    // Withdrawal of deposits
    function withdrawDeposit2(address tokenAddr, uint amount) external nonReentrant{
        iLendingManager(lendingManager).withdrawDeposit(
            tokenAddr,
            amount,
            msg.sender
        );
        if (IERC20(A0GI).balanceOf(address(this)) > 0) {
            iwA0GI(A0GI).withdraw(IERC20(A0GI).balanceOf(address(this)));
        }
        if (IERC20(tokenAddr).balanceOf(address(this)) > 0) {
            IERC20(tokenAddr).safeTransfer(
                msg.sender,
                IERC20(tokenAddr).balanceOf(address(this))
            );
        }
        if (address(this).balance > 0) {
            address payable receiver = payable(msg.sender);
            (bool success, ) = receiver.call{value: address(this).balance}("");
            require(success, "Lending Interface: 0g Transfer Failed");
        }
    }
    function withdrawDepositMax2(address tokenAddr) external nonReentrant {
        address[2] memory depositAndLend = assetsDepositAndLendAddrs(tokenAddr);
        uint tokenBalance = IERC20(depositAndLend[0]).balanceOf(
            address(msg.sender)
        );
        tokenBalance = tokenBalance * (10**iDecimals(tokenAddr).decimals()) / 1 ether;
        iLendingManager(lendingManager).withdrawDeposit(
            tokenAddr,
            tokenBalance,
            msg.sender
        );
        if (IERC20(A0GI).balanceOf(address(this)) > 0) {
            iwA0GI(A0GI).withdraw(IERC20(A0GI).balanceOf(address(this)));
        }
        if (IERC20(tokenAddr).balanceOf(address(this)) > 0) {
            IERC20(tokenAddr).safeTransfer(
                msg.sender,
                IERC20(tokenAddr).balanceOf(address(this))
            );
        }
        if (address(this).balance > 0) {
            address payable receiver = payable(msg.sender);
            (bool success, ) = receiver.call{value: address(this).balance}("");
            require(success, "Lending Interface: 0g Transfer Failed");
        }
    }
    // lend Asset
    function lendAsset2(address tokenAddr, uint amount) external nonReentrant{
        iLendingManager(lendingManager).lendAsset(
            tokenAddr,
            amount,
            msg.sender
        );
        if (IERC20(A0GI).balanceOf(address(this)) > 0) {
            iwA0GI(A0GI).withdraw(IERC20(A0GI).balanceOf(address(this)));
        } else if (IERC20(tokenAddr).balanceOf(address(this)) > 0) {
            IERC20(tokenAddr).safeTransfer(
                msg.sender,
                IERC20(tokenAddr).balanceOf(address(this))
            );
        }
        if (address(this).balance > 0) {
            address payable receiver = payable(msg.sender);
            (bool success, ) = receiver.call{value: address(this).balance}("");
            require(success, "Lending Interface: 0g Transfer Failed");
        }
    }
    // repay Loan
    function repayLoan2(address tokenAddr, uint amount) external payable nonReentrant{
        if (tokenAddr == A0GI) {
            require(
                amount <= msg.value,
                "Lending Interface: amount should == msg.value"
            );
            iwA0GI(A0GI).deposit{value: amount}();
        } else {
            require(msg.value == 0, "Lending Interface: msg.value should == 0");
            IERC20(tokenAddr).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
        }
        IERC20(tokenAddr).approve(lendingManager, amount);
        iLendingManager(lendingManager).repayLoan(
            tokenAddr,
            amount,
            msg.sender
        );
        if (IERC20(A0GI).balanceOf(address(this)) > 0) {
            iwA0GI(A0GI).withdraw(IERC20(A0GI).balanceOf(address(this)));
        }
        if (IERC20(tokenAddr).balanceOf(address(this)) > 0) {
            IERC20(tokenAddr).safeTransfer(
                msg.sender,
                IERC20(tokenAddr).balanceOf(address(this))
            );
        }
        if (address(this).balance > 0) {
            address payable receiver = payable(msg.sender);
            (bool success, ) = receiver.call{value: address(this).balance}("");
            require(success, "Lending Interface: 0g Transfer Failed");
        }
    }
    function repayLoanMax2(address tokenAddr) external payable nonReentrant {
        address[2] memory depositAndLend = assetsDepositAndLendAddrs(tokenAddr);
        uint tokenBalance = IERC20(depositAndLend[1]).balanceOf(
            address(msg.sender)
        );
        uint tokenBackAmount = tokenBalance * (10**iDecimals(tokenAddr).decimals()) / 1 ether;
        if(tokenBalance > tokenBackAmount * 1 ether / (10**iDecimals(tokenAddr).decimals())) {
            tokenBackAmount = tokenBackAmount + 1;
        }
        if (tokenAddr == A0GI) {
            require(
                tokenBackAmount <= msg.value,
                "Lending Interface: amount should == msg.value"
            );
            iwA0GI(A0GI).deposit{value: tokenBackAmount}();
        } else {
            require(msg.value == 0, "Lending Interface: msg.value should == 0");
            IERC20(tokenAddr).safeTransferFrom(
                msg.sender,
                address(this),
                tokenBackAmount
            );
        }
        IERC20(tokenAddr).approve(lendingManager, tokenBackAmount);
        iLendingManager(lendingManager).repayLoan(
            tokenAddr,
            tokenBackAmount,
            msg.sender
        );
        if (IERC20(A0GI).balanceOf(address(this)) > 0) {
            iwA0GI(A0GI).withdraw(IERC20(A0GI).balanceOf(address(this)));
        }
        if (IERC20(tokenAddr).balanceOf(address(this)) > 0) {
            IERC20(tokenAddr).safeTransfer(
                msg.sender,
                IERC20(tokenAddr).balanceOf(address(this))
            );
        }
        if (address(this).balance > 0) {
            address payable receiver = payable(msg.sender);
            (bool success, ) = receiver.call{value: address(this).balance}("");
            require(success, "Lending Interface: 0g Transfer Failed");
        }
    }
    // ======================== contract base methods =====================
    fallback() external payable {}
    receive() external payable {}
}
