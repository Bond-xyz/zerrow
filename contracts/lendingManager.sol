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

/// @custom:oz-upgrades-unsafe-allow constructor
contract lendingManager is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    uint public constant ONE_YEAR = 31536000;
    uint public constant UPPER_SYSTEM_LIMIT = 10000;

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

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;

    //----------------------------modifier ----------------------------
    modifier onlySetter() {
        require(msg.sender == setter, 'Lending Manager: Only Setter Use');
        _;
    }
    modifier onlyInterface(address user) {
        if (msg.sender != user) {
            require(xInterface[msg.sender],"Lending Manager: Not whitelisted interface" );
            require(interfaceApproval[user][msg.sender],"Lending Manager: User has not approved interface");
        }
        _;
    }

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
    //------------------------------------------------------------------

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
        require(msg.sender == setter, "not setter");
    }

    /// @notice Pause the contract
    function pause() external onlySetter {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlySetter {
        _unpause();
    }

    function setFlashLoanFeesAddress(address _flashLoanFeesAddress) external onlySetter{
        flashLoanFeesAddress = _flashLoanFeesAddress;
    }

    function transferSetter(address _set) external onlySetter{
        require(_set != address(0), "Lending Manager: Cannot transfer to zero");
        newsetter = _set;
    }
    function acceptSetter(bool _TorF) external {
        require(msg.sender == newsetter, 'Lending Manager: Permission FORBIDDEN');
        if(_TorF){
            setter = newsetter;
        }
        newsetter = address(0);
    }

    function setup( address _coinFactory,
                    address _lendingVault,
                    address _riskIsolationModeAcceptAssets,
                    address _coreAlgorithm,
                    address _oracleAddr ) external onlySetter{
        require(_coinFactory != address(0), "Lending Manager: Zero address");
        require(_lendingVault != address(0), "Lending Manager: Zero address");
        require(_coreAlgorithm != address(0), "Lending Manager: Zero address");
        require(_oracleAddr != address(0), "Lending Manager: Zero address");
        coinFactory = _coinFactory;
        oracleAddr = _oracleAddr;
        lendingVault = _lendingVault;
        coreAlgorithm = _coreAlgorithm;
        riskIsolationModeAcceptAssets = _riskIsolationModeAcceptAssets;
    }

    function xInterfacesetting(address _xInterface, bool _ToF)external onlySetter{
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

    function setFloorOfHealthFactor(uint normal, uint homogeneous) external onlySetter{
        require(normal >= 1 ether, "Lending Manager: Normal floor too low");
        require(homogeneous >= 1 ether, "Lending Manager: Homogeneous floor too low");
        normalFloorOfHealthFactor = normal;
        homogeneousFloorOfHealthFactor = homogeneous;
        emit FloorOfHealthFactorSetup( normal, homogeneous);
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
                                    bool  _isNew) public onlySetter {
        require(   _maxLTV <= 9500
                && _liqPenalty >= 100
                && _liqPenalty <= UPPER_SYSTEM_LIMIT/5
                && _bestLendingRatio > 0
                && _bestLendingRatio < UPPER_SYSTEM_LIMIT
                && _homogeneousModeLTV < UPPER_SYSTEM_LIMIT
                && _bestDepositInterestRate > 0
                && _bestDepositInterestRate < UPPER_SYSTEM_LIMIT
                && _reserveFactor > 0,"Lending Manager: Exceed UPPER_SYSTEM_LIMIT");
        require(licensedAssets[_asset].assetAddr == address(0),"Lending Manager: Asset already registered!");
        require(assetsSerialNumber.length < 49,"Lending Manager: assets can't exceed 50");
        assetsSerialNumber.push(_asset);
        licensedAssets[_asset].assetAddr = _asset;
        licensedAssets[_asset].maximumLTV = _maxLTV;
        licensedAssets[_asset].liquidationPenalty = _liqPenalty;
        licensedAssets[_asset].maxLendingAmountInRIM = _maxLendingAmountInRIM;
        licensedAssets[_asset].bestLendingRatio = _bestLendingRatio;
        licensedAssets[_asset].lendingModeNum = _lendingModeNum;
        licensedAssets[_asset].homogeneousModeLTV = _homogeneousModeLTV;
        licensedAssets[_asset].bestDepositInterestRate = _bestDepositInterestRate;
        licensedAssets[_asset].reserveFactor = _reserveFactor;

        if(_isNew){
            assetsDepositAndLend[_asset] = iCoinFactory(coinFactory).createDeAndLoCoin(_asset);
        }else{
            assetsDepositAndLend[_asset][0] = iCoinFactory(coinFactory).getDepositCoin(_asset);
            assetsDepositAndLend[_asset][1] = iCoinFactory(coinFactory).getLoanCoin(_asset);
        }

        emit LicensedAssetsSetup(_asset,
                                 _maxLTV,
                                 _liqPenalty,
                                 _maxLendingAmountInRIM,
                                 _bestLendingRatio,
                                 _reserveFactor,
                                 _lendingModeNum,
                                 _homogeneousModeLTV,
                                 _bestDepositInterestRate) ;
    }

    function licensedAssetsReset(address _asset,
                                uint _maxLTV,
                                uint _liqPenalty,
                                uint _maxLendingAmountInRIM,
                                uint _bestLendingRatio,
                                uint  _reserveFactor,
                                uint8 _lendingModeNum,
                                uint _homogeneousModeLTV,
                                uint _bestDepositInterestRate) public onlySetter {
        require(licensedAssets[_asset].assetAddr == _asset ,"Lending Manager: asset is Not registered!");
        require(   _maxLTV <= 9500
                && _liqPenalty >= 100
                && _liqPenalty <= UPPER_SYSTEM_LIMIT/5
                && _bestLendingRatio > 0
                && _bestLendingRatio < UPPER_SYSTEM_LIMIT
                && _homogeneousModeLTV < UPPER_SYSTEM_LIMIT
                && _bestDepositInterestRate > 0
                && _bestDepositInterestRate < UPPER_SYSTEM_LIMIT
                && _reserveFactor > 0,"Lending Manager: Exceed UPPER_SYSTEM_LIMIT");
         _beforeUpdate(_asset);
        licensedAssets[_asset].maximumLTV = _maxLTV;
        licensedAssets[_asset].liquidationPenalty = _liqPenalty;
        licensedAssets[_asset].maxLendingAmountInRIM = _maxLendingAmountInRIM;
        licensedAssets[_asset].bestLendingRatio = _bestLendingRatio;
        licensedAssets[_asset].lendingModeNum = _lendingModeNum;
        licensedAssets[_asset].homogeneousModeLTV = _homogeneousModeLTV;
        licensedAssets[_asset].bestDepositInterestRate = _bestDepositInterestRate;
        licensedAssets[_asset].reserveFactor = _reserveFactor;
        _assetsValueUpdate(_asset);
        emit LicensedAssetsSetup(_asset,
                                 _maxLTV,
                                 _liqPenalty,
                                 _maxLendingAmountInRIM,
                                 _bestLendingRatio,
                                 _reserveFactor,
                                 _lendingModeNum,
                                 _homogeneousModeLTV,
                                 _bestDepositInterestRate) ;
    }

    function userModeSetting(uint8 _mode,address _userRIMAssetsAddress, address user) public onlyInterface(user){
        require(_userTotalLendingValue(user) == 0 && _userTotalDepositValue(user) == 0,"Lending Manager: should return all Lending Assets and withdraw all Deposit Assets.");

        if(_mode == 1){
            require(licensedAssets[_userRIMAssetsAddress].maxLendingAmountInRIM > 0,"Lending Manager: Mode 1 Need a RIMAsset.");
        }

        userMode[user] = _mode;
        userRIMAssetsAddress[user] = _userRIMAssetsAddress;
        emit UserModeSetting(user, _mode, _userRIMAssetsAddress);
    }

    //----------------------------- View Function------------------------------------
    function assetsBaseInfo(address token) public view returns(uint maximumLTV,
                                                               uint liquidationPenalty,
                                                               uint maxLendingAmountInRIM,
                                                               uint bestLendingRatio,
                                                               uint lendingModeNum,
                                                               uint homogeneousModeLTV,
                                                               uint bestDepositInterestRate){
        return (licensedAssets[token].maximumLTV,
                licensedAssets[token].liquidationPenalty,
                licensedAssets[token].maxLendingAmountInRIM,
                licensedAssets[token].bestLendingRatio,
                licensedAssets[token].lendingModeNum,
                licensedAssets[token].homogeneousModeLTV,
                licensedAssets[token].bestDepositInterestRate);
    }
    function assetsReserveFactor(address token) public view returns(uint reserveFactor){
        return (licensedAssets[token].reserveFactor);
    }

    function assetsTimeDependentParameter(address token) public view returns(uint latestDepositCoinValue,
                                                                             uint latestLendingCoinValue,
                                                                             uint latestDepositInterest,
                                                                             uint latestLendingInterest){
        return (assetInfos[token].latestDepositCoinValue,
                assetInfos[token].latestLendingCoinValue,
                assetInfos[token].latestDepositInterest,
                assetInfos[token].latestLendingInterest);
    }

    function assetsDepositAndLendAddrs(address token) public view returns(address[2] memory addrs){
        return assetsDepositAndLend[token];
    }

    function licensedAssetAmount() public view returns(uint assetLength){
        assetLength = assetsSerialNumber.length;
    }
    function VaultTokensAmount(address tokenAddr) public view returns(uint maxAmount){
        address[2] memory pair = assetsDepositAndLendAddrs(tokenAddr);
        uint amountD18 = iDepositOrLoanCoin(pair[0]).totalSupply();
        uint amountL18 = iDepositOrLoanCoin(pair[1]).totalSupply();
        return (amountD18 - amountL18);
    }

    function _userTotalLendingValue(address _user) internal view returns(uint values){
        for(uint i=0;i<assetsSerialNumber.length;i++){
            values += IERC20(assetsDepositAndLend[assetsSerialNumber[i]][1]).balanceOf(_user)
            * iSlcOracle(oracleAddr).getPrice(assetsSerialNumber[i]) / 1 ether;
        }
    }

    function _userTotalDepositValue(address _user) internal view returns(uint values){
        for(uint i=0;i!=assetsSerialNumber.length;i++){
            values += IERC20(assetsDepositAndLend[assetsSerialNumber[i]][0]).balanceOf(_user)
            * iSlcOracle(oracleAddr).getPrice(assetsSerialNumber[i]) / 1 ether;
        }
    }

    function userDepositAndLendingValue(address user) public view returns(uint _amountDeposit,uint _amountLending){
        uint tempgetprice;
        for(uint i=0;i!=assetsSerialNumber.length;i++){
            tempgetprice = iSlcOracle(oracleAddr).getPrice(assetsSerialNumber[i]);
            if(userMode[user]>1){
                    _amountDeposit += iDepositOrLoanCoin(assetsDepositAndLend[assetsSerialNumber[i]][0]).balanceOf(user)
                                    * tempgetprice / 1 ether
                                    * licensedAssets[assetsSerialNumber[i]].homogeneousModeLTV / UPPER_SYSTEM_LIMIT;
            }else{
                    _amountDeposit += iDepositOrLoanCoin(assetsDepositAndLend[assetsSerialNumber[i]][0]).balanceOf(user)
                                    * tempgetprice / 1 ether
                                    * licensedAssets[assetsSerialNumber[i]].maximumLTV / UPPER_SYSTEM_LIMIT;
            }
            _amountLending += iDepositOrLoanCoin(assetsDepositAndLend[assetsSerialNumber[i]][1]).balanceOf(user)
                                * tempgetprice / 1 ether;
        }
    }

    function viewUsersHealthFactor(address user) public view returns(uint userHealthFactor){
        uint _amountDeposit;
        uint _amountLending;

        (_amountDeposit,_amountLending) = userDepositAndLendingValue(user);
        if(_amountLending > 0){
            userHealthFactor = _amountDeposit * 1 ether / _amountLending;
        }else if(_amountDeposit >= 0){
            userHealthFactor = 1000 ether;
        }else{
            userHealthFactor = 0 ether;
        }
    }

    function getCoinValues(address token) public view returns(uint[2] memory currentValue){
        uint tempVaule = (block.timestamp - assetInfos[token].latestTimeStamp) * 1 ether / (ONE_YEAR * UPPER_SYSTEM_LIMIT);
        currentValue[0] = assetInfos[token].latestDepositCoinValue
                        + tempVaule * assetInfos[token].latestDepositInterest;
        currentValue[1] = assetInfos[token].latestLendingCoinValue
                        + tempVaule * assetInfos[token].latestLendingInterest;

        if(currentValue[0] == 0){
            currentValue[0] = 1 ether;
        }
        if(currentValue[1] == 0){
            currentValue[1] = 1 ether;
        }
    }

    function userAssetOverview(address user) public view returns(address[] memory tokens, uint[] memory _amountDeposit, uint[] memory _amountLending){
        uint assetLength = assetsSerialNumber.length;
        _amountDeposit = new uint[](assetLength);
        _amountLending = new uint[](assetLength);
        tokens = new address[](assetLength);
        for(uint i=0;i!=assetLength;i++){
            tokens[i] = assetsSerialNumber[i];
            _amountDeposit[i] = iDepositOrLoanCoin(assetsDepositAndLend[assetsSerialNumber[i]][0]).balanceOf(user);
            _amountLending[i] = iDepositOrLoanCoin(assetsDepositAndLend[assetsSerialNumber[i]][1]).balanceOf(user);
        }
    }

    //---------------------------- borrow & lend  Function----------------------------
    function _beforeUpdate(address token) internal returns(uint[2] memory latestValues){
        latestValues = getCoinValues(token);
        assetInfos[token].latestDepositCoinValue = latestValues[0];
        assetInfos[token].latestLendingCoinValue = latestValues[1];
        assetInfos[token].latestTimeStamp = block.timestamp;
    }

    function _assetsValueUpdate(address token) internal returns(uint[2] memory latestInterest){
        require(assetInfos[token].latestTimeStamp == block.timestamp,"Lending Manager: Only be uesd after beforeUpdate");
        latestInterest = iLendingCoreAlgorithm(coreAlgorithm).assetsValueUpdate(token);
        assetInfos[token].latestDepositInterest = latestInterest[0];
        assetInfos[token].latestLendingInterest = latestInterest[1];
        emit DepositAndLoanInterest( token, latestInterest[0], latestInterest[1], block.timestamp);
    }

    //  Assets Deposit
    function assetsDeposit(address tokenAddr, uint amount, address user) public whenNotPaused nonReentrant onlyInterface(user) {
        uint amountNormalize = amount * 1 ether / (10**iDecimals(tokenAddr).decimals());

        require(amount > 0,"Lending Manager: Cant Pledge 0 amount");
        require(licensedAssets[tokenAddr].assetAddr == tokenAddr,"Lending Manager: Token not licensed");
        if(userMode[user] == 0){
            require(licensedAssets[tokenAddr].maxLendingAmountInRIM == 0,"Lending Manager: Wrong Token in Risk Isolation Mode");
        }else if(userMode[user] == 1){
            require((tokenAddr == userRIMAssetsAddress[user]),"Lending Manager: Wrong Token in Risk Isolation Mode");
        }else {
            require((licensedAssets[tokenAddr].lendingModeNum == userMode[user]),"Lending Manager: Wrong Mode, Need in same homogeneous Mode");
        }

        _beforeUpdate(tokenAddr);
        IERC20(tokenAddr).safeTransferFrom(msg.sender,lendingVault,amount);
        iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][0]).mintCoin(user,amountNormalize);
        _assetsValueUpdate(tokenAddr);
        emit AssetsDeposit(tokenAddr, amount, user);
    }

    // Withdrawal of deposits
    function withdrawDeposit(address tokenAddr, uint amount, address user) public whenNotPaused nonReentrant onlyInterface(user) {
        uint amountNormalize = amount * 1 ether / (10**iDecimals(tokenAddr).decimals());
        uint amountTokenMax = iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][0]).balanceOf(user);

        require(amount > 0,"Lending Manager: Cant Pledge 0 amount");
        require(licensedAssets[tokenAddr].assetAddr == tokenAddr,"Lending Manager: Token not licensed");
        require(VaultTokensAmount(tokenAddr) >= amountNormalize,"Lending Manager: Vault Token amount NOT enough");
        require(amountTokenMax >= amountNormalize,"Lending Manager: User Token amount NOT enough");
        if(amountTokenMax - amountNormalize < 1 ether / (10**iDecimals(tokenAddr).decimals())) {
            amountNormalize = amountTokenMax;
        }

        iLendingVaults(lendingVault).vaultsERC20Approve(tokenAddr, amount);
        _beforeUpdate(tokenAddr);
        IERC20(tokenAddr).safeTransferFrom(lendingVault,user,amount);
        iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][0]).burnCoin(user,amountNormalize);
        _assetsValueUpdate(tokenAddr);

        uint factor;
        (factor) = viewUsersHealthFactor(user);
        if(userMode[user] > 1){
            require( factor >= homogeneousFloorOfHealthFactor,"Your Health Factor <= homogeneous Floor Of Health Factor, Cant redeem assets");
        }else{
            require( factor >= normalFloorOfHealthFactor,"Your Health Factor <= normal Floor Of Health Factor, Cant redeem assets");
        }
        emit WithdrawDeposit(tokenAddr, amount, user);
    }

    // lend Asset
    function lendAsset(address tokenAddr, uint amount, address user) public whenNotPaused nonReentrant onlyInterface(user) {
        uint amountNormalize = amount * 1 ether / (10**iDecimals(tokenAddr).decimals());

        require(amount > 0,"Lending Manager: Cant Pledge 0 amount");
        require(licensedAssets[tokenAddr].assetAddr == tokenAddr,"Lending Manager: Token not licensed");
        require(VaultTokensAmount(tokenAddr) >= amountNormalize,"Lending Manager: Vault Tokens amount NOT enough");

        if(userMode[user] == 1){
            require(tokenAddr == riskIsolationModeAcceptAssets,"Lending Manager: Wrong Token in Risk Isolation Mode");
            uint tempAmount = IERC20(assetsDepositAndLend[riskIsolationModeAcceptAssets][1]).balanceOf(user) + amountNormalize;
            riskIsolationModeLendingNetAmount[userRIMAssetsAddress[user]] = riskIsolationModeLendingNetAmount[userRIMAssetsAddress[user]]
                                                         - userRIMAssetsLendingNetAmount[user][tokenAddr]
                                                         + tempAmount;
            userRIMAssetsLendingNetAmount[user][tokenAddr] = tempAmount;
            require(riskIsolationModeLendingNetAmount[userRIMAssetsAddress[user]] <= licensedAssets[userRIMAssetsAddress[user]].maxLendingAmountInRIM,"Lending Manager: The borrow amount exceeds RIM allowed limit");
        }
        if(userMode[user] > 1){
            require((licensedAssets[tokenAddr].lendingModeNum == userMode[user]),"Lending Manager: Wrong Mode, Need in same homogeneous Mode");
        }
        _beforeUpdate(tokenAddr);
        iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][1]).mintCoin(user,amountNormalize);
        iLendingVaults(lendingVault).vaultsERC20Approve(tokenAddr, amount);
        IERC20(tokenAddr).safeTransferFrom(lendingVault, user,amount);
        _assetsValueUpdate(tokenAddr);

        uint factor;
        (factor) = viewUsersHealthFactor(user);
        if(userMode[user] > 1){
            require( factor >= homogeneousFloorOfHealthFactor,"Your Health Factor <= homogeneous Floor Of Health Factor, Cant redeem assets");
        }else{
            require( factor >= normalFloorOfHealthFactor,"Your Health Factor <= normal Floor Of Health Factor, Cant redeem assets");
        }
        require(IERC20(assetsDepositAndLend[tokenAddr][0]).totalSupply() * 99 / 100 >= IERC20(assetsDepositAndLend[tokenAddr][1]).totalSupply(),"Lending Manager: total amount borrowed can t exceeds 99% of the deposit");
        emit LendAsset(tokenAddr, amount, user);
    }

    // repay Loan
    function repayLoan(address tokenAddr,uint amount, address user) public whenNotPaused nonReentrant onlyInterface(user) {
        uint amountNormalize = amount * 1 ether / (10**iDecimals(tokenAddr).decimals());
        uint amountTokenMax = iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][1]).balanceOf(user);

        require(amount > 0,"Lending Manager: Cant Pledge 0 amount");
        require(licensedAssets[tokenAddr].assetAddr == tokenAddr,"Lending Manager: Token not licensed");
        if(amountNormalize > amountTokenMax){
            require(amountNormalize - amountTokenMax < 1 ether / (10**iDecimals(tokenAddr).decimals()));
            amountNormalize = amountTokenMax;
        }

        if(userMode[user] == 1){
            require(licensedAssets[userRIMAssetsAddress[user]].maxLendingAmountInRIM > 0,"Lending Manager: Wrong Token in Risk Isolation Mode");
            require((tokenAddr == riskIsolationModeAcceptAssets),"Lending Manager: Wrong Token in Risk Isolation Mode");
            uint tempAmount = IERC20(assetsDepositAndLend[riskIsolationModeAcceptAssets][1]).balanceOf(user) - amountNormalize;
            riskIsolationModeLendingNetAmount[userRIMAssetsAddress[user]] = riskIsolationModeLendingNetAmount[userRIMAssetsAddress[user]]
                                                         - userRIMAssetsLendingNetAmount[user][tokenAddr]
                                                         + tempAmount;
            userRIMAssetsLendingNetAmount[user][tokenAddr] = tempAmount;
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
                              address user) public whenNotPaused onlyInterface(user) nonReentrant {
        uint borrowAmountNormalize = borrowAmount * 1 ether / (10**iDecimals(borrowTokenAddr).decimals());
        uint userMaxPaid = iDepositOrLoanCoin(assetsDepositAndLend[useTokenAddr][0]).balanceOf(user)
                         * iSlcOracle(oracleAddr).getPrice(useTokenAddr) ;
        uint userNeedPaid = borrowAmountNormalize * iSlcOracle(oracleAddr).getPrice(borrowTokenAddr) / 100;
        require(userMaxPaid > userNeedPaid ,"Lending Manager: Insufficient funds");

        require(borrowAmount > 0,"Lending Manager: Cant Pledge 0 amount");
        require(licensedAssets[useTokenAddr].assetAddr == useTokenAddr,"Lending Manager: Token not licensed");
        require(licensedAssets[borrowTokenAddr].assetAddr == borrowTokenAddr,"Lending Manager: Borrow token not licensed");
        require(flashLoanFeesAddress != address(0),"Lending Manager: Flash loan fees address not set");
        userNeedPaid = userNeedPaid / iSlcOracle(oracleAddr).getPrice(useTokenAddr);
        require(VaultTokensAmount(useTokenAddr) > userNeedPaid,"Lending Manager: Vault Tokens amount NOT enough");
        iLendingVaults(lendingVault).vaultsERC20Approve(useTokenAddr, userNeedPaid);
        IERC20(useTokenAddr).safeTransferFrom(lendingVault, flashLoanFeesAddress, userNeedPaid);
        iDepositOrLoanCoin(assetsDepositAndLend[useTokenAddr][0]).burnCoin(user, userNeedPaid);

        _beforeUpdate(useTokenAddr);
        iLendingVaults(lendingVault).vaultsERC20Approve(borrowTokenAddr, borrowAmount);
        IERC20(borrowTokenAddr).safeTransferFrom(lendingVault, user, borrowAmount);
        iUserFlashLoan(flashLoanUserContractAddr).executeOperation(borrowTokenAddr, borrowAmount, '');
        IERC20(borrowTokenAddr).safeTransferFrom(user, lendingVault, borrowAmount);
        _assetsValueUpdate(useTokenAddr);

        uint factor;
        (factor) = viewUsersHealthFactor(user);
        if(userMode[user] > 1){
            require( factor >= homogeneousFloorOfHealthFactor,"Your Health Factor <= homogeneous Floor Of Health Factor, Cant redeem assets");
        }else{
            require( factor >= normalFloorOfHealthFactor,"Your Health Factor <= normal Floor Of Health Factor, Cant redeem assets");
        }
    }

    //------------------------------ Liquidate Function------------------------------
    function tokenLiquidate(address user,
                            address liquidateToken,
                            uint    liquidateAmount,
                            address depositToken) public whenNotPaused nonReentrant returns(uint usedAmount) {
        uint liquidateAmountNormalize = liquidateAmount * 1 ether / (10**iDecimals(liquidateToken).decimals());
        _beforeUpdate(liquidateToken);
        _beforeUpdate(depositToken);

        require(liquidateAmountNormalize > 0,"Lending Manager: Cant Pledge 0 amount");

        require(viewUsersHealthFactor(user) < 1 ether,"Lending Manager: Users Health Factor Need < 1 ether");
        uint amountLending = iDepositOrLoanCoin(assetsDepositAndLend[liquidateToken][1]).balanceOf(user);
        uint amountDeposit = iDepositOrLoanCoin(assetsDepositAndLend[depositToken][0]).balanceOf(user);
        require( amountLending >= liquidateAmountNormalize,"Lending Manager: amountLending >= liquidateAmountNormalize");

        usedAmount = liquidateAmountNormalize * iSlcOracle(oracleAddr).getPrice(liquidateToken);
        usedAmount = usedAmount * (UPPER_SYSTEM_LIMIT - licensedAssets[liquidateToken].liquidationPenalty)
                                / (UPPER_SYSTEM_LIMIT * iSlcOracle(oracleAddr).getPrice(depositToken));
        require( amountDeposit >= usedAmount,"Lending Manager: amountDeposit >= usedAmount");

        iDepositOrLoanCoin(assetsDepositAndLend[liquidateToken][1]).burnCoin(user,liquidateAmountNormalize);
        iDepositOrLoanCoin(assetsDepositAndLend[depositToken][0]).burnCoin(user,usedAmount);

        usedAmount = usedAmount * (10**iDecimals(depositToken).decimals()) / 1 ether;

        iLendingVaults(lendingVault).vaultsERC20Approve(liquidateToken, liquidateAmount);
        IERC20(depositToken).safeTransferFrom(msg.sender, lendingVault, usedAmount);
        IERC20(liquidateToken).safeTransferFrom(lendingVault, msg.sender, liquidateAmount);

        _assetsValueUpdate(liquidateToken);
        _assetsValueUpdate(depositToken);
        emit Liquidation(user, msg.sender, liquidateToken, depositToken, liquidateAmount, usedAmount);
    }

}
