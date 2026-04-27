// SPDX-License-Identifier: Business Source License 1.1
// First Release Time : 2024.09.30

pragma solidity 0.8.6;

interface iLendingManager{
    struct licensedAsset{
        address assetAddr;             
        uint    maximumLTV;               // loan-to-value (LTV) ratio is a measurement lenders use to compare your loan amount 
                                          // for a home against the value of that property.(MAX = UPPER_SYSTEM_LIMIT) 
        uint    liquidationPenalty;       // MAX = UPPER_SYSTEM_LIMIT/5 ,default is 500(5%)
        uint    bestLendingRatio;         // MAX = UPPER_SYSTEM_LIMIT , setting NOT more than 9000
        uint    bestDepositInterestRate ; // MAX = UPPER_SYSTEM_LIMIT , setting NOT more than 1000
        uint    maxLendingAmountInRIM;    // default is 0, means no limits; if > 0, have limits : 1 ether = 1 slc
        uint    reserveFactor;            //  default is 1000, (10%)
        uint8   lendingModeNum;           // Risk Isolation Mode: 1 ;  USDT  USDC : 2  ; 
        uint    homogeneousModeLTV;       // USDT  USDC : 97%  ; 
    }

    struct assetInfo{
        uint    latestDepositCoinValue;   // Relative to the initial DepositCoin value, the initial value is 1 ether
        uint    latestLendingCoinValue;   // Relative to the initial LendingCoin value, the initial value is 1 ether
        uint    latestDepositInterest;    // Latest interest value of DepositCoin
        uint    latestLendingInterest;    // Latest interest value of LendingCoin
        uint    latestTimeStamp;          // Latest TimeStamp
    }
    // uint public constant ONE_YEAR = 31536000;
    function ONE_YEAR() external view returns (uint);
    // uint public constant UPPER_SYSTEM_LIMIT = 10000;
    function UPPER_SYSTEM_LIMIT() external view returns (uint);
    function LIQUIDATION_CLOSE_FACTOR() external view returns (uint);

    // uint    public normalFloorOfHealthFactor;
    function normalFloorOfHealthFactor() external view returns (uint);
    // uint    public homogeneousFloorOfHealthFactor;
    function homogeneousFloorOfHealthFactor() external view returns (uint);


    // mapping(address => licensedAsset) public licensedAssets;
    function licensedAssets(address) external view returns (licensedAsset memory);
    // mapping(address => address[2]) assetsDepositAndLend;
    function assetsDepositAndLendAddrs(address) external view returns (address[2] memory);
    // address[] public assetsSerialNumber;
    function assetsSerialNumber(uint) external view returns(address);
    // address  public lendingInterface;
    function lendingInterface() external view returns (address);
    // mapping(address => assetInfo) public assetInfos;
    // function assetInfos(address) external view returns (assetInfo memory);
    // mapping(address => mapping(address => uint)) public userRIMAssetsLendingNetAmount;
    function userRIMAssetsLendingNetAmount(address,address) external view returns (uint);
    // mapping(address => uint) public riskIsolationModeLendingNetAmount; //RIM  Risk Isolation Mode
    function riskIsolationModeLendingNetAmount(address) external view returns (uint);
    // mapping(address => address) public userRIMAssetsAddress; 
    function userRIMAssetsAddress(address user) external view returns(address);
    // address public riskIsolationModeAcceptAssets;
    function riskIsolationModeAcceptAssets() external view returns(address);
    // mapping(address => uint8) public userMode;
    function userMode(address user) external view returns(uint8);

    function getCoinValues(address token) external view returns (uint[2] memory price);
    function viewUsersHealthFactor(address user) external view returns(uint userHealthFactor);
    // function viewUserLendableLimit(address user) external view returns(uint userLendableLimit);
    // function assetsLiqPenaltyInfo(address token) external view returns(uint liqPenalty);

    function assetsReserveFactor(address token) external view returns(uint reserveFactor);
    // function assetsBaseInfo(address token) external view returns(uint maximumLTV,uint bestLendingRatio,uint lendingModeNum,uint bestDepositInterestRate);
    function assetsBaseInfo(address token) external view returns(uint maximumLTV,
                                                               uint liquidationPenalty,
                                                               uint maxLendingAmountInRIM,
                                                               uint bestLendingRatio,
                                                               uint lendingModeNum,
                                                               uint homogeneousModeLTV,
                                                               uint bestDepositInterestRate);
    function assetsTimeDependentParameter(address token) external view returns(uint latestDepositCoinValue,
                                                                   uint latestLendingCoinValue,
                                                                   uint latestDepositInterest,
                                                                   uint latestLendingInterest);
    function licensedAssetAmount() external view returns(uint assetLength);
    function VaultTokensAmount(address tokenAddr) external view returns(uint maxAmount);
    // function licensedAssetPrice() external view returns(uint[] memory assetPrice);
    // function licensedAssetOverview() external view returns(uint totalValueOfMortgagedAssets, uint totalValueOfLendedAssets);
    function userDepositAndLendingValue(address user) external view returns(uint _amountDeposit,uint _amountLending);
    function userAssetOverview(address user) external view returns(address[] memory tokens,
                                                                   uint[] memory _amountDeposit, 
                                                                   uint[] memory _amountLending);

    // function usersHealthFactorEstimate(address user,
    //                                    address token,
    //                                    uint amount,
    //                                    uint operator) external view returns(uint userHealthFactor);

    //Operation
    function userModeSetting(uint8 _mode,address _userRIMAssetsAddress, address user) external;
    //  Assets Deposit
    function assetsDeposit(address tokenAddr, uint amount, address user) external;
    // Withdrawal of deposits
    function withdrawDeposit(address tokenAddr, uint amount, address user) external ;
    // lend Asset
    function lendAsset(address tokenAddr, uint amount, address user) external;
    // repay Loan
    function repayLoan(address tokenAddr,uint amount, address user) external ;
        
    // interface approvals for whitelisted callers
    function setInterfaceApproval(bool approved) external;
    function interfaceApproval(address user, address iface) external view returns (bool);

    // FlashLoan
    function executeFlashLoan(address useTokenAddr,
                              address borrowTokenAddr,
                              uint    borrowAmount,
                              address flashLoanUserContractAddr,
                              address user)  external;

    // token Liquidate
    function tokenLiquidate(address user,
                            address liquidateToken,
                            uint    liquidateAmount, 
                            address depositToken) external returns(uint usedAmount) ;
    function tokenLiquidateToDepositCoin(address user,
                                         address liquidateToken,
                                         uint    liquidateAmount,
                                         address depositToken) external returns(uint usedAmount) ;
    // function tokenLiquidateEstimate(address user,
    //                         address liquidateToken,
    //                         address depositToken) external view returns(uint[2] memory maxAmounts);

}
