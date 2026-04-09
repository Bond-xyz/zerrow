// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice V2 of zerrowOracleRedstone with new state variable
/// @custom:oz-upgrades-unsafe-allow constructor
contract ZerrowOracleRedstoneV2 is Initializable, UUPSUpgradeable {
    // --- V1 STATE (must match zerrowOracleRedstone storage layout) ---
    address public setter;
    address newsetter;
    address public st0gAdr;
    uint public maxStaleness;
    mapping(address => address) public tokenToFeed;

    // --- V2 NEW STATE ---
    uint256 public priceDeviationThreshold;

    /// @dev Storage gap reduced by 1
    uint256[49] private __gap;

    modifier onlySetter() {
        require(msg.sender == setter, "Zerrow Oracle: Only Setter");
        _;
    }

    constructor() initializer {}

    function initialize(address _setter) public initializer {
        __UUPSUpgradeable_init();
        setter = _setter;
        maxStaleness = 25200;
    }

    function _authorizeUpgrade(address) internal override {
        require(msg.sender == setter, "not setter");
    }

    /// @notice V2 new function
    function setPriceDeviationThreshold(uint256 _threshold) external onlySetter {
        priceDeviationThreshold = _threshold;
    }

    /// @notice V2 version identifier
    function version() external pure returns (string memory) {
        return "v2";
    }

    function setTokenFeed(address token, address feed) external onlySetter {
        tokenToFeed[token] = feed;
    }
}
