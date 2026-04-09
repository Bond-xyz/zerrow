// SPDX-License-Identifier: Business Source License 1.1
// First Release Time : 2025.03.30

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/iDepositOrLoanCoin.sol";
import "./interfaces/iLendingManager.sol";
import "./interfaces/iDecimals.sol";

/// @custom:oz-upgrades-unsafe-allow constructor
contract lendingVaults is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    address public lendingManager;

    address public setter;
    address newsetter;
    address public rebalancer;

    using SafeERC20 for IERC20;

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;

    /// @dev Disable initializer on implementation contract
    constructor() initializer {}

    /// @notice Replaces constructor for proxy deployment
    function initialize(address _setter) public initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        setter = _setter;
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

    //----------------------------modifier ----------------------------

    modifier onlySetter() {
        require(msg.sender == setter, 'Lending Vault: Only Setter Use');
        _;
    }
    modifier onlyManager() {
        require(msg.sender == lendingManager, 'Lending Vault: Only Setter Use');
        _;
    }
    modifier onlyRebalancer() {
        require(msg.sender == rebalancer, 'Lending Vault: Only Rebalancer Use');
        _;
    }

    //----------------------------        ----------------------------
    function transferSetter(address _set) external onlySetter{
        require(_set != address(0),"Lending Vault: New setter cannot be zero address");
        require(_set != setter,"Lending Vault: Cannot transfer to current setter");
        newsetter = _set;
    }
    function acceptSetter(bool _TorF) external {
        require(msg.sender == newsetter, 'Lending Vault: Permission FORBIDDEN');
        if(_TorF){
            setter = newsetter;
        }
        newsetter = address(0);
    }
    function setManager(address _manager) external onlySetter{
        require(_manager != address(0), "Lending Vault: Manager cannot be zero");
        lendingManager = _manager;
    }
    function setRebalancer(address _rebalancer) external onlySetter{
        require(_rebalancer != address(0), "Lending Vault: Rebalancer cannot be zero");
        rebalancer = _rebalancer;
    }

    function excessDisposal(address token) public whenNotPaused nonReentrant onlyRebalancer(){
        address[2] memory pair = iLendingManager(lendingManager).assetsDepositAndLendAddrs(token);
        uint amountD18 = iDepositOrLoanCoin(pair[0]).totalSupply();
        uint amountL18 = iDepositOrLoanCoin(pair[1]).totalSupply();

        uint netNorm18 = amountD18 - amountL18;
        uint d = iDecimals(token).decimals();
        uint balRaw = IERC20(token).balanceOf(address(this));
        uint balNorm18 = (balRaw * 1 ether) / (10 ** d);

        require(balNorm18 > netNorm18,"Lending Vault: Cant Do Excess Disposal, asset not enough!");
        uint exNorm18 = balNorm18 - netNorm18;
        uint exRaw = (exNorm18 * (10 ** d)) / 1 ether;
        IERC20(token).safeTransfer(msg.sender, exRaw);
    }

    function vaultsERC20Approve(address ERC20Addr,uint amount) external whenNotPaused onlyManager{
        IERC20(ERC20Addr).safeIncreaseAllowance(lendingManager,amount);
    }

    function transferNativeToken(address _to) external nonReentrant onlySetter{
        if(address(this).balance>0){
            address payable receiver = payable(_to); // Set receiver
            (bool success, ) = receiver.call{value:address(this).balance}("");
            require(success,"Lending Vault: 0g Transfer Failed");
        }
    }

    // ======================== contract base methods =====================
    fallback() external payable {}
    receive() external payable {}

}
