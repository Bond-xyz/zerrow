// SPDX-License-Identifier: Business Source License 1.1
// First Release Time : 2025.03.30

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/islcoracle.sol";
import "./interfaces/iDecimals.sol";

import "./interfaces/iCoinFactory.sol";
import "./interfaces/iDepositOrLoanCoin.sol";
import "./interfaces/iLendingCoreAlgorithm.sol";
import "./interfaces/iLendingVaults.sol";
import "./interfaces/iUserFlashLoan.sol";
import "./LendingManagerLib.sol";

/// @custom:oz-upgrades-unsafe-allow constructor
contract lendingManager is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    uint public constant ONE_YEAR = 31536000;
    uint public constant UPPER_SYSTEM_LIMIT = 10000;
    uint public constant LIQUIDATION_CLOSE_FACTOR = 5000;

    uint    public slcUnsecuredIssuancesAmount;

    address public oracleAddr;
    address public coinFactory;
    address public lendingVault;
    address public coreAlgorithm;

    address public setter;
    address newsetter;

    uint    public normalFloorOfHealthFactor;
    uint    public homogeneousFloorOfHealthFactor;

    address public flashLoanFeesAddress;

    //  Assets Init:          USDT  USDC  BTC   ETH   0g
    //  MaximumLTV:            95%   95%  80%   75%  50%
    //  LiqPenalty:             3%    3%   5%    5%  10%
    //maxLendingAmountInRIM:     0     0    0     0   1k
    //bestLendingRatio:        76%   76%  70%   70%  50%
    //lendingModeNum:            2     2    4     5    3
    //homogeneousModeLTV:      97%   97%  95%   95%  60%
    //bestDepositInterestRate   4%    4%  4.5% 4.6%   6%


    struct licensedAsset{
        address assetAddr;
        uint    maximumLTV;               // loan-to-value (LTV) ratio
        uint    liquidationPenalty;       // MAX = UPPER_SYSTEM_LIMIT/5 ,default is 500(5%)
        uint    bestLendingRatio;         // MAX = UPPER_SYSTEM_LIMIT , setting NOT more than 9000
        uint    bestDepositInterestRate ; // MAX = UPPER_SYSTEM_LIMIT , setting NOT more than 1000
        uint    maxLendingAmountInRIM;    // default is 0, means no limits; if > 0, have limits : 1 ether = 1 slc
        uint    reserveFactor;            // default is 1000, (10%)
        uint8   lendingModeNum;           // Risk Isolation Mode: 1 ;  USDT  USDC : 2  ;
        uint    homogeneousModeLTV;       // USDT  USDC : 97%  ;
    }

    struct assetInfo{
        uint    latestDepositCoinValue;
        uint    latestLendingCoinValue;
        uint    latestDepositInterest;
        uint    latestLendingInterest;
        uint    latestTimeStamp;
    }

    mapping (address=>bool) public xInterface;
    address[] public interfaceArray;
    mapping(address => mapping(address => bool)) public interfaceApproval;

    mapping(address => licensedAsset) public licensedAssets;
    mapping(address => address[2]) public assetsDepositAndLend;
    address[] public assetsSerialNumber;

    mapping(address => assetInfo) public assetInfos;
    mapping(address => mapping(address => uint)) public userRIMAssetsLendingNetAmount;
    mapping(address => uint) public riskIsolationModeLendingNetAmount; //RIM  Risk Isolation Mode
    mapping(address => address) public userRIMAssetsAddress;
    address public riskIsolationModeAcceptAssets;
    mapping(address => uint8) public userMode;

    address public guardian;

    /// @dev Storage gap for future upgrades
    uint256[49] private __gap;

    //----------------------------custom errors ----------------------------
    error OnlySetter();
    error NotWhitelistedInterface();
    error InterfaceNotApproved();
    error ZeroAddress();
    error ZeroAmount();
    error TokenNotLicensed();
    error AssetAlreadyRegistered();
    error AssetNotRegistered();
    error TooManyAssets();
    error OutstandingPositions();
    error CannotTransferToZero();
    error PermissionForbidden();
    error NormalFloorTooLow();
    error HomogeneousFloorTooLow();
    error HomogeneousFloorMustBeBelowNormal();
    error WrongRIMToken();
    error WrongHomogeneousMode();
    error Mode1NeedsRIMAsset();
    error RIMAssetOnlyInMode1();
    error UnknownMode();
    error PositionsNotCleared();
    error VaultInsufficient();
    error UserBalanceInsufficient();
    error RIMBorrowLimitExceeded();
    error BorrowExceeds99Pct();
    error InsufficientFunds();
    error BorrowTokenNotLicensed();
    error FlashLoanFeesNotSet();
    error SelfLiquidation();
    error DebtTokenNotLicensed();
    error CollateralTokenNotLicensed();
    error LiquidationMustImproveHF();
    error NotAfterBeforeUpdate();
    error NotSetterOrGuardian();
    error RepayExceedsDebt();

    //----------------------------- event -----------------------------
    event AssetsDeposit(address indexed tokenAddr, uint amount, address user);
    event WithdrawDeposit(address indexed tokenAddr, uint amount, address user);
    event LendAsset(address indexed tokenAddr, uint amount, address user);
    event RepayLoan(address indexed tokenAddr,uint amount, address user);
    event LicensedAssetsSetup(address indexed _asset,
                                uint _maxLTV,
                                uint _liqPenalty,
                                uint _maxLendingAmountInRIM,
                                uint _bestLendingRatio,
                                uint    reserveFactor,
                                uint8 _lendingModeNum,
                                uint _homogeneousModeLTV,
                                uint _bestDepositInterestRate) ;
    event UserModeSetting(address indexed user,uint8 _mode,address _userRIMAssetsAddress);
    event InterfaceApproval(address indexed user,address indexed iface,bool approved);
    event InterfaceSetup(address _xInterface, bool _ToF);
    event FloorOfHealthFactorSetup(uint normal, uint homogeneous);
    event DepositAndLoanInterest(address indexed token,
                                 uint latestDepositInterest,
                                 uint latestLoanInterest,
                                 uint latestTimeStamp);
    event BadDebtDeduction(address user,uint blockTimestamp);
    event Liquidation(address indexed user, address indexed liquidator, address liquidateToken, address depositToken, uint liquidateAmount, uint seizedAmount);
    event LicensedAssetsDeregistered(address indexed _asset);
    //------------------------------------------------------------------

    function _requireSetter() internal view {
        if (msg.sender != setter) revert OnlySetter();
    }

    function _requireInterface(address user) internal view {
        if (msg.sender != user) {
            if (!xInterface[msg.sender]) revert NotWhitelistedInterface();
            if (!interfaceApproval[user][msg.sender]) revert InterfaceNotApproved();
        }
    }

    /// @dev Disable initializer on implementation contract
    constructor() initializer {}

    /// @notice Replaces constructor for proxy deployment
    function initialize(address _setter) public initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        setter = _setter;
        normalFloorOfHealthFactor = 1.2 ether;
        homogeneousFloorOfHealthFactor = 1.03 ether;
    }

    /// @dev Required by UUPSUpgradeable
    function _authorizeUpgrade(address) internal override {
        _requireSetter();
    }

    /// @notice Pause the contract
    function pause() external {
        if (msg.sender != setter && msg.sender != guardian) revert NotSetterOrGuardian();
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external {
        _requireSetter();
        _unpause();
    }

    function setFlashLoanFeesAddress(address _flashLoanFeesAddress) external {
        _requireSetter();
        flashLoanFeesAddress = _flashLoanFeesAddress;
    }

    function setGuardian(address _guardian) external {
        _requireSetter();
        guardian = _guardian;
    }

    function transferSetter(address _set) external {
        _requireSetter();
        if (_set == address(0)) revert CannotTransferToZero();
        newsetter = _set;
    }
    function acceptSetter(bool _TorF) external {
        if (msg.sender != newsetter) revert PermissionForbidden();
        if(_TorF){
            setter = newsetter;
        }
        newsetter = address(0);
    }

    function setup( address _coinFactory,
                    address _lendingVault,
                    address _riskIsolationModeAcceptAssets,
                    address _coreAlgorithm,
                    address _oracleAddr ) external {
        _requireSetter();
        if (_coinFactory == address(0) || _lendingVault == address(0)
            || _coreAlgorithm == address(0) || _oracleAddr == address(0)) revert ZeroAddress();
        coinFactory = _coinFactory;
        oracleAddr = _oracleAddr;
        lendingVault = _lendingVault;
        coreAlgorithm = _coreAlgorithm;
        riskIsolationModeAcceptAssets = _riskIsolationModeAcceptAssets;
    }

    function xInterfacesetting(address _xInterface, bool _ToF)external {
        _requireSetter();
        uint lengthTemp = interfaceArray.length;
        if(_ToF == false){
            xInterface[_xInterface] = false;
            for(uint i = 0; i != lengthTemp; i++){
                if(interfaceArray[i] == _xInterface){
                    interfaceArray[i] = interfaceArray[lengthTemp -1];
                    interfaceArray.pop();
                    break;
                }
            }
        }else if(xInterface[_xInterface] == false){
            xInterface[_xInterface] = true;
            interfaceArray.push(_xInterface);
        }
        emit InterfaceSetup( _xInterface, _ToF);
    }

    function setInterfaceApproval(bool approved) external {
        uint lengthTemp = interfaceArray.length;
        for(uint i = 0; i != lengthTemp; i++){
            interfaceApproval[msg.sender][interfaceArray[i]] = approved;
            emit InterfaceApproval(msg.sender, interfaceArray[i], approved);
        }
    }

    function setFloorOfHealthFactor(uint normal, uint homogeneous) external {
        _requireSetter();
        if (normal < 1 ether) revert NormalFloorTooLow();
        if (homogeneous < 1 ether) revert HomogeneousFloorTooLow();
        if (normal <= homogeneous) revert HomogeneousFloorMustBeBelowNormal();
        normalFloorOfHealthFactor = normal;
        homogeneousFloorOfHealthFactor = homogeneous;
        emit FloorOfHealthFactorSetup( normal, homogeneous);
    }

    function coinMintLockerSetup(address coinAddr, bool tOF) external {
        _requireSetter();
        iDepositOrLoanCoin(coinAddr).mintLockerSetup(tOF);
    }

    function licensedAssetsDeregister(address _asset) external {
        _requireSetter();
        if (licensedAssets[_asset].assetAddr != _asset) revert AssetNotRegistered();
        if (IERC20(assetsDepositAndLend[_asset][0]).totalSupply() != 0
            || IERC20(assetsDepositAndLend[_asset][1]).totalSupply() != 0) revert OutstandingPositions();
        delete licensedAssets[_asset];
        delete assetsDepositAndLend[_asset];
        for (uint i = 0; i < assetsSerialNumber.length; i++) {
            if (assetsSerialNumber[i] == _asset) {
                assetsSerialNumber[i] = assetsSerialNumber[assetsSerialNumber.length - 1];
                assetsSerialNumber.pop();
                break;
            }
        }
        emit LicensedAssetsDeregistered(_asset);
    }

    function licensedAssetsRegister(address _asset,
                                    uint  _maxLTV,
                                    uint  _liqPenalty,
                                    uint  _maxLendingAmountInRIM,
                                    uint  _bestLendingRatio,
                                    uint  _reserveFactor,
                                    uint8 _lendingModeNum,
                                    uint  _homogeneousModeLTV,
                                    uint  _bestDepositInterestRate,
                                    bool  _isNew) public {
        _requireSetter();
        LendingManagerLib.validateAssetParams(_maxLTV, _liqPenalty, _bestLendingRatio, _homogeneousModeLTV, _bestDepositInterestRate, _reserveFactor);
        if (licensedAssets[_asset].assetAddr != address(0)) revert AssetAlreadyRegistered();
        if (assetsSerialNumber.length >= 49) revert TooManyAssets();
        assetsSerialNumber.push(_asset);
        _setAssetParams(_asset, _maxLTV, _liqPenalty, _maxLendingAmountInRIM, _bestLendingRatio, _reserveFactor, _lendingModeNum, _homogeneousModeLTV, _bestDepositInterestRate);

        if(_isNew){
            assetsDepositAndLend[_asset] = iCoinFactory(coinFactory).createDeAndLoCoin(_asset);
        }else{
            assetsDepositAndLend[_asset][0] = iCoinFactory(coinFactory).getDepositCoin(_asset);
            assetsDepositAndLend[_asset][1] = iCoinFactory(coinFactory).getLoanCoin(_asset);
        }
    }

    function licensedAssetsReset(address _asset,
                                uint _maxLTV,
                                uint _liqPenalty,
                                uint _maxLendingAmountInRIM,
                                uint _bestLendingRatio,
                                uint  _reserveFactor,
                                uint8 _lendingModeNum,
                                uint _homogeneousModeLTV,
                                uint _bestDepositInterestRate) public {
        _requireSetter();
        if (licensedAssets[_asset].assetAddr != _asset) revert AssetNotRegistered();
        LendingManagerLib.validateAssetParams(_maxLTV, _liqPenalty, _bestLendingRatio, _homogeneousModeLTV, _bestDepositInterestRate, _reserveFactor);
        _beforeUpdate(_asset);
        _setAssetParams(_asset, _maxLTV, _liqPenalty, _maxLendingAmountInRIM, _bestLendingRatio, _reserveFactor, _lendingModeNum, _homogeneousModeLTV, _bestDepositInterestRate);
        _assetsValueUpdate(_asset);
    }

    function _setAssetParams(address _asset, uint _maxLTV, uint _liqPenalty, uint _maxLendingAmountInRIM, uint _bestLendingRatio, uint _reserveFactor, uint8 _lendingModeNum, uint _homogeneousModeLTV, uint _bestDepositInterestRate) internal {
        licensedAsset storage la = licensedAssets[_asset];
        la.assetAddr = _asset;
        la.maximumLTV = _maxLTV;
        la.liquidationPenalty = _liqPenalty;
        la.maxLendingAmountInRIM = _maxLendingAmountInRIM;
        la.bestLendingRatio = _bestLendingRatio;
        la.lendingModeNum = _lendingModeNum;
        la.homogeneousModeLTV = _homogeneousModeLTV;
        la.bestDepositInterestRate = _bestDepositInterestRate;
        la.reserveFactor = _reserveFactor;
        emit LicensedAssetsSetup(_asset, _maxLTV, _liqPenalty, _maxLendingAmountInRIM, _bestLendingRatio, _reserveFactor, _lendingModeNum, _homogeneousModeLTV, _bestDepositInterestRate);
    }

    function userModeSetting(uint8 _mode,address _userRIMAssetsAddress, address user) public {
        _requireInterface(user);
        LendingManagerLib.AssetSnapshot[] memory s = _loadAssetSnapshots();
        if (LendingManagerLib.totalLendingValue(s, user, oracleAddr) != 0
            || LendingManagerLib.totalDepositValue(s, user, oracleAddr) != 0) revert PositionsNotCleared();
        if (_mode > 1 && !LendingManagerLib.modeIsRegistered(s, _mode)) revert UnknownMode();

        if(_mode == 1){
            if (licensedAssets[_userRIMAssetsAddress].maxLendingAmountInRIM == 0) revert Mode1NeedsRIMAsset();
        } else {
            if (_userRIMAssetsAddress != address(0)) revert RIMAssetOnlyInMode1();
        }

        userMode[user] = _mode;
        userRIMAssetsAddress[user] = _userRIMAssetsAddress;
        emit UserModeSetting(user, _mode, _userRIMAssetsAddress);
    }

    //----------------------------- Internal Helpers ------------------------------------
    function _loadAssetSnapshots() internal view returns (LendingManagerLib.AssetSnapshot[] memory s) {
        uint len = assetsSerialNumber.length;
        s = new LendingManagerLib.AssetSnapshot[](len);
        for (uint i = 0; i < len; i++) {
            address asset = assetsSerialNumber[i];
            licensedAsset storage la = licensedAssets[asset];
            s[i].asset = asset;
            s[i].depositCoin = assetsDepositAndLend[asset][0];
            s[i].loanCoin = assetsDepositAndLend[asset][1];
            s[i].maximumLTV = la.maximumLTV;
            s[i].homogeneousModeLTV = la.homogeneousModeLTV;
            s[i].liquidationPenalty = la.liquidationPenalty;
            s[i].maxLendingAmountInRIM = la.maxLendingAmountInRIM;
            s[i].lendingModeNum = la.lendingModeNum;
        }
    }

    function _requireLicensed(address tokenAddr) internal view {
        if (licensedAssets[tokenAddr].assetAddr != tokenAddr) revert TokenNotLicensed();
    }

    function _requireNonZeroAmount(uint amount) internal pure {
        if (amount == 0) revert ZeroAmount();
    }

    //----------------------------- View Function------------------------------------
    function assetsBaseInfo(address token) public view returns(uint maximumLTV,
                                                               uint liquidationPenalty,
                                                               uint maxLendingAmountInRIM,
                                                               uint bestLendingRatio,
                                                               uint lendingModeNum,
                                                               uint homogeneousModeLTV,
                                                               uint bestDepositInterestRate){
        licensedAsset storage a = licensedAssets[token];
        return (a.maximumLTV, a.liquidationPenalty, a.maxLendingAmountInRIM,
                a.bestLendingRatio, a.lendingModeNum, a.homogeneousModeLTV, a.bestDepositInterestRate);
    }
    function assetsReserveFactor(address token) public view returns(uint reserveFactor){
        return (licensedAssets[token].reserveFactor);
    }

    function assetsTimeDependentParameter(address token) public view returns(uint latestDepositCoinValue,
                                                                             uint latestLendingCoinValue,
                                                                             uint latestDepositInterest,
                                                                             uint latestLendingInterest){
        assetInfo storage a = assetInfos[token];
        return (a.latestDepositCoinValue, a.latestLendingCoinValue, a.latestDepositInterest, a.latestLendingInterest);
    }

    function assetsDepositAndLendAddrs(address token) public view returns(address[2] memory addrs){
        return assetsDepositAndLend[token];
    }

    function licensedAssetAmount() public view returns(uint assetLength){
        assetLength = assetsSerialNumber.length;
    }

    function _rawToNormalized(address tokenAddr, uint amountRaw) internal view returns (uint amountNorm18) {
        amountNorm18 = amountRaw * 1 ether / (10 ** iDecimals(tokenAddr).decimals());
    }

    function _normalizedToRaw(address tokenAddr, uint amountNorm18) internal view returns (uint amountRaw) {
        amountRaw = amountNorm18 * (10 ** iDecimals(tokenAddr).decimals()) / 1 ether;
    }

    function VaultTokensAmount(address tokenAddr) public view returns(uint maxAmount){
        maxAmount = _rawToNormalized(tokenAddr, IERC20(tokenAddr).balanceOf(lendingVault));
    }

    function userDepositAndLendingValue(address user) public view returns(uint _amountDeposit,uint _amountLending){
        LendingManagerLib.AssetSnapshot[] memory s = _loadAssetSnapshots();
        return LendingManagerLib.depositAndLendingValue(s, user, userMode[user], oracleAddr);
    }

    function viewUsersHealthFactor(address user) public view returns(uint userHealthFactor){
        LendingManagerLib.AssetSnapshot[] memory s = _loadAssetSnapshots();
        return LendingManagerLib.healthFactor(s, user, userMode[user], oracleAddr);
    }

    function getCoinValues(address token) public view returns(uint[2] memory currentValue){
        assetInfo storage a = assetInfos[token];
        return LendingManagerLib.coinValues(
            a.latestDepositCoinValue, a.latestLendingCoinValue,
            a.latestDepositInterest, a.latestLendingInterest, a.latestTimeStamp
        );
    }

    function userAssetOverview(address user) public view returns(address[] memory tokens, uint[] memory _amountDeposit, uint[] memory _amountLending){
        LendingManagerLib.AssetSnapshot[] memory s = _loadAssetSnapshots();
        return LendingManagerLib.assetOverview(s, user);
    }

    //---------------------------- borrow & lend  Function----------------------------
    function _beforeUpdate(address token) internal returns(uint[2] memory latestValues){
        latestValues = getCoinValues(token);
        assetInfo storage a = assetInfos[token];
        a.latestDepositCoinValue = latestValues[0];
        a.latestLendingCoinValue = latestValues[1];
        a.latestTimeStamp = block.timestamp;
    }

    function _assetsValueUpdate(address token) internal returns(uint[2] memory latestInterest){
        assetInfo storage a = assetInfos[token];
        if (a.latestTimeStamp != block.timestamp) revert NotAfterBeforeUpdate();
        latestInterest = iLendingCoreAlgorithm(coreAlgorithm).assetsValueUpdate(token);
        a.latestDepositInterest = latestInterest[0];
        a.latestLendingInterest = latestInterest[1];
        emit DepositAndLoanInterest( token, latestInterest[0], latestInterest[1], block.timestamp);
    }

    function _socializeBadDebt(address user) internal {
        LendingManagerLib.AssetSnapshot[] memory s = _loadAssetSnapshots();
        (uint badDebtValue, uint[] memory burnAmounts) = LendingManagerLib.computeBadDebt(s, user, oracleAddr);
        if (badDebtValue == 0) return;

        slcUnsecuredIssuancesAmount += badDebtValue;
        for (uint i = 0; i < s.length; i++) {
            if (burnAmounts[i] > 0) {
                iDepositOrLoanCoin(s[i].loanCoin).burnCoin(user, burnAmounts[i]);

                uint totalDeposits = iDepositOrLoanCoin(s[i].depositCoin).totalSupply();
                if (totalDeposits > 0) {
                    assetInfo storage a = assetInfos[s[i].asset];
                    uint oldValue = a.latestDepositCoinValue;
                    if (oldValue == 0) { oldValue = 1 ether; }
                    if (burnAmounts[i] >= totalDeposits) {
                        a.latestDepositCoinValue = 0;
                        a.latestDepositInterest = 0;
                    } else {
                        a.latestDepositCoinValue = oldValue * (totalDeposits - burnAmounts[i]) / totalDeposits;
                        a.latestDepositInterest = a.latestDepositInterest * (totalDeposits - burnAmounts[i]) / totalDeposits;
                    }
                }
            }
        }
        emit BadDebtDeduction(user, block.timestamp);
    }

    function _checkHealthFactor(address user) internal view {
        uint factor = viewUsersHealthFactor(user);
        LendingManagerLib.requireHealthy(
            factor,
            userMode[user],
            normalFloorOfHealthFactor,
            homogeneousFloorOfHealthFactor
        );
    }

    function _updateRIMAccounting(address user, address tokenAddr, uint amountNormalize, bool isLend) internal {
        address rimAsset = userRIMAssetsAddress[user];
        uint maxRIM = licensedAssets[rimAsset].maxLendingAmountInRIM;
        if (!isLend) {
            if (maxRIM == 0) revert WrongRIMToken();
        }
        if (tokenAddr != riskIsolationModeAcceptAssets) revert WrongRIMToken();
        uint currentBal = IERC20(assetsDepositAndLend[riskIsolationModeAcceptAssets][1]).balanceOf(user);
        uint tempAmount = isLend ? currentBal + amountNormalize : currentBal - amountNormalize;
        riskIsolationModeLendingNetAmount[rimAsset] = riskIsolationModeLendingNetAmount[rimAsset]
                                                     - userRIMAssetsLendingNetAmount[user][tokenAddr]
                                                     + tempAmount;
        userRIMAssetsLendingNetAmount[user][tokenAddr] = tempAmount;
        if (isLend && riskIsolationModeLendingNetAmount[rimAsset] > maxRIM) revert RIMBorrowLimitExceeded();
    }

    function _checkDepositMode(address tokenAddr, address user) internal view {
        if(userMode[user] == 0){
            if (licensedAssets[tokenAddr].maxLendingAmountInRIM != 0) revert WrongRIMToken();
        }else if(userMode[user] == 1){
            if (tokenAddr != userRIMAssetsAddress[user]) revert WrongRIMToken();
        }else {
            if (licensedAssets[tokenAddr].lendingModeNum != userMode[user]) revert WrongHomogeneousMode();
        }
    }

    //  Assets Deposit
    function assetsDeposit(address tokenAddr, uint amount, address user) public whenNotPaused nonReentrant {
        _requireInterface(user);
        uint amountNormalize = _rawToNormalized(tokenAddr, amount);

        _requireNonZeroAmount(amount);
        _requireLicensed(tokenAddr);
        _checkDepositMode(tokenAddr, user);

        _beforeUpdate(tokenAddr);
        IERC20(tokenAddr).safeTransferFrom(msg.sender,lendingVault,amount);
        iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][0]).mintCoin(user,amountNormalize);
        _assetsValueUpdate(tokenAddr);
        emit AssetsDeposit(tokenAddr, amount, user);
    }

    // Withdrawal of deposits
    function withdrawDeposit(address tokenAddr, uint amount, address user) public whenNotPaused nonReentrant {
        _requireInterface(user);
        uint amountNormalize = _rawToNormalized(tokenAddr, amount);
        uint amountTokenMax = iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][0]).balanceOf(user);

        _requireNonZeroAmount(amount);
        _requireLicensed(tokenAddr);
        if (VaultTokensAmount(tokenAddr) < amountNormalize) revert VaultInsufficient();
        if (amountTokenMax < amountNormalize) revert UserBalanceInsufficient();
        if(amountTokenMax - amountNormalize < _rawToNormalized(tokenAddr, 1)) {
            amountNormalize = amountTokenMax;
        }

        iLendingVaults(lendingVault).vaultsERC20Approve(tokenAddr, amount);
        _beforeUpdate(tokenAddr);
        IERC20(tokenAddr).safeTransferFrom(lendingVault,user,amount);
        iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][0]).burnCoin(user,amountNormalize);
        _assetsValueUpdate(tokenAddr);

        _checkHealthFactor(user);
        emit WithdrawDeposit(tokenAddr, amount, user);
    }

    // lend Asset
    function lendAsset(address tokenAddr, uint amount, address user) public whenNotPaused nonReentrant {
        _requireInterface(user);
        uint amountNormalize = _rawToNormalized(tokenAddr, amount);

        _requireNonZeroAmount(amount);
        _requireLicensed(tokenAddr);
        if (VaultTokensAmount(tokenAddr) < amountNormalize) revert VaultInsufficient();

        if(userMode[user] == 1){
            _updateRIMAccounting(user, tokenAddr, amountNormalize, true);
        }
        if(userMode[user] > 1){
            if (licensedAssets[tokenAddr].lendingModeNum != userMode[user]) revert WrongHomogeneousMode();
        }
        _beforeUpdate(tokenAddr);
        iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][1]).mintCoin(user,amountNormalize);
        iLendingVaults(lendingVault).vaultsERC20Approve(tokenAddr, amount);
        IERC20(tokenAddr).safeTransferFrom(lendingVault, user,amount);
        _assetsValueUpdate(tokenAddr);

        _checkHealthFactor(user);
        if (IERC20(assetsDepositAndLend[tokenAddr][0]).totalSupply() * 99 / 100 < IERC20(assetsDepositAndLend[tokenAddr][1]).totalSupply()) revert BorrowExceeds99Pct();
        emit LendAsset(tokenAddr, amount, user);
    }

    // repay Loan
    function repayLoan(address tokenAddr,uint amount, address user) public whenNotPaused nonReentrant {
        _requireInterface(user);
        uint amountNormalize = _rawToNormalized(tokenAddr, amount);
        uint amountTokenMax = iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][1]).balanceOf(user);

        _requireNonZeroAmount(amount);
        _requireLicensed(tokenAddr);
        if(amountNormalize > amountTokenMax){
            if(amountNormalize - amountTokenMax >= _rawToNormalized(tokenAddr, 1)) revert RepayExceedsDebt();
            amountNormalize = amountTokenMax;
        }

        if(userMode[user] == 1){
            _updateRIMAccounting(user, tokenAddr, amountNormalize, false);
        }
        _beforeUpdate(tokenAddr);

        iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][1]).burnCoin(user,amountNormalize);
        IERC20(tokenAddr).safeTransferFrom(msg.sender,lendingVault,amount);
        _assetsValueUpdate(tokenAddr);
        emit RepayLoan(tokenAddr, amount, user);
    }

    //------------------------------------------------------------------------------
    function executeFlashLoan(address useTokenAddr,
                              address borrowTokenAddr,
                              uint    borrowAmount,
                              address flashLoanUserContractAddr,
                              address user) public whenNotPaused nonReentrant {
        _requireInterface(user);
        _requireNonZeroAmount(borrowAmount);
        _requireLicensed(useTokenAddr);
        if (licensedAssets[borrowTokenAddr].assetAddr != borrowTokenAddr) revert BorrowTokenNotLicensed();
        if (flashLoanFeesAddress == address(0)) revert FlashLoanFeesNotSet();

        uint userNeedPaid = LendingManagerLib.computeFlashLoanFee(
            _rawToNormalized(borrowTokenAddr, borrowAmount),
            iDepositOrLoanCoin(assetsDepositAndLend[useTokenAddr][0]).balanceOf(user),
            iSlcOracle(oracleAddr).getPrice(useTokenAddr),
            iSlcOracle(oracleAddr).getPrice(borrowTokenAddr),
            VaultTokensAmount(useTokenAddr)
        );
        uint userNeedPaidRaw = _normalizedToRaw(useTokenAddr, userNeedPaid);
        iLendingVaults(lendingVault).vaultsERC20Approve(useTokenAddr, userNeedPaidRaw);
        IERC20(useTokenAddr).safeTransferFrom(lendingVault, flashLoanFeesAddress, userNeedPaidRaw);
        iDepositOrLoanCoin(assetsDepositAndLend[useTokenAddr][0]).burnCoin(user, userNeedPaid);

        _beforeUpdate(useTokenAddr);
        iLendingVaults(lendingVault).vaultsERC20Approve(borrowTokenAddr, borrowAmount);
        IERC20(borrowTokenAddr).safeTransferFrom(lendingVault, user, borrowAmount);
        iUserFlashLoan(flashLoanUserContractAddr).executeOperation(borrowTokenAddr, borrowAmount, '');
        IERC20(borrowTokenAddr).safeTransferFrom(user, lendingVault, borrowAmount);
        _assetsValueUpdate(useTokenAddr);

        _checkHealthFactor(user);
    }

    //------------------------------ Liquidate Function------------------------------
    function _tokenLiquidate(address user,
                             address liquidateToken,
                             uint    liquidateAmount,
                             address depositToken,
                             bool receiveDepositCoin) internal returns(uint usedAmount) {
        uint liquidateAmountNormalize = _rawToNormalized(liquidateToken, liquidateAmount);
        _beforeUpdate(liquidateToken);
        _beforeUpdate(depositToken);

        _requireNonZeroAmount(liquidateAmountNormalize);
        if (msg.sender == user) revert SelfLiquidation();
        if (licensedAssets[liquidateToken].assetAddr != liquidateToken) revert DebtTokenNotLicensed();
        licensedAsset storage depAsset = licensedAssets[depositToken];
        if (depAsset.assetAddr != depositToken) revert CollateralTokenNotLicensed();

        uint healthFactorBefore;
        uint seizedCollateralNormalize;
        (healthFactorBefore, seizedCollateralNormalize) = LendingManagerLib.previewLiquidation(
            LendingManagerLib.LiquidationParams({
                user: user,
                liquidateToken: liquidateToken,
                liquidateAmountNormalize: liquidateAmountNormalize,
                depositToken: depositToken,
                liquidateLoanCoin: assetsDepositAndLend[liquidateToken][1],
                depositDepositCoin: assetsDepositAndLend[depositToken][0],
                liquidationPenalty: depAsset.liquidationPenalty,
                oracle: oracleAddr,
                currentHF: viewUsersHealthFactor(user)
            })
        );

        IERC20(liquidateToken).safeTransferFrom(msg.sender, lendingVault, liquidateAmount);
        iDepositOrLoanCoin(assetsDepositAndLend[liquidateToken][1]).burnCoin(user,liquidateAmountNormalize);
        iDepositOrLoanCoin(assetsDepositAndLend[depositToken][0]).burnCoin(user,seizedCollateralNormalize);

        usedAmount = _normalizedToRaw(depositToken, seizedCollateralNormalize);
        if (receiveDepositCoin) {
            iDepositOrLoanCoin(assetsDepositAndLend[depositToken][0]).mintCoin(msg.sender,seizedCollateralNormalize);
        } else {
            iLendingVaults(lendingVault).vaultsERC20Approve(depositToken, usedAmount);
            IERC20(depositToken).safeTransferFrom(lendingVault, msg.sender, usedAmount);
        }

        _assetsValueUpdate(liquidateToken);
        _assetsValueUpdate(depositToken);
        _socializeBadDebt(user);

        uint healthFactorAfter = viewUsersHealthFactor(user);
        if (LendingManagerLib.totalLendingValue(_loadAssetSnapshots(), user, oracleAddr) != 0
            && healthFactorAfter < 1 ether
            && healthFactorAfter <= healthFactorBefore) revert LiquidationMustImproveHF();

        emit Liquidation(user, msg.sender, liquidateToken, depositToken, liquidateAmount, usedAmount);
    }

    function tokenLiquidate(address user,
                            address liquidateToken,
                            uint    liquidateAmount,
                            address depositToken) public whenNotPaused nonReentrant returns(uint usedAmount) {
        usedAmount = _tokenLiquidate(user, liquidateToken, liquidateAmount, depositToken, false);
    }

    function tokenLiquidateToDepositCoin(address user,
                                         address liquidateToken,
                                         uint    liquidateAmount,
                                         address depositToken) public whenNotPaused nonReentrant returns(uint usedAmount) {
        usedAmount = _tokenLiquidate(user, liquidateToken, liquidateAmount, depositToken, true);
    }

}
