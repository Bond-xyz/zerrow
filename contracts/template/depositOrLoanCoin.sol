// SPDX-License-Identifier: Business Source License 1.1
// First Release Time : 2024.09.30

pragma solidity 0.8.6;

import "./ERC20NoTransferUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../interfaces/iLendingManager.sol";
import "../interfaces/iRewardMini.sol";

/// @notice depositOrLoanCoin is deployed behind a BeaconProxy.
/// Upgrade logic lives in the UpgradeableBeacon, not in this contract.
/// @dev `manager` was previously `immutable`. It is now a regular storage variable.
/// This means a new storage slot is used at position after `setter`. When migrating
/// from the old non-upgradeable layout, this slot was unused (it was not in storage
/// because immutable variables are stored in bytecode). For fresh deployments via
/// BeaconProxy + initialize(), storage layout is correct.
contract depositOrLoanCoin is Initializable, ERC20NoTransferUpgradeable, ReentrancyGuardUpgradeable {
    /// @dev Changed from `immutable` to regular storage for proxy compatibility.
    /// IMPORTANT: In the original contract, `manager` was immutable (stored in bytecode,
    /// not in storage). Converting to upgradeable means this now occupies a storage slot.
    /// For fresh BeaconProxy deployments this is fine. For migration of existing data,
    /// this slot was previously empty and will be set via initialize().
    address public manager;
    address public setter;
    address newsetter;
    address public OCoin;
    address public rewardContract;

    uint public depositOrLoan;
    uint public OQCtotalSupply; //OriginalQuantityCoin

    bool public mintlock;//0g added switch

    mapping(address=>uint) public userOQCAmount;

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;

    //----------------------------modifier ----------------------------
    modifier onlyManager() {
        require(msg.sender == manager, 'Deposit Or Loan Coin: Only Manager Use');
        _;
    }
    modifier onlySetter() {
        require(msg.sender == setter, 'Deposit Or Loan Coin: Only setter Use');
        _;
    }
    modifier mintLocker() {
        require(mintlock == false, 'Deposit Or Loan Coin: Mint function locked');
        _;
    }

    //----------------------------- event -----------------------------
    event Mint(address indexed token,address mintAddress, uint amount);
    event Burn(address indexed token,address burnAddress, uint amount);
    event RecordUpdate(bool ToF, address _userAccount,uint _value);

    /// @dev Disable initializer on implementation contract
    constructor() initializer {}

    /// @notice Replaces constructor for proxy deployment (called by BeaconProxy)
    function initialize(
        string memory _name,
        string memory _symbol,
        address _setter,
        address _OCoin,
        address _manager,
        uint _depositOrLoan,
        address _rewardContract
    ) public initializer {
        __ERC20NoTransfer_init(_name, _symbol);
        __ReentrancyGuard_init();
        setter = _setter;
        OCoin = _OCoin;
        manager = _manager;
        depositOrLoan = _depositOrLoan;
        rewardContract = _rewardContract;
        mintlock = false;
    }

    //-------------------------- sys function --------------------------

    function mintLockerSetup(bool tOF) external onlySetter{
        mintlock = tOF;
    }
    function rewardContractSetup(address _rewardContract) external onlySetter{
        rewardContract = _rewardContract;
    }
    function transferSetter(address _set) external onlySetter{
        require(_set != address(0),"Deposit Or Loan Coin: New setter cannot be zero address");
        require(_set != setter,"Lending Manager: Cannot transfer to current setter");
        newsetter = _set;
    }
    function acceptSetter(bool _TorF) external {
        require(msg.sender == newsetter, 'Deposit Or Loan Coin: Permission FORBIDDEN');
        if(_TorF){
            setter = newsetter;
        }
        newsetter = address(0);
    }
    //----------------------------- function -----------------------------

    /**
     * @dev mint
     */
    function mintCoin(address _account,uint256 _value) public onlyManager mintLocker nonReentrant{
        uint addTokens;
        require(_value > 0,"Deposit Or Loan Coin: Input value MUST > 0");
        require(_account != address(0),"Deposit Or Loan Coin: Cannot mint to zero address");
        require(_value <= type(uint256).max / 1 ether, "Deposit Or Loan Coin: Value too large");

        addTokens = iLendingManager(manager).getCoinValues(OCoin)[depositOrLoan];

        addTokens = _value * 1 ether / addTokens;
        userOQCAmount[_account] += addTokens;
        OQCtotalSupply += addTokens;

        try iRewardMini(rewardContract).recordUpdate(_account, userOQCAmount[_account]) returns (bool /*ok*/) {
            emit RecordUpdate(true, _account, userOQCAmount[_account]);
        } catch {
            emit RecordUpdate(false, _account, userOQCAmount[_account]);
        }

        emit Transfer(address(0), _account, _value);
        emit Mint(address(this), _account, _value);
    }
    /**
     * @dev burn
     */
    function burnCoin(address _account,uint256 _value) public onlyManager nonReentrant{
        uint burnTokens;
        require(_value > 0,"Deposit Or Loan Coin: Con't burn 0");
        require(_value <= balanceOf(_account),"Deposit Or Loan Coin: Must <= account balance");

        burnTokens = iLendingManager(manager).getCoinValues(OCoin)[depositOrLoan];

        burnTokens = _value * 1 ether / burnTokens;
        if(userOQCAmount[_account] == burnTokens + 1){
            burnTokens += 1;
        }
        if(userOQCAmount[_account] > burnTokens ){
            userOQCAmount[_account] -= burnTokens;
        }else{
            userOQCAmount[_account] = 0;
        }
        if(OQCtotalSupply > burnTokens ){
            OQCtotalSupply -= burnTokens;
        }else{
            OQCtotalSupply = 0;
        }

        try iRewardMini(rewardContract).recordUpdate(_account, userOQCAmount[_account]) returns (bool /*ok*/) {
            emit RecordUpdate(true, _account, userOQCAmount[_account]);
        } catch {
            emit RecordUpdate(false, _account, userOQCAmount[_account]);
        }

        emit Burn(address(this), _account, _value);
        emit Transfer(_account, address(0), _value);
    }

    //---------------------------------------------------------------------
    /**
     * @dev balance Of account will auto increase
     */
    function balanceOf(address account) public view virtual override returns (uint) {
        uint coinValue;
        coinValue = iLendingManager(manager).getCoinValues(OCoin)[depositOrLoan];
        return coinValue * userOQCAmount[account] / 1 ether;
    }
    /**
     * @dev balance Of totalSupply will auto increase
     */
    function totalSupply() public view virtual override returns (uint) {
        uint coinValue;
        coinValue = iLendingManager(manager).getCoinValues(OCoin)[depositOrLoan];
        return coinValue * OQCtotalSupply / 1 ether;
    }

}
