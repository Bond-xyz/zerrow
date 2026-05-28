// SPDX-License-Identifier: Business Source License 1.1
// First Release Time : 2025.03.30

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/islcoracle.sol";

import "./interfaces/iDepositOrLoanCoin.sol";
import "./interfaces/iLendingCoreAlgorithm.sol";
import "./interfaces/iLendingVaults.sol";
import "./interfaces/iUserFlashLoan.sol";
import "./LendingManagerAdminLib.sol";
import "./LendingManagerAssetLib.sol";
import "./LendingManagerLib.sol";
import "./LendingManagerModeLib.sol";
import "./LendingManagerRIMLib.sol";
import "./LendingManagerSnapshotLib.sol";
import "./LendingManagerTypes.sol";

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


    mapping (address=>bool) public xInterface;
    address[] public interfaceArray;
    mapping(address => mapping(address => bool)) public interfaceApproval;

    mapping(address => LendingManagerTypes.LicensedAsset) public licensedAssets;
    mapping(address => address[2]) public assetsDepositAndLend;
    address[] public assetsSerialNumber;

    mapping(address => LendingManagerTypes.AssetInfo) public assetInfos;
    mapping(address => mapping(address => uint)) public userRIMAssetsLendingNetAmount;
    mapping(address => uint) public riskIsolationModeLendingNetAmount; //RIM  Risk Isolation Mode
    mapping(address => address) public userRIMAssetsAddress;
    address public riskIsolationModeAcceptAssets;
    mapping(address => uint8) public userMode;

    address public guardian;

    /// @notice Incremented each time an interface is de-listed, invalidating
    ///         any approvals that were granted under a prior version.
    mapping(address => uint256) public interfaceVersion;
    /// @notice Records the interfaceVersion at which a user granted approval.
    mapping(address => mapping(address => uint256)) public interfaceApprovalVersion;

    /// @dev Storage gap for future upgrades (reduced by 2 for new mappings)
    uint256[47] private __gap;

    //----------------------------custom errors ----------------------------
    error OnlySetter();
    error NotWhitelistedInterface();
    error InterfaceNotApproved();
    error ApprovalOutdated();
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
    error NormalFloorTooHigh();
    error HomogeneousFloorTooHigh();
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
    event TransferSetterCancelled(address indexed cancelledPending);
    //------------------------------------------------------------------

    function _requireSetter() internal view {
        if (msg.sender != setter) revert OnlySetter();
    }

    function _requireInterface(address user) internal view {
        if (msg.sender != user) {
            if (!xInterface[msg.sender]) revert NotWhitelistedInterface();
            if (!interfaceApproval[user][msg.sender]) revert InterfaceNotApproved();
            if (interfaceApprovalVersion[user][msg.sender] != interfaceVersion[msg.sender]) revert ApprovalOutdated();
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
    function _authorizeUpgrade(address) internal view override {
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
        newsetter = LendingManagerAdminLib.transferSetter(msg.sender, setter, _set);
    }
    function acceptSetter(bool _TorF) external {
        (setter, newsetter) = LendingManagerAdminLib.acceptSetter(msg.sender, newsetter, setter, _TorF);
    }

    function cancelTransferSetter() external {
        LendingManagerAdminLib.cancelTransferSetter(msg.sender, setter, newsetter);
        newsetter = address(0);
    }

    function setup( address _coinFactory,
                    address _lendingVault,
                    address _riskIsolationModeAcceptAssets,
                    address _coreAlgorithm,
                    address _oracleAddr ) external {
        LendingManagerAdminLib.validateSetup(
            licensedAssets,
            assetsSerialNumber,
            riskIsolationModeLendingNetAmount,
            msg.sender,
            setter,
            riskIsolationModeAcceptAssets,
            _coinFactory,
            _lendingVault,
            _riskIsolationModeAcceptAssets,
            _coreAlgorithm,
            _oracleAddr
        );
        coinFactory = _coinFactory;
        oracleAddr = _oracleAddr;
        lendingVault = _lendingVault;
        coreAlgorithm = _coreAlgorithm;
        riskIsolationModeAcceptAssets = _riskIsolationModeAcceptAssets;
    }

    function xInterfacesetting(address _xInterface, bool _ToF)external {
        LendingManagerAdminLib.setInterface(
            xInterface,
            interfaceArray,
            interfaceVersion,
            msg.sender,
            setter,
            _xInterface,
            _ToF
        );
    }

    function setInterfaceApproval(bool approved) external {
        LendingManagerAdminLib.setInterfaceApproval(
            interfaceArray,
            interfaceApproval,
            interfaceVersion,
            interfaceApprovalVersion,
            msg.sender,
            approved
        );
    }

    function setFloorOfHealthFactor(uint normal, uint homogeneous) external {
        LendingManagerAdminLib.validateFloorOfHealthFactor(msg.sender, setter, normal, homogeneous);
        normalFloorOfHealthFactor = normal;
        homogeneousFloorOfHealthFactor = homogeneous;
    }

    function coinMintLockerSetup(address coinAddr, bool tOF) external {
        LendingManagerAdminLib.coinMintLockerSetup(msg.sender, setter, coinAddr, tOF);
    }

    /// @notice Update the reward contract on a deposit/loan coin.
    /// @dev    The lendingManager is the setter on coins it creates, so only
    ///         this contract can call rewardContractSetup.  The factory's
    ///         coinResetup cannot work because the factory is not the setter.
    /// @param _coin            Address of the depositOrLoanCoin to reconfigure.
    /// @param _rewardContract  New reward contract address.
    function coinRewardContractSetup(address _coin, address _rewardContract) external {
        LendingManagerAdminLib.coinRewardContractSetup(msg.sender, setter, _coin, _rewardContract);
    }

    /// @notice Transfer the setter role on a deposit/loan coin.
    /// @dev    The lendingManager is the setter on coins it creates, so only
    ///         this contract can call transferSetter.  The factory cannot do
    ///         this because it is not the setter.
    /// @param _coin       Address of the depositOrLoanCoin whose setter to transfer.
    /// @param _newSetter  Address of the new setter (must accept via acceptSetter).
    function coinTransferSetter(address _coin, address _newSetter) external {
        LendingManagerAdminLib.coinTransferSetter(msg.sender, setter, _coin, _newSetter);
    }

    function licensedAssetsDeregister(address _asset) external {
        _requireSetter();
        LendingManagerAssetLib.deregister(licensedAssets, assetsDepositAndLend, assetInfos, assetsSerialNumber, _asset);
    }

    function licensedAssetsRegister(address,
                                    uint,
                                    uint,
                                    uint,
                                    uint,
                                    uint,
                                    uint8,
                                    uint,
                                    uint,
                                    bool) external {
        _requireSetter();
        LendingManagerAssetLib.registerFromCalldata(
            licensedAssets,
            assetsDepositAndLend,
            assetsSerialNumber,
            coinFactory,
            msg.data
        );
    }

    function licensedAssetsReset(address _asset,
                                uint,
                                uint,
                                uint,
                                uint,
                                uint,
                                uint8,
                                uint,
                                uint) external {
        _requireSetter();
        _beforeUpdate(_asset);
        LendingManagerAssetLib.resetFromCalldata(
            licensedAssets,
            msg.data
        );
        _assetsValueUpdate(_asset);
    }

    function userModeSetting(uint8 _mode,address _userRIMAssetsAddress, address user) external {
        _requireInterface(user);
        LendingManagerModeLib.userModeSetting(
            licensedAssets,
            assetsDepositAndLend,
            assetsSerialNumber,
            userMode,
            userRIMAssetsAddress,
            oracleAddr,
            _mode,
            _userRIMAssetsAddress,
            user
        );
    }

    //----------------------------- Internal Helpers ------------------------------------
    function _loadAssetSnapshots() internal view returns (LendingManagerLib.AssetSnapshot[] memory s) {
        return LendingManagerSnapshotLib.loadAssetSnapshots(licensedAssets, assetsDepositAndLend, assetsSerialNumber);
    }

    function _requireLicensed(address tokenAddr) internal view {
        if (licensedAssets[tokenAddr].assetAddr != tokenAddr) revert TokenNotLicensed();
    }

    function _requireNonZeroAmount(uint amount) internal pure {
        if (amount == 0) revert ZeroAmount();
    }

    //----------------------------- View Function------------------------------------
    function assetsBaseInfo(address token) external view returns(uint maximumLTV,
                                                               uint liquidationPenalty,
                                                               uint maxLendingAmountInRIM,
                                                               uint bestLendingRatio,
                                                               uint lendingModeNum,
                                                               uint homogeneousModeLTV,
                                                               uint bestDepositInterestRate){
        LendingManagerTypes.LicensedAsset storage a = licensedAssets[token];
        return (a.maximumLTV, a.liquidationPenalty, a.maxLendingAmountInRIM,
                a.bestLendingRatio, a.lendingModeNum, a.homogeneousModeLTV, a.bestDepositInterestRate);
    }
    function assetsReserveFactor(address token) external view returns(uint reserveFactor){
        return (licensedAssets[token].reserveFactor);
    }

    function assetsTimeDependentParameter(address token) external view returns(uint latestDepositCoinValue,
                                                                             uint latestLendingCoinValue,
                                                                             uint latestDepositInterest,
                                                                             uint latestLendingInterest){
        LendingManagerTypes.AssetInfo storage a = assetInfos[token];
        return (a.latestDepositCoinValue, a.latestLendingCoinValue, a.latestDepositInterest, a.latestLendingInterest);
    }

    function assetsDepositAndLendAddrs(address token) external view returns(address[2] memory addrs){
        return assetsDepositAndLend[token];
    }

    function licensedAssetAmount() external view returns(uint assetLength){
        assetLength = assetsSerialNumber.length;
    }

    function _rawToNormalized(address tokenAddr, uint amountRaw) internal view returns (uint amountNorm18) {
        return LendingManagerLib.rawToNormalized(tokenAddr, amountRaw);
    }

    function _normalizedToRaw(address tokenAddr, uint amountNorm18) internal view returns (uint amountRaw) {
        return LendingManagerLib.normalizedToRaw(tokenAddr, amountNorm18);
    }

    function VaultTokensAmount(address tokenAddr) public view returns(uint maxAmount){
        maxAmount = _rawToNormalized(tokenAddr, IERC20(tokenAddr).balanceOf(lendingVault));
    }

    function userDepositAndLendingValue(address user) external view returns(uint _amountDeposit,uint _amountLending){
        LendingManagerLib.AssetSnapshot[] memory s = _loadAssetSnapshots();
        return LendingManagerLib.depositAndLendingValue(s, user, userMode[user], oracleAddr);
    }

    function viewUsersHealthFactor(address user) public view returns(uint userHealthFactor){
        LendingManagerLib.AssetSnapshot[] memory s = _loadAssetSnapshots();
        return LendingManagerLib.healthFactor(s, user, userMode[user], oracleAddr);
    }

    function getCoinValues(address token) public view returns(uint[2] memory currentValue){
        LendingManagerTypes.AssetInfo storage a = assetInfos[token];
        return LendingManagerLib.coinValues(
            a.latestDepositCoinValue, a.latestLendingCoinValue,
            a.latestDepositInterest, a.latestLendingInterest, a.latestTimeStamp
        );
    }

    function userAssetOverview(address user) external view returns(address[] memory tokens, uint[] memory _amountDeposit, uint[] memory _amountLending){
        LendingManagerLib.AssetSnapshot[] memory s = _loadAssetSnapshots();
        return LendingManagerLib.assetOverview(s, user);
    }

    //---------------------------- borrow & lend  Function----------------------------
    function _beforeUpdate(address token) internal returns(uint[2] memory latestValues){
        latestValues = getCoinValues(token);
        LendingManagerTypes.AssetInfo storage a = assetInfos[token];
        // FR-H-02: Preserve the "fully wiped" sentinel. coinValues() returns 0
        // for wiped markets, but writing 0 back would be misread as "uninitialized"
        // on subsequent calls. Keep the sentinel so the wipe is permanent.
        if (a.latestDepositCoinValue != type(uint256).max) {
            a.latestDepositCoinValue = latestValues[0];
        }
        a.latestLendingCoinValue = latestValues[1];
        a.latestTimeStamp = block.timestamp;
    }

    function _assetsValueUpdate(address token) internal returns(uint[2] memory latestInterest){
        LendingManagerTypes.AssetInfo storage a = assetInfos[token];
        if (a.latestTimeStamp != block.timestamp) revert NotAfterBeforeUpdate();

        // R2-H-01: If the market was fully wiped by _socializeBadDebt(), the
        // deposit sentinel must be preserved. Value-based deposit totalSupply()
        // reads zero because getCoinValues returns 0 for wiped markets, but raw
        // OQC shares may still exist. Resetting the deposit side to 1 ether
        // would revive those worthless shares back to par. The lending side can
        // only be reset when no loan value remains outstanding.
        if (a.latestDepositCoinValue == type(uint256).max) {
            if (IERC20(assetsDepositAndLend[token][1]).totalSupply() == 0) {
                a.latestLendingCoinValue = 1 ether;
            }
            a.latestTimeStamp = block.timestamp;
            a.latestDepositInterest = 0;
            a.latestLendingInterest = 0;
            latestInterest[0] = 0;
            latestInterest[1] = 0;
            emit DepositAndLoanInterest(token, 0, 0, block.timestamp);
            return latestInterest;
        }

        // When both deposit and loan supplies are zero the market is idle.
        // Reset coin values and timestamp to baseline so the next deposit
        // does not apply elapsed idle time against stale rate data.
        if (IERC20(assetsDepositAndLend[token][0]).totalSupply() == 0
            && IERC20(assetsDepositAndLend[token][1]).totalSupply() == 0) {
            a.latestDepositCoinValue = 1 ether;
            a.latestLendingCoinValue = 1 ether;
            a.latestTimeStamp = block.timestamp;
            a.latestDepositInterest = 0;
            a.latestLendingInterest = 0;
            latestInterest[0] = 0;
            latestInterest[1] = 0;
            emit DepositAndLoanInterest(token, 0, 0, block.timestamp);
            return latestInterest;
        }

        latestInterest = iLendingCoreAlgorithm(coreAlgorithm).assetsValueUpdate(token);
        a.latestDepositInterest = latestInterest[0];
        a.latestLendingInterest = latestInterest[1];
        emit DepositAndLoanInterest( token, latestInterest[0], latestInterest[1], block.timestamp);
    }

    /// @dev Decrement RIM debt counters when loan coins are burned outside of repayLoan.
    ///      Safe to call for any user/token; no-ops when user is not in RIM mode or
    ///      the token is not the RIM-accepted asset.
    /// @dev FR-M-02: Reads post-burn OQC shares from the loan-coin contract
    ///      and syncs the RIM mappings to match. Because this function is always
    ///      called AFTER burnCoin(), reading the actual userOQCAmount captures
    ///      the exact share delta including burnCoin's ±1 dust adjustments.
    function _decrementRIMDebt(address user, address token, uint /*amount*/) internal {
        LendingManagerRIMLib.decrementDebt(
            assetsDepositAndLend,
            userRIMAssetsLendingNetAmount,
            riskIsolationModeLendingNetAmount,
            userRIMAssetsAddress,
            userMode,
            riskIsolationModeAcceptAssets,
            user,
            token
        );
    }

    function _socializeBadDebt(address user) internal {
        LendingManagerLib.AssetSnapshot[] memory s = _loadAssetSnapshots();
        (uint badDebtValue, uint[] memory burnAmounts) = LendingManagerLib.computeBadDebt(s, user, oracleAddr);
        if (badDebtValue == 0) return;

        slcUnsecuredIssuancesAmount += badDebtValue;
        for (uint i = 0; i < s.length; i++) {
            if (burnAmounts[i] > 0) {
                _beforeUpdate(s[i].asset);
                iDepositOrLoanCoin(s[i].loanCoin).burnCoin(user, burnAmounts[i]);
                _decrementRIMDebt(user, s[i].asset, burnAmounts[i]);

                {
                    uint totalDeposits = iDepositOrLoanCoin(s[i].depositCoin).totalSupply();
                    if (totalDeposits > 0) {
                        LendingManagerTypes.AssetInfo storage a = assetInfos[s[i].asset];
                        uint oldValue = a.latestDepositCoinValue;
                        // FR-H-02: Also handle type(uint256).max (wiped sentinel)
                        if (oldValue == 0 || oldValue == type(uint256).max) { oldValue = 1 ether; }
                        if (burnAmounts[i] >= totalDeposits) {
                            // FR-H-02: Use type(uint256).max as "fully wiped" sentinel
                            // instead of 0. Zero is already used as "uninitialized → 1e18"
                            // in coinValues(), so setting 0 here would revive deposits to par.
                            a.latestDepositCoinValue = type(uint256).max;
                            a.latestDepositInterest = 0;
                        } else {
                            a.latestDepositCoinValue = oldValue * (totalDeposits - burnAmounts[i]) / totalDeposits;
                            a.latestDepositInterest = a.latestDepositInterest * (totalDeposits - burnAmounts[i]) / totalDeposits;
                        }
                    }
                }
                _assetsValueUpdate(s[i].asset);
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

    /// @dev FR-M-02: RIM counters now track raw OQC shares (Original Quantity Coin)
    ///      instead of value-adjusted balances. This ensures that passive interest
    ///      accrual on dormant borrowers is always reflected in the global cap check,
    ///      because totalShares * currentCoinValue = true interest-inclusive debt.
    function _updateRIMAccounting(address user, address tokenAddr, uint amountNormalize, bool isLend) internal {
        uint coinValue = getCoinValues(riskIsolationModeAcceptAssets)[1];
        if (isLend) {
            LendingManagerRIMLib.updateBorrow(
                licensedAssets,
                assetsDepositAndLend,
                userRIMAssetsLendingNetAmount,
                riskIsolationModeLendingNetAmount,
                userRIMAssetsAddress,
                riskIsolationModeAcceptAssets,
                user,
                tokenAddr,
                amountNormalize,
                coinValue
            );
        } else {
            LendingManagerRIMLib.updateRepayment(
                licensedAssets,
                assetsDepositAndLend,
                userRIMAssetsLendingNetAmount,
                riskIsolationModeLendingNetAmount,
                userRIMAssetsAddress,
                riskIsolationModeAcceptAssets,
                user,
                tokenAddr,
                amountNormalize,
                coinValue
            );
        }
    }

    function _checkDepositMode(address tokenAddr, address user) internal view {
        LendingManagerRIMLib.checkDepositMode(licensedAssets, tokenAddr, userMode[user], userRIMAssetsAddress[user]);
    }

    //  Assets Deposit
    function assetsDeposit(address tokenAddr, uint amount, address user) external whenNotPaused nonReentrant {
        _requireInterface(user);

        _requireNonZeroAmount(amount);
        _requireLicensed(tokenAddr);
        _checkDepositMode(tokenAddr, user);

        _beforeUpdate(tokenAddr);
        uint balBefore = IERC20(tokenAddr).balanceOf(lendingVault);
        IERC20(tokenAddr).safeTransferFrom(msg.sender,lendingVault,amount);
        uint balAfter = IERC20(tokenAddr).balanceOf(lendingVault);
        uint actualReceived = balAfter - balBefore;
        uint amountNormalize = _rawToNormalized(tokenAddr, actualReceived);
        iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][0]).mintCoin(user,amountNormalize);
        _assetsValueUpdate(tokenAddr);
        emit AssetsDeposit(tokenAddr, amount, user);
    }

    // Withdrawal of deposits
    function withdrawDeposit(address tokenAddr, uint amount, address user) external whenNotPaused nonReentrant {
        _requireInterface(user);
        uint amountNormalize = _rawToNormalized(tokenAddr, amount);
        uint amountTokenMax = iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][0]).balanceOf(user);

        _requireNonZeroAmount(amount);
        _requireLicensed(tokenAddr);
        if (VaultTokensAmount(tokenAddr) < amountNormalize) revert VaultInsufficient();
        if (amountTokenMax < amountNormalize) revert UserBalanceInsufficient();
        if(amountTokenMax - amountNormalize < _rawToNormalized(tokenAddr, 1)) {
            // Dust remaining is less than 1 raw unit.
            // Only burn the normalized equivalent of the raw amount actually transferred,
            // so we don't burn more value than the user receives.
            amountNormalize = _rawToNormalized(tokenAddr, amount);
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
    function lendAsset(address tokenAddr, uint amount, address user) external whenNotPaused nonReentrant {
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
    function repayLoan(address tokenAddr,uint amount, address user) external whenNotPaused nonReentrant {
        _requireInterface(user);
        uint amountTokenMax = iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][1]).balanceOf(user);

        _requireNonZeroAmount(amount);
        _requireLicensed(tokenAddr);

        _beforeUpdate(tokenAddr);
        uint balBefore = IERC20(tokenAddr).balanceOf(lendingVault);
        IERC20(tokenAddr).safeTransferFrom(msg.sender,lendingVault,amount);
        uint balAfter = IERC20(tokenAddr).balanceOf(lendingVault);
        uint actualReceived = balAfter - balBefore;
        uint amountNormalize = _rawToNormalized(tokenAddr, actualReceived);

        if(amountNormalize > amountTokenMax){
            if(amountNormalize - amountTokenMax >= _rawToNormalized(tokenAddr, 1)) revert RepayExceedsDebt();
            amountNormalize = amountTokenMax;
        }

        if(userMode[user] == 1){
            _updateRIMAccounting(user, tokenAddr, amountNormalize, false);
        }

        iDepositOrLoanCoin(assetsDepositAndLend[tokenAddr][1]).burnCoin(user,amountNormalize);
        _assetsValueUpdate(tokenAddr);
        emit RepayLoan(tokenAddr, amount, user);
    }

    //------------------------------------------------------------------------------
    function executeFlashLoan(address useTokenAddr,
                              address borrowTokenAddr,
                              uint    borrowAmount,
                              address flashLoanUserContractAddr,
                              address user) external whenNotPaused nonReentrant {
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
        LendingManagerTypes.LicensedAsset storage depAsset = licensedAssets[depositToken];
        if (depAsset.assetAddr != depositToken) revert CollateralTokenNotLicensed();

        {
            uint balBefore = IERC20(liquidateToken).balanceOf(lendingVault);
            IERC20(liquidateToken).safeTransferFrom(msg.sender, lendingVault, liquidateAmount);
            uint balAfter = IERC20(liquidateToken).balanceOf(lendingVault);
            liquidateAmountNormalize = _rawToNormalized(liquidateToken, balAfter - balBefore);
        }
        if (liquidateAmountNormalize == 0) revert ZeroAmount();

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

        iDepositOrLoanCoin(assetsDepositAndLend[liquidateToken][1]).burnCoin(user,liquidateAmountNormalize);
        _decrementRIMDebt(user, liquidateToken, liquidateAmountNormalize);
        iDepositOrLoanCoin(assetsDepositAndLend[depositToken][0]).burnCoin(user,seizedCollateralNormalize);

        usedAmount = _normalizedToRaw(depositToken, seizedCollateralNormalize);
        if (receiveDepositCoin) {
            // M-02: enforce collateral-mode isolation on the liquidator
            uint8 liquidatorMode = userMode[msg.sender];
            if (liquidatorMode == 0) {
                if (licensedAssets[depositToken].maxLendingAmountInRIM != 0) revert WrongRIMToken();
            } else if (liquidatorMode == 1) {
                if (depositToken != userRIMAssetsAddress[msg.sender]) revert WrongRIMToken();
            } else {
                if (licensedAssets[depositToken].lendingModeNum != liquidatorMode) revert WrongHomogeneousMode();
            }
            iDepositOrLoanCoin(assetsDepositAndLend[depositToken][0]).mintCoin(msg.sender,seizedCollateralNormalize);
        } else {
            if (VaultTokensAmount(depositToken) < seizedCollateralNormalize) revert VaultInsufficient();
            iLendingVaults(lendingVault).vaultsERC20Approve(depositToken, usedAmount);
            IERC20(depositToken).safeTransferFrom(lendingVault, msg.sender, usedAmount);
        }

        _assetsValueUpdate(liquidateToken);
        _assetsValueUpdate(depositToken);
        _socializeBadDebt(user);

        // FR-H-01: Allow partial liquidation when HF is below 1e18.
        // High-LTV positions (e.g. LTV=97%, penalty=3%) can have HF decrease after
        // partial liquidation because the penalty seizes proportionally more collateral
        // than debt repaid. Blocking these liquidations causes insolvency.
        // New rule: if position is still underwater (HF < 1), only require that
        // the liquidation actually reduced debt (which the transfer already guarantees).
        // If HF >= 1, the position is healthy and no further liquidation is needed.
        uint healthFactorAfter = viewUsersHealthFactor(user);
        uint remainingDebt = LendingManagerLib.totalLendingValue(_loadAssetSnapshots(), user, oracleAddr);
        if (remainingDebt != 0 && healthFactorAfter < 1 ether) {
            // Position still underwater: only revert if HF got worse AND was already above 1
            // (i.e. liquidation of a healthy position). Since we checked HF < 1 above,
            // this branch always allows the liquidation — the position is insolvent and
            // any debt reduction is better than none.
            if (healthFactorBefore >= 1 ether && healthFactorAfter < healthFactorBefore) {
                revert LiquidationMustImproveHF();
            }
        }

        emit Liquidation(user, msg.sender, liquidateToken, depositToken, liquidateAmount, usedAmount);
    }

    function tokenLiquidate(address user,
                            address liquidateToken,
                            uint    liquidateAmount,
                            address depositToken) external whenNotPaused nonReentrant returns(uint usedAmount) {
        usedAmount = _tokenLiquidate(user, liquidateToken, liquidateAmount, depositToken, false);
    }

    function tokenLiquidateToDepositCoin(address user,
                                         address liquidateToken,
                                         uint    liquidateAmount,
                                         address depositToken) external whenNotPaused nonReentrant returns(uint usedAmount) {
        usedAmount = _tokenLiquidate(user, liquidateToken, liquidateAmount, depositToken, true);
    }

}
