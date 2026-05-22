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
import "./interfaces/iDecimals.sol";
import "./LendingInterfaceLib.sol";

/// @custom:oz-upgrades-unsafe-allow constructor
contract lendingInterface is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    address public lendingManager;
    address public W0G;
    address public oracleAddr;
    address public lCoreAddr;

    /// @notice Admin address for upgrade authorization
    address public admin;
    address public pendingAdmin;

    using SafeERC20 for IERC20;

    /// @notice Emitted when repayLoanMax2 leaves sub-raw-unit normalized dust
    ///         because the user's debt has precision below the token's decimals.
    /// @param user         The borrower whose debt was (nearly) fully repaid.
    /// @param tokenAddr    The underlying ERC-20 repayment token.
    /// @param dustNormalized Residual normalized debt (< 1 raw unit in value).
    event RepayLoanMaxDust(address indexed user, address indexed tokenAddr, uint dustNormalized);

    /// @dev Storage gap for future upgrades
    uint256[49] private __gap;

    /// @dev Disable initializer on implementation contract
    constructor() initializer {}

    /// @notice Replaces constructor for proxy deployment
    function initialize(
        address _manager,
        address _w0g,
        address _oracle,
        address _core
    ) public initializer {
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        lendingManager = _manager;
        W0G = _w0g;
        oracleAddr = _oracle;
        lCoreAddr = _core;
        admin = msg.sender;
    }

    /// @dev Required by UUPSUpgradeable
    function _authorizeUpgrade(address) internal override {
        require(msg.sender == admin, "not admin");
    }

    function transferAdmin(address _admin) external {
        require(msg.sender == admin, "not admin");
        require(_admin != address(0), "Lending Interface: New admin cannot be zero");
        require(_admin != admin, "Lending Interface: Cannot transfer to current admin");
        pendingAdmin = _admin;
    }

    function acceptAdmin(bool _TorF) external {
        require(msg.sender == pendingAdmin, "Lending Interface: Permission FORBIDDEN");
        if (_TorF) {
            admin = pendingAdmin;
        }
        pendingAdmin = address(0);
    }

    function cancelTransferAdmin() external {
        require(msg.sender == admin, "not admin");
        address cancelled = pendingAdmin;
        pendingAdmin = address(0);
        emit TransferAdminCancelled(cancelled);
    }

    event TransferAdminCancelled(address indexed cancelledPending);

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
        for (uint i = 0; i != assetLength; i++) {
            availableAmount[i] = iLendingManager(lendingManager).VaultTokensAmount(
                assetsSerialNumber(i)
            );
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
        return LendingInterfaceLib.computeHealthFactorEstimate(
            user, token, amount, operator,
            lendingManager, oracleAddr, lCoreAddr
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
        return LendingInterfaceLib.computeUsersRiskDetails(user, lendingManager, oracleAddr);
    }

    function userProfile(
        address user
    ) public view returns (int netWorth, int netApy) {
        return LendingInterfaceLib.computeUserProfile(user, lendingManager, oracleAddr);
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
        return LendingInterfaceLib.computeGeneralParameters(lendingManager, oracleAddr);
    }

    //------------------------------------------------Operation----------------------------------------------------
    function _refundTokenDelta(address tokenAddr, uint balanceBefore) internal {
        uint balanceAfter = IERC20(tokenAddr).balanceOf(address(this));
        if (balanceAfter > balanceBefore) {
            IERC20(tokenAddr).safeTransfer(msg.sender, balanceAfter - balanceBefore);
        }
    }

    function _refundNativeCompatible(
        address tokenAddr,
        uint tokenBefore,
        uint wrappedBefore,
        uint nativeBefore
    ) internal {
        uint wrappedAfter = IERC20(W0G).balanceOf(address(this));
        if (wrappedAfter > wrappedBefore) {
            iw0G(W0G).withdraw(wrappedAfter - wrappedBefore);
        }

        if (tokenAddr != W0G) {
            uint tokenAfter = IERC20(tokenAddr).balanceOf(address(this));
            if (tokenAfter > tokenBefore) {
                IERC20(tokenAddr).safeTransfer(msg.sender, tokenAfter - tokenBefore);
            }
        }

        uint nativeAfter = address(this).balance;
        if (nativeAfter > nativeBefore) {
            address payable receiver = payable(msg.sender);
            (bool success, ) = receiver.call{value: nativeAfter - nativeBefore}("");
            require(success, "Lending Interface: 0g Transfer Failed");
        }
    }

    /// @notice Pull W0G from msg.sender, unwrap to native 0G, and send to msg.sender.
    ///         Used by withdrawDeposit2, withdrawDepositMax2, and lendAsset2 when
    ///         tokenAddr == W0G. The manager sends W0G directly to the user, so this
    ///         function pulls it back for unwrapping.
    /// @dev    FR-QA-01: The caller MUST have approved this contract for W0G spending
    ///         BEFORE calling withdrawDeposit2/withdrawDepositMax2/lendAsset2 with W0G.
    ///         Without the allowance, the safeTransferFrom below will revert.
    ///         Frontend should ensure W0G approval to lendingInterface exists.
    function _pullUnwrapAndSendNative(uint amount) internal {
        IERC20(W0G).safeTransferFrom(msg.sender, address(this), amount);
        iw0G(W0G).withdraw(amount);
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Lending Interface: 0g Transfer Failed");
    }

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
        uint tokenBefore = IERC20(tokenAddr).balanceOf(address(this));
        IERC20(tokenAddr).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(tokenAddr).approve(lendingManager, amount);
        iLendingManager(lendingManager).assetsDeposit(
            tokenAddr,
            amount,
            msg.sender
        );
        _refundTokenDelta(tokenAddr, tokenBefore);
    }
    // Withdrawal of deposits
    function withdrawDeposit(address tokenAddr, uint amount) external nonReentrant{
        uint tokenBefore = IERC20(tokenAddr).balanceOf(address(this));
        iLendingManager(lendingManager).withdrawDeposit(
            tokenAddr,
            amount,
            msg.sender
        );
        _refundTokenDelta(tokenAddr, tokenBefore);
    }
    // lend Asset
    function lendAsset(address tokenAddr, uint amount) external nonReentrant{
        uint tokenBefore = IERC20(tokenAddr).balanceOf(address(this));
        iLendingManager(lendingManager).lendAsset(
            tokenAddr,
            amount,
            msg.sender
        );
        _refundTokenDelta(tokenAddr, tokenBefore);
    }
    // repay Loan
    function repayLoan(address tokenAddr, uint amount) external nonReentrant{
        uint tokenBefore = IERC20(tokenAddr).balanceOf(address(this));
        IERC20(tokenAddr).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(tokenAddr).approve(lendingManager, amount);
        iLendingManager(lendingManager).repayLoan(
            tokenAddr,
            amount,
            msg.sender
        );
        _refundTokenDelta(tokenAddr, tokenBefore);
    }
    //-----------------------------------------Operation 2 can use 0g---------------------------------------------
    //  Assets Deposit
    function assetsDeposit2(address tokenAddr, uint amount) external payable nonReentrant{
        uint tokenBefore = tokenAddr == W0G ? 0 : IERC20(tokenAddr).balanceOf(address(this));
        uint wrappedBefore = IERC20(W0G).balanceOf(address(this));
        uint nativeBefore = address(this).balance - msg.value;
        if (tokenAddr == W0G) {
            require(
                amount <= msg.value,
                "Lending Interface: amount should == msg.value"
            );
            iw0G(W0G).deposit{value: amount}();
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
        _refundNativeCompatible(tokenAddr, tokenBefore, wrappedBefore, nativeBefore);
    }
    // Withdrawal of deposits
    function withdrawDeposit2(address tokenAddr, uint amount) external nonReentrant{
        if (tokenAddr == W0G) {
            iLendingManager(lendingManager).withdrawDeposit(
                tokenAddr,
                amount,
                msg.sender
            );
            _pullUnwrapAndSendNative(amount);
        } else {
            uint tokenBefore = IERC20(tokenAddr).balanceOf(address(this));
            uint wrappedBefore = IERC20(W0G).balanceOf(address(this));
            uint nativeBefore = address(this).balance;
            iLendingManager(lendingManager).withdrawDeposit(
                tokenAddr,
                amount,
                msg.sender
            );
            _refundNativeCompatible(tokenAddr, tokenBefore, wrappedBefore, nativeBefore);
        }
    }
    function withdrawDepositMax2(address tokenAddr) external nonReentrant {
        address[2] memory depositAndLend = assetsDepositAndLendAddrs(tokenAddr);
        uint tokenBalance = IERC20(depositAndLend[0]).balanceOf(
            address(msg.sender)
        );
        tokenBalance = tokenBalance * (10**iDecimals(tokenAddr).decimals()) / 1 ether;
        if (tokenAddr == W0G) {
            iLendingManager(lendingManager).withdrawDeposit(
                tokenAddr,
                tokenBalance,
                msg.sender
            );
            _pullUnwrapAndSendNative(tokenBalance);
        } else {
            uint tokenBefore = IERC20(tokenAddr).balanceOf(address(this));
            uint wrappedBefore = IERC20(W0G).balanceOf(address(this));
            uint nativeBefore = address(this).balance;
            iLendingManager(lendingManager).withdrawDeposit(
                tokenAddr,
                tokenBalance,
                msg.sender
            );
            _refundNativeCompatible(tokenAddr, tokenBefore, wrappedBefore, nativeBefore);
        }
    }
    // lend Asset
    function lendAsset2(address tokenAddr, uint amount) external nonReentrant{
        if (tokenAddr == W0G) {
            iLendingManager(lendingManager).lendAsset(
                tokenAddr,
                amount,
                msg.sender
            );
            _pullUnwrapAndSendNative(amount);
        } else {
            uint tokenBefore = IERC20(tokenAddr).balanceOf(address(this));
            uint wrappedBefore = IERC20(W0G).balanceOf(address(this));
            uint nativeBefore = address(this).balance;
            iLendingManager(lendingManager).lendAsset(
                tokenAddr,
                amount,
                msg.sender
            );
            _refundNativeCompatible(tokenAddr, tokenBefore, wrappedBefore, nativeBefore);
        }
    }
    // repay Loan
    function repayLoan2(address tokenAddr, uint amount) external payable nonReentrant{
        uint tokenBefore = tokenAddr == W0G ? 0 : IERC20(tokenAddr).balanceOf(address(this));
        uint wrappedBefore = IERC20(W0G).balanceOf(address(this));
        uint nativeBefore = address(this).balance - msg.value;
        if (tokenAddr == W0G) {
            require(
                amount <= msg.value,
                "Lending Interface: amount should == msg.value"
            );
            iw0G(W0G).deposit{value: amount}();
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
        _refundNativeCompatible(tokenAddr, tokenBefore, wrappedBefore, nativeBefore);
    }
    function repayLoanMax2(address tokenAddr) external payable nonReentrant {
        uint tokenBefore = tokenAddr == W0G ? 0 : IERC20(tokenAddr).balanceOf(address(this));
        uint wrappedBefore = IERC20(W0G).balanceOf(address(this));
        uint nativeBefore = address(this).balance - msg.value;
        address[2] memory depositAndLend = assetsDepositAndLendAddrs(tokenAddr);
        uint debtNormalized = IERC20(depositAndLend[1]).balanceOf(
            address(msg.sender)
        );
        // Q-03 fix: use floor (truncation) instead of ceiling to avoid
        // overpaying one raw token unit when normalized debt has sub-raw-unit
        // dust.  Any residual dust (< 1 raw unit in value) is emitted via
        // RepayLoanMaxDust so off-chain systems can track it.
        uint tokenBackAmount = debtNormalized * (10**iDecimals(tokenAddr).decimals()) / 1 ether;
        if (tokenAddr == W0G) {
            require(
                tokenBackAmount <= msg.value,
                "Lending Interface: amount should == msg.value"
            );
            iw0G(W0G).deposit{value: tokenBackAmount}();
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
        // Emit dust event if sub-raw-unit normalized debt remains after
        // floor-based repayment (the residual is < 1 raw unit in value).
        uint remainingDebt = IERC20(depositAndLend[1]).balanceOf(msg.sender);
        if (remainingDebt > 0) {
            emit RepayLoanMaxDust(msg.sender, tokenAddr, remainingDebt);
        }
        _refundNativeCompatible(tokenAddr, tokenBefore, wrappedBefore, nativeBefore);
    }
    // ======================== contract base methods =====================
    fallback() external payable {}
    receive() external payable {}
}
