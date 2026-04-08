// SPDX-License-Identifier: Business Source License 1.1
// First Release Time : 2025.03.30
pragma solidity 0.8.6;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import './template/depositOrLoanCoin.sol';
import "./interfaces/iRewardMini.sol";

/// @custom:oz-upgrades-unsafe-allow constructor
contract coinFactory is Initializable, UUPSUpgradeable {
    //----------------------Persistent Variables ----------------------
    address public setPermissionAddress;
    address newPermissionAddress;
    address public lendingManager;
    address public rewardContract;
    uint public depositType;
    uint public loanType;
    mapping(address => address) public getDepositCoin;
    mapping(address => address) public getLoanCoin;

    /// @notice UpgradeableBeacon address for depositOrLoanCoin instances
    address public beacon;

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;

    //----------------------------- event -----------------------------
    event DepositCoinCreated(address indexed token, address DepositCoin);
    event LoanCoinCreatedX(address indexed token, address LoanCoin);

    /// @dev Disable initializer on implementation contract
    constructor() initializer {}

    /// @notice Replaces constructor for proxy deployment
    function initialize(address _admin) public initializer {
        __UUPSUpgradeable_init();
        setPermissionAddress = _admin;
    }

    /// @dev Required by UUPSUpgradeable
    function _authorizeUpgrade(address) internal override {
        require(msg.sender == setPermissionAddress, "not admin");
    }

    /// @notice Set the UpgradeableBeacon address for depositOrLoanCoin
    function setBeacon(address _beacon) external {
        require(msg.sender == setPermissionAddress, 'Coin Factory: Permission FORBIDDEN');
        require(_beacon != address(0), 'Coin Factory: Zero Address Not Allowed');
        beacon = _beacon;
    }

    //----------------------------- functions -----------------------------
    function createDeAndLoCoin(address token) external returns (address[2] memory _pAndLCoin) {
        require(msg.sender == lendingManager, 'Coin Factory: msg.sender MUST be lendingManager.');
        require(token != address(0), 'Coin Factory: ZERO_ADDRESS');
        require(getDepositCoin[token] == address(0), 'Coin Factory: COIN_EXISTS');// single check is sufficient
        require(lendingManager != address(0), 'Coin Factory: Coin manager NOT Set');
        require(rewardContract != address(0), 'Coin Factory: Reward Contract NOT Set');
        require(depositType != 0, 'Coin Factory: Reward Type NOT Set');
        require(beacon != address(0), 'Coin Factory: Beacon NOT Set');

        string memory depositName = strConcat(string(ERC20(token).symbol()), " Zerrow Deposit Coin V1");
        string memory depositSymbol = strConcat(string(ERC20(token).symbol()), " ZDCoin V1");
        string memory loanName = strConcat(string(ERC20(token).symbol()), " Zerrow Loan Coin V1");
        string memory loanSymbol = strConcat(string(ERC20(token).symbol()), " ZLCoin V1");

        // Deploy deposit coin as BeaconProxy
        bytes memory depositInitData = abi.encodeWithSelector(
            depositOrLoanCoin.initialize.selector,
            depositName,
            depositSymbol,
            msg.sender, // setter = lendingManager deployer (will be transferred)
            token,
            lendingManager,
            0, // depositOrLoan = 0 (deposit)
            rewardContract
        );
        _pAndLCoin[0] = address(new BeaconProxy(beacon, depositInitData));

        // Deploy loan coin as BeaconProxy
        bytes memory loanInitData = abi.encodeWithSelector(
            depositOrLoanCoin.initialize.selector,
            loanName,
            loanSymbol,
            msg.sender, // setter
            token,
            lendingManager,
            1, // depositOrLoan = 1 (loan)
            rewardContract
        );
        _pAndLCoin[1] = address(new BeaconProxy(beacon, loanInitData));

        getDepositCoin[token] = _pAndLCoin[0];
        getLoanCoin[token] = _pAndLCoin[1];
        iRewardMini(rewardContract).factoryUsedRegister(_pAndLCoin[0], depositType);
        iRewardMini(rewardContract).factoryUsedRegister(_pAndLCoin[1], loanType);
        emit DepositCoinCreated( token, _pAndLCoin[0]);
        emit LoanCoinCreatedX( token, _pAndLCoin[1]);
    }

    function strConcat(string memory _str1, string memory _str2) internal pure returns (string memory) {
        return string(abi.encodePacked(_str1, _str2));
    }
    function name(address token) public view returns (string memory) {
        return string(ERC20(token).name());
    }

    //--------------------------- Setup functions --------------------------

    function settings(address _lendingManager,address _rewardContract) external {
        require(msg.sender == setPermissionAddress, 'Coin Factory: Permission FORBIDDEN');
        lendingManager = _lendingManager;
        rewardContract = _rewardContract;
    }

    function coinResetup(address coinAddr,address _rewardContract) external {
        require(msg.sender == setPermissionAddress, 'Coin Factory: Permission FORBIDDEN');
        depositOrLoanCoin(coinAddr).rewardContractSetup(_rewardContract);
    }
    function coinMintLockerSetup(address coinAddr, bool tOF) external {
        require(msg.sender == setPermissionAddress, 'Coin Factory: Permission FORBIDDEN');
        depositOrLoanCoin(coinAddr).mintLockerSetup(tOF);
    }
    function rewardTypeSetup(uint _depositType,uint _loanType) external {
        require(msg.sender == setPermissionAddress, 'Coin Factory: Permission FORBIDDEN');
        require(_depositType * _loanType > 0, 'Coin Factory: Type Must > 0');
        require(_depositType != _loanType, 'Coin Factory: depositType and loanType Must NOT same');
        require(_depositType > 0 && _depositType <= 10000,"Coin Factory: Invalid deposit type");
        require(_loanType > 0 && _loanType <= 10000,"Coin Factory: Invalid loan type");
        depositType = _depositType;
        loanType = _loanType;
    }

    function setPA(address _setPermissionAddress) external {
        require(msg.sender == setPermissionAddress, 'Coin Factory: Permission FORBIDDEN');
        require(_setPermissionAddress != address(0),'Coin Factory: Zero Address Not Allowed');
        newPermissionAddress = _setPermissionAddress;
    }
    function acceptPA(bool _TorF) external {
        require(msg.sender == newPermissionAddress, 'Coin Factory: Permission FORBIDDEN');
        if(_TorF){
            setPermissionAddress = newPermissionAddress;
        }
        newPermissionAddress = address(0);
    }

}
