// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "ds-test/test.sol";

interface Vm {
    function expectRevert() external;
    function expectRevert(bytes memory revertData) external;
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function warp(uint256 newTimestamp) external;
    function mockCall(address callee, bytes memory data, bytes memory returnData) external;
}

abstract contract TestBase is DSTest {
    address internal constant VM_ADDRESS =
        address(bytes20(uint160(uint256(keccak256("hevm cheat code")))));

    Vm internal constant vm = Vm(VM_ADDRESS);

    function assertFalse(bool condition) internal {
        assertTrue(!condition);
    }

    function assertFalse(bool condition, string memory err) internal {
        assertTrue(!condition, err);
    }
}
