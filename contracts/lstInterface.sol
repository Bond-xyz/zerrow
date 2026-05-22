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
import "./LendingInterfaceLib.sol";

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
    // FR-M-03: Delegate to LendingInterfaceLib to reduce bytecode size.
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
        return LendingInterfaceLib.computeHealthFactorEstimate(
            user, token, amount, operator, lendingManager, oracleAddr, lCoreAddr
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

    // FR-M-03: Delegate to LendingInterfaceLib to reduce bytecode size.
    // Also incorporates FR-L-02 fix (correct RIM key) via the library.
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

    // FR-M-03: Delegate to LendingInterfaceLib to reduce bytecode size.
    function userProfile(
        address user
    ) public view returns (int netWorth, int netApy) {
        return LendingInterfaceLib.computeUserProfile(user, lendingManager, oracleAddr);
    }

    // FR-M-03: Delegate to LendingInterfaceLib to reduce bytecode size.
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

    // FR-M-03: Delegate to LendingInterfaceLib to reduce bytecode size.
    function tokenLiquidateEstimate(address user,
                            address liquidateToken,
                            address depositToken) public view returns(uint[2] memory maxAmounts){
        return LendingInterfaceLib.computeTokenLiquidateEstimate(
            user, liquidateToken, depositToken, lendingManager, oracleAddr
        );
    }

    //=======================================stake for Gimo=============================================
    function gimoStake() public payable nonReentrant {
        uint nativeBefore = address(this).balance - msg.value;
        uint gTokenBefore = IERC20(gToken).balanceOf(address(this));

        iLstGimo(lstGimo).stake{value: msg.value}("zerrow");

        _refundTokenDelta(gToken, gTokenBefore);
        _refundNativeDelta(nativeBefore);
    }
    function gimoUnstake(uint256 _lsdTokenAmount) public nonReentrant {
        IERC20(gToken).safeTransferFrom(msg.sender, address(this), _lsdTokenAmount);
        uint nativeBefore = address(this).balance;
        uint gTokenBefore = IERC20(gToken).balanceOf(address(this));

        iLstGimo(lstGimo).unstake(_lsdTokenAmount);

        _refundTokenDelta(gToken, gTokenBefore);
        _refundNativeDelta(nativeBefore);
    }
    function getRate() public view returns (uint256){
        return iLstGimo(lstGimo).getRate();
    }
    function withdraw() public nonReentrant {
        uint nativeBefore = address(this).balance;

        iLstGimo(lstGimo).withdraw();

        _refundNativeDelta(nativeBefore);
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
                uint depositedGTokens;
                if(stakeToken == gToken) {
                    require(currentAmount <= address(this).balance,"Insufficient balance");
                    // Stake current amount
                    iLstGimo(lstGimo).stake{value: currentAmount}("zerrow");
                    // Get received gTokens
                    depositedGTokens = IERC20(gToken).balanceOf(address(this)) - stakeBefore;
                    require(depositedGTokens > 0, "No gTokens received");
                    // Approve and deposit gTokens
                    IERC20(gToken).approve(lendingManager, depositedGTokens);
                    iLendingManager(lendingManager).assetsDeposit( gToken, depositedGTokens, msg.sender);
                }else{
                    revert("Need be a 0g Lst Token");
                }
                // Size borrow from realized gToken collateral value, not native input
                uint realizedCollateralValue = depositedGTokens * iLstGimo(lstGimo).getRate() / 1 ether;
                uint lendAmount = (realizedCollateralValue * percentage) / 10000;
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
