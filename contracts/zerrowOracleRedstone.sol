// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "./interfaces/iAggregatorV3.sol";
import "./interfaces/iLstGimo.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @custom:oz-upgrades-unsafe-allow constructor
contract zerrowOracleRedstone is Initializable, UUPSUpgradeable {
    address public setter;
    address newsetter;
    address public st0gAdr;

    // Max allowed age for a price update before it's considered stale
    uint public maxStaleness;

    // token address => Redstone PriceFeed contract address
    mapping(address => address) public tokenToFeed;

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;

    modifier onlySetter() {
        require(msg.sender == setter, "Zerrow Oracle: Only Setter");
        _;
    }

    /// @dev Disable initializer on implementation contract
    constructor() initializer {}

    /// @notice Replaces constructor for proxy deployment
    function initialize(address _setter) public initializer {
        __UUPSUpgradeable_init();
        setter = _setter;
        maxStaleness = 25200; // 7 hours (Redstone 0G heartbeat is 6h)
        st0gAdr = address(0x7bBC63D01CA42491c3E084C941c3E86e55951404);
    }

    /// @dev Required by UUPSUpgradeable
    function _authorizeUpgrade(address) internal override {
        require(msg.sender == setter, "not setter");
    }

    // ======================== Admin ========================

    function transferSetter(address _set) external onlySetter {
        newsetter = _set;
    }

    function acceptSetter(bool _TorF) external {
        require(msg.sender == newsetter, "Zerrow Oracle: Permission FORBIDDEN");
        if (_TorF) {
            setter = newsetter;
        }
        newsetter = address(0);
    }

    function setTokenFeed(address token, address feed) external onlySetter {
        tokenToFeed[token] = feed;
    }

    function setTokenFeedBatch(
        address[] calldata tokens,
        address[] calldata feeds
    ) external onlySetter {
        require(tokens.length == feeds.length, "Zerrow Oracle: Length mismatch");
        for (uint i = 0; i < tokens.length; i++) {
            tokenToFeed[tokens[i]] = feeds[i];
        }
    }

    function setMaxStaleness(uint _maxStaleness) external onlySetter {
        require(_maxStaleness >= 3600, "Zerrow Oracle: Min staleness 1 hour");
        maxStaleness = _maxStaleness;
    }

    function setSt0gAdr(address _st0gAdr) external onlySetter {
        st0gAdr = _st0gAdr;
    }

    // ======================== Price ========================

    function getRedstonePrice(address token) public view returns (uint price) {
        address feed = tokenToFeed[token];
        require(feed != address(0), "Zerrow Oracle: No feed for token");

        (
            ,
            int256 answer,
            ,
            uint256 updatedAt,

        ) = AggregatorV3Interface(feed).latestRoundData();

        require(answer > 0, "Zerrow Oracle: Invalid price");
        require(
            block.timestamp - updatedAt <= maxStaleness,
            "Zerrow Oracle: Stale price"
        );

        uint8 feedDecimals = AggregatorV3Interface(feed).decimals();
        // Normalize to 18 decimals (1 ether = 1 USD)
        price = uint256(answer) * (10 ** (18 - feedDecimals));
    }

    function getPrice(address token) external view returns (uint price) {
        if (token == st0gAdr) {
            price = getRedstonePrice(token) * iLstGimo(st0gAdr).getRate() / 1 ether;
        } else {
            price = getRedstonePrice(token);
        }
        require(price > 0, "Zerrow Oracle: Zero price");
        return price;
    }

    // ======================== View Helpers ========================

    function getPriceRaw(address token)
        external
        view
        returns (
            int256 answer,
            uint256 updatedAt,
            uint8 feedDecimals
        )
    {
        address feed = tokenToFeed[token];
        require(feed != address(0), "Zerrow Oracle: No feed for token");

        (, answer, , updatedAt, ) = AggregatorV3Interface(feed)
            .latestRoundData();
        feedDecimals = AggregatorV3Interface(feed).decimals();
    }

    function isFeedStale(address token) external view returns (bool) {
        address feed = tokenToFeed[token];
        if (feed == address(0)) return true;

        (, , , uint256 updatedAt, ) = AggregatorV3Interface(feed)
            .latestRoundData();
        return block.timestamp - updatedAt > maxStaleness;
    }

    // ======================== Recovery ========================

    function nativeTokenReturn() external onlySetter {
        uint amount = address(this).balance;
        address payable receiver = payable(msg.sender);
        (bool success, ) = receiver.call{value: amount}("");
        require(success, "Zerrow Oracle: 0G Transfer Failed");
    }

    fallback() external payable {}
    receive() external payable {}
}
