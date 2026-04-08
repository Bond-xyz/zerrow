// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

import "../template/ERC20NoTransferUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../interfaces/iLendingManager.sol";
import "../interfaces/iRewardMini.sol";

/// @notice V2 of depositOrLoanCoin with new state variable.
/// Used to test beacon upgrade propagation across all token proxies.
contract DepositOrLoanCoinV2 is Initializable, ERC20NoTransferUpgradeable, ReentrancyGuardUpgradeable {
    address public manager;
    address public setter;
    address newsetter;
    address public OCoin;
    address public rewardContract;

    uint public depositOrLoan;
    uint public OQCtotalSupply;

    bool public mintlock;

    mapping(address=>uint) public userOQCAmount;

    // --- V2 NEW STATE ---
    uint256 public feeAccumulator;

    /// @dev Storage gap reduced by 1
    uint256[49] private __gap;

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

    event Mint(address indexed token, address mintAddress, uint amount);
    event Burn(address indexed token, address burnAddress, uint amount);
    event RecordUpdate(bool ToF, address _userAccount, uint _value);

    constructor() initializer {}

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

    /// @notice V2 new function
    function setFeeAccumulator(uint256 _fee) external onlySetter {
        feeAccumulator = _fee;
    }

    /// @notice V2 version identifier
    function version() external pure returns (string memory) {
        return "v2";
    }

    function mintLockerSetup(bool tOF) external onlySetter{
        mintlock = tOF;
    }

    function rewardContractSetup(address _rewardContract) external onlySetter{
        rewardContract = _rewardContract;
    }

    function mintCoin(address _account, uint256 _value) public onlyManager mintLocker nonReentrant{
        uint addTokens;
        require(_value > 0, "Deposit Or Loan Coin: Input value MUST > 0");
        require(_account != address(0), "Deposit Or Loan Coin: Cannot mint to zero address");
        require(_value <= type(uint256).max / 1 ether, "Deposit Or Loan Coin: Value too large");

        addTokens = iLendingManager(manager).getCoinValues(OCoin)[depositOrLoan];
        addTokens = _value * 1 ether / addTokens;
        userOQCAmount[_account] += addTokens;
        OQCtotalSupply += addTokens;

        try iRewardMini(rewardContract).recordUpdate(_account, userOQCAmount[_account]) returns (bool) {
            emit RecordUpdate(true, _account, userOQCAmount[_account]);
        } catch {
            emit RecordUpdate(false, _account, userOQCAmount[_account]);
        }

        emit Transfer(address(0), _account, _value);
        emit Mint(address(this), _account, _value);
    }

    function burnCoin(address _account, uint256 _value) public onlyManager nonReentrant{
        uint burnTokens;
        require(_value > 0, "Deposit Or Loan Coin: Con't burn 0");
        require(_value <= balanceOf(_account), "Deposit Or Loan Coin: Must <= account balance");

        burnTokens = iLendingManager(manager).getCoinValues(OCoin)[depositOrLoan];
        burnTokens = _value * 1 ether / burnTokens;
        if(userOQCAmount[_account] == burnTokens + 1) burnTokens += 1;
        if(userOQCAmount[_account] > burnTokens) userOQCAmount[_account] -= burnTokens;
        else userOQCAmount[_account] = 0;
        if(OQCtotalSupply > burnTokens) OQCtotalSupply -= burnTokens;
        else OQCtotalSupply = 0;

        try iRewardMini(rewardContract).recordUpdate(_account, userOQCAmount[_account]) returns (bool) {
            emit RecordUpdate(true, _account, userOQCAmount[_account]);
        } catch {
            emit RecordUpdate(false, _account, userOQCAmount[_account]);
        }

        emit Burn(address(this), _account, _value);
        emit Transfer(_account, address(0), _value);
    }

    function balanceOf(address account) public view virtual override returns (uint) {
        uint coinValue = iLendingManager(manager).getCoinValues(OCoin)[depositOrLoan];
        return coinValue * userOQCAmount[account] / 1 ether;
    }

    function totalSupply() public view virtual override returns (uint) {
        uint coinValue = iLendingManager(manager).getCoinValues(OCoin)[depositOrLoan];
        return coinValue * OQCtotalSupply / 1 ether;
    }
}
