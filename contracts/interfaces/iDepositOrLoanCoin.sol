// SPDX-License-Identifier: Business Source License 1.1
// First Release Time : 2024.09.30

pragma solidity 0.8.6;

interface iDepositOrLoanCoin{
    function mintCoin(address _account,uint256 _value) external;
    function burnCoin(address _account,uint256 _value) external;
    function balanceOf(address account) external view returns (uint);
    function totalSupply() external view returns (uint);
    function mintLockerSetup(bool tOF) external;
    function rewardContractSetup(address _rewardContract) external;
    function transferSetter(address _set) external;
}
