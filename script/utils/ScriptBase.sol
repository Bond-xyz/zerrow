// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

interface Vm {
    function envUint(string calldata name) external view returns (uint256 value);
    function envAddress(string calldata name) external view returns (address value);
    function envString(string calldata name) external view returns (string memory value);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
    function addr(uint256 privateKey) external view returns (address addrValue);
    function toString(uint256 value) external pure returns (string memory stringValue);
    function toString(address value) external pure returns (string memory stringValue);
    function projectRoot() external view returns (string memory path);
    function writeFile(string calldata path, string calldata data) external;
    function readFile(string calldata path) external view returns (string memory data);
    function parseJsonUint(string calldata json, string calldata key) external pure returns (uint256 value);
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address value);
    function parseJsonString(string calldata json, string calldata key) external pure returns (string memory value);
    function parseJsonBool(string calldata json, string calldata key) external pure returns (bool value);
}

abstract contract ScriptBase {
    address internal constant VM_ADDRESS =
        address(bytes20(uint160(uint256(keccak256("hevm cheat code")))));

    Vm internal constant vm = Vm(VM_ADDRESS);
}
