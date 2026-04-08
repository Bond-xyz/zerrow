// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice V2 of LendingVaults with new state variable from storage gap
/// @custom:oz-upgrades-unsafe-allow constructor
contract LendingVaultsV2 is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    address public lendingManager;
    address public setter;
    address newsetter;
    address public rebalancer;

    using SafeERC20 for IERC20;

    // --- V2 NEW STATE ---
    uint256 public maxWithdrawPerBlock;

    /// @dev Storage gap reduced by 1
    uint256[49] private __gap;

    modifier onlySetter() {
        require(msg.sender == setter, 'Lending Vault: Only Setter Use');
        _;
    }

    constructor() initializer {}

    function initialize(address _setter) public initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        setter = _setter;
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

    /// @notice V2 new function
    function setMaxWithdrawPerBlock(uint256 _max) external onlySetter {
        maxWithdrawPerBlock = _max;
    }

    /// @notice V2 version identifier
    function version() external pure returns (string memory) {
        return "v2";
    }

    function setManager(address _manager) external onlySetter{
        lendingManager = _manager;
    }

    function setRebalancer(address _rebalancer) external onlySetter{
        rebalancer = _rebalancer;
    }

    function vaultsERC20Approve(address ERC20Addr, uint amount) external {
        require(msg.sender == lendingManager, 'Lending Vault: Only Setter Use');
        IERC20(ERC20Addr).safeIncreaseAllowance(lendingManager, amount);
    }

    fallback() external payable {}
    receive() external payable {}
}
