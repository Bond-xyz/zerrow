// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice V2 of CoinFactory with new state variable
/// @custom:oz-upgrades-unsafe-allow constructor
contract CoinFactoryV2 is Initializable, UUPSUpgradeable {
    address public setPermissionAddress;
    address newPermissionAddress;
    address public lendingManager;
    address public rewardContract;
    uint public depositType;
    uint public loanType;
    mapping(address => address) public getDepositCoin;
    mapping(address => address) public getLoanCoin;
    address public beacon;

    // --- V2 NEW STATE ---
    uint256 public maxTokensPerAsset;

    /// @dev Storage gap reduced by 1
    uint256[49] private __gap;

    constructor() initializer {}

    function initialize(address _admin) public initializer {
        __UUPSUpgradeable_init();
        setPermissionAddress = _admin;
    }

    function _authorizeUpgrade(address) internal override {
        require(msg.sender == setPermissionAddress, "not admin");
    }

    /// @notice V2 new function
    function setMaxTokensPerAsset(uint256 _max) external {
        require(msg.sender == setPermissionAddress, 'Coin Factory: Permission FORBIDDEN');
        maxTokensPerAsset = _max;
    }

    /// @notice V2 version identifier
    function version() external pure returns (string memory) {
        return "v2";
    }

    function settings(address _lendingManager, address _rewardContract) external {
        require(msg.sender == setPermissionAddress, 'Coin Factory: Permission FORBIDDEN');
        lendingManager = _lendingManager;
        rewardContract = _rewardContract;
    }

    function setBeacon(address _beacon) external {
        require(msg.sender == setPermissionAddress, 'Coin Factory: Permission FORBIDDEN');
        beacon = _beacon;
    }

    function rewardTypeSetup(uint _depositType, uint _loanType) external {
        require(msg.sender == setPermissionAddress, 'Coin Factory: Permission FORBIDDEN');
        depositType = _depositType;
        loanType = _loanType;
    }
}
