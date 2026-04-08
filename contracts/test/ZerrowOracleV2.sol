// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice V2 of ZerrowOracle with new state variable
/// @custom:oz-upgrades-unsafe-allow constructor
contract ZerrowOracleV2 is Initializable, UUPSUpgradeable {
    address public setter;
    address newsetter;
    address st0gAdr;
    address public pythAddr;
    mapping(address => bytes32) public TokenToPythId;

    // --- V2 NEW STATE ---
    uint256 public priceDeviationThreshold;

    /// @dev Storage gap reduced by 1
    uint256[49] private __gap;

    modifier onlySetter() {
        require(msg.sender == setter, 'SLC Vaults: Only Manager Use');
        _;
    }

    constructor() initializer {}

    function initialize(address _setter) public initializer {
        __UUPSUpgradeable_init();
        setter = _setter;
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

    function TokenToPythIdSetup(address tokenAddress, bytes32 pythId) external onlySetter{
        TokenToPythId[tokenAddress] = pythId;
    }
}
