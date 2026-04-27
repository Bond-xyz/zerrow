// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "../lstInterface.sol";

contract LstInterfaceV2 is lstInterface {
    uint256 public upgradeMarker;

    function version() external pure returns (string memory) {
        return "v2";
    }

    function setUpgradeMarker(uint256 _marker) external {
        require(msg.sender == admin, "not admin");
        upgradeMarker = _marker;
    }
}
