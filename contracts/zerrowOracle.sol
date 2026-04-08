// contracts/GameItems.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/iLstGimo.sol";

/// @custom:oz-upgrades-unsafe-allow constructor
contract zerrowOracle is Initializable, UUPSUpgradeable {
    address public setter;
    address newsetter;
    address st0gAdr;
    //--------------------------pyth Used Paras--------------------------
    address public  pythAddr;
    mapping(address => bytes32) public TokenToPythId;

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;

    //----------------------------modifier ----------------------------
    modifier onlySetter() {
        require(msg.sender == setter, 'SLC Vaults: Only Manager Use');
        _;
    }
    //------------------------------------ ----------------------------

    /// @dev Disable initializer on implementation contract
    constructor() initializer {}

    /// @notice Replaces constructor for proxy deployment
    function initialize(address _setter) public initializer {
        __UUPSUpgradeable_init();
        setter = _setter;
        pythAddr = address(0x2880aB155794e7179c9eE2e38200202908C17B43);
        st0gAdr = address(0x7bBC63D01CA42491c3E084C941c3E86e55951404);

        TokenToPythId[address(0x1f3AA82227281cA364bFb3d253B0f1af1Da6473E)] = bytes32(0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a);
        TokenToPythId[address(0x1Cd0690fF9a693f5EF2dD976660a8dAFc81A109c)]= bytes32(0xfa9e8d4591613476ad0961732475dc08969d248faca270cc6c47efe009ea3070);
        TokenToPythId[address(0x7bBC63D01CA42491c3E084C941c3E86e55951404)] = bytes32(0xfa9e8d4591613476ad0961732475dc08969d248faca270cc6c47efe009ea3070);
    }

    /// @dev Required by UUPSUpgradeable
    function _authorizeUpgrade(address) internal override {
        require(msg.sender == setter, "not setter");
    }

    function transferSetter(address _set) external onlySetter{
        newsetter = _set;
    }
    function acceptSetter(bool _TorF) external {
        require(msg.sender == newsetter, 'SLC Vaults: Permission FORBIDDEN');
        if(_TorF){
            setter = newsetter;
        }
        newsetter = address(0);
    }
    function setup( address _pythAddr ) external onlySetter{
        pythAddr = _pythAddr;
    }

    function TokenToPythIdSetup(address tokenAddress, bytes32 pythId) external onlySetter{
        TokenToPythId[tokenAddress] = pythId;
    }
    //-----------------------------------Special token handling----------------------------------------


    //-----------------------------------Pyth Used functions-------------------------------------------

    function getPythBasicPrice(bytes32 id) internal view returns (PythStructs.Price memory price){
        price = IPyth(pythAddr).getPriceUnsafe(id);
        require(price.price > 0, "Oracle: zero price from Pyth");
    }

    function pythPriceUpdate(bytes[] calldata updateData) public payable {
        uint fee = IPyth(pythAddr).getUpdateFee( updateData);
        IPyth(pythAddr).updatePriceFeeds{ value: fee }(updateData);
    }

    function getPythPrice(address token) public view returns (uint price){
        PythStructs.Price memory priceBasic;
        uint tempPriceExpo ;
        require(TokenToPythId[token] != bytes32(0), "Oracle: no Pyth ID for token");
        priceBasic = getPythBasicPrice(TokenToPythId[token]);
        tempPriceExpo = uint(int256(18+priceBasic.expo));
        price = uint(int256(priceBasic.price)) * (10**tempPriceExpo);
    }

    function getPrice(address token) external view returns (uint price){
        if(token == st0gAdr){
            price = getPythPrice(token) * iLstGimo(st0gAdr).getRate() / 1 ether;
        }
        else{
            price = getPythPrice(token);
        }
        require(price > 0, "Oracle: zero price");
        return price;
    }

    //  Native token return
    function  nativeTokenReturn() external onlySetter {
        uint amount = address(this).balance;
        address payable receiver = payable(msg.sender);
        (bool success, ) = receiver.call{value:amount}("");
        require(success,"Zerrow Oracle: 0G Transfer Failed");
    }
    // ======================== contract base methods =====================
    fallback() external payable {}
    receive() external payable {}

}
