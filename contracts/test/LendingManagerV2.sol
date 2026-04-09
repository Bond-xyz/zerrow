// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/islcoracle.sol";
import "../interfaces/iDecimals.sol";
import "../interfaces/iCoinFactory.sol";
import "../interfaces/iDepositOrLoanCoin.sol";
import "../interfaces/iLendingCoreAlgorithm.sol";
import "../interfaces/iLendingVaults.sol";
import "../interfaces/iUserFlashLoan.sol";

/// @notice V2 of LendingManager that adds a new state variable using the storage gap.
/// @custom:oz-upgrades-unsafe-allow constructor
contract LendingManagerV2 is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
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

    struct licensedAsset{
        address assetAddr;
        uint    maximumLTV;
        uint    liquidationPenalty;
        uint    bestLendingRatio;
        uint    bestDepositInterestRate;
        uint    maxLendingAmountInRIM;
        uint    reserveFactor;
        uint8   lendingModeNum;
        uint    homogeneousModeLTV;
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
    mapping(address => uint) public riskIsolationModeLendingNetAmount;
    mapping(address => address) public userRIMAssetsAddress;
    address public riskIsolationModeAcceptAssets;
    mapping(address => uint8) public userMode;

    // --- V2 NEW STATE: uses one slot from __gap ---
    uint256 public protocolFeeRate;

    /// @dev Storage gap reduced by 1 for the new state variable
    uint256[49] private __gap;

    modifier onlySetter() {
        require(msg.sender == setter, 'Lending Manager: Only Setter Use');
        _;
    }

    constructor() initializer {}

    function initialize(address _setter) public initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        setter = _setter;
        normalFloorOfHealthFactor = 1.2 ether;
        homogeneousFloorOfHealthFactor = 1.03 ether;
    }

    function _authorizeUpgrade(address) internal override {
        require(msg.sender == setter, "not setter");
    }

    function pause() external onlySetter {
        _pause();
    }

    function unpause() external onlySetter {
        _unpause();
    }

    /// @notice V2 new function: set protocol fee rate
    function setProtocolFeeRate(uint256 _rate) external onlySetter {
        require(_rate <= 1000, "fee rate too high");
        protocolFeeRate = _rate;
    }

    /// @notice V2 new function: returns version string
    function version() external pure returns (string memory) {
        return "v2";
    }

    // Keep essential view functions for state preservation verification
    function viewUsersHealthFactor(address) public pure returns(uint) {
        return 1000 ether;
    }

    function getCoinValues(address token) public view returns(uint[2] memory currentValue){
        uint tempVaule = (block.timestamp - assetInfos[token].latestTimeStamp) * 1 ether / (ONE_YEAR * UPPER_SYSTEM_LIMIT);
        currentValue[0] = assetInfos[token].latestDepositCoinValue
                        + tempVaule * assetInfos[token].latestDepositInterest;
        currentValue[1] = assetInfos[token].latestLendingCoinValue
                        + tempVaule * assetInfos[token].latestLendingInterest;
        if(currentValue[0] == 0) currentValue[0] = 1 ether;
        if(currentValue[1] == 0) currentValue[1] = 1 ether;
    }

    function assetsDepositAndLendAddrs(address token) public view returns(address[2] memory addrs){
        return assetsDepositAndLend[token];
    }

    function assetsReserveFactor(address token) public view returns(uint reserveFactor){
        return (licensedAssets[token].reserveFactor);
    }

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

    function licensedAssetAmount() public view returns(uint assetLength){
        assetLength = assetsSerialNumber.length;
    }

    function setup(address _coinFactory,
                   address _lendingVault,
                   address _riskIsolationModeAcceptAssets,
                   address _coreAlgorithm,
                   address _oracleAddr) external onlySetter{
        coinFactory = _coinFactory;
        oracleAddr = _oracleAddr;
        lendingVault = _lendingVault;
        coreAlgorithm = _coreAlgorithm;
        riskIsolationModeAcceptAssets = _riskIsolationModeAcceptAssets;
    }

    function setFloorOfHealthFactor(uint normal, uint homogeneous) external onlySetter{
        normalFloorOfHealthFactor = normal;
        homogeneousFloorOfHealthFactor = homogeneous;
    }
}
