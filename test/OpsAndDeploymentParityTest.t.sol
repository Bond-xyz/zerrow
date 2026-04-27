// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "./utils/TestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../contracts/lendingInterface.sol";
import "../contracts/lstInterface.sol";
import "../contracts/test/LendingInterfaceV2.sol";
import "../contracts/test/LstInterfaceV2.sol";

contract LendingInterfaceAdminTransferTest is TestBase {
    lendingInterface public impl;
    ERC1967Proxy public proxy;
    lendingInterface public iface;

    address public newAdmin = address(0xBEEF);

    function setUp() public {
        impl = new lendingInterface();
        bytes memory initData = abi.encodeWithSelector(
            lendingInterface.initialize.selector,
            address(0x100),
            address(0x200),
            address(0x300),
            address(0x400)
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        iface = lendingInterface(payable(address(proxy)));
    }

    function test_InitializeSetsAdminToDeployer() public {
        assertEq(iface.admin(), address(this));
        assertEq(iface.pendingAdmin(), address(0));
    }

    function test_AdminTransferAndUpgradeFlow() public {
        iface.transferAdmin(newAdmin);
        assertEq(iface.pendingAdmin(), newAdmin);

        vm.prank(newAdmin);
        iface.acceptAdmin(true);

        assertEq(iface.admin(), newAdmin);
        assertEq(iface.pendingAdmin(), address(0));

        LendingInterfaceV2 implV2 = new LendingInterfaceV2();

        vm.expectRevert("not admin");
        iface.upgradeTo(address(implV2));

        vm.prank(newAdmin);
        iface.upgradeTo(address(implV2));

        LendingInterfaceV2 ifaceV2 = LendingInterfaceV2(payable(address(proxy)));
        assertEq(ifaceV2.admin(), newAdmin);
        assertEq(ifaceV2.lendingManager(), address(0x100));
        assertEq(ifaceV2.W0G(), address(0x200));
        assertEq(ifaceV2.oracleAddr(), address(0x300));
        assertEq(ifaceV2.lCoreAddr(), address(0x400));
        assertEq(ifaceV2.version(), "v2");

        vm.prank(newAdmin);
        ifaceV2.setUpgradeMarker(42);
        assertEq(ifaceV2.upgradeMarker(), 42);
    }
}

contract LstInterfaceAdminTransferTest is TestBase {
    lstInterface public impl;
    ERC1967Proxy public proxy;
    lstInterface public iface;

    address public newAdmin = address(0xCAFE);

    function setUp() public {
        impl = new lstInterface();
        bytes memory initData = abi.encodeWithSelector(
            lstInterface.initialize.selector,
            address(0x100),
            address(0x200),
            address(0x300),
            address(0x400),
            address(0x500),
            address(0x600)
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        iface = lstInterface(payable(address(proxy)));
    }

    function test_InitializeSetsAdminToDeployer() public {
        assertEq(iface.admin(), address(this));
        assertEq(iface.pendingAdmin(), address(0));
    }

    function test_AdminTransferAndUpgradeFlow() public {
        iface.transferAdmin(newAdmin);
        assertEq(iface.pendingAdmin(), newAdmin);

        vm.prank(newAdmin);
        iface.acceptAdmin(true);

        assertEq(iface.admin(), newAdmin);
        assertEq(iface.pendingAdmin(), address(0));

        LstInterfaceV2 implV2 = new LstInterfaceV2();

        vm.expectRevert("not admin");
        iface.upgradeTo(address(implV2));

        vm.prank(newAdmin);
        iface.upgradeTo(address(implV2));

        LstInterfaceV2 ifaceV2 = LstInterfaceV2(payable(address(proxy)));
        assertEq(ifaceV2.admin(), newAdmin);
        assertEq(ifaceV2.lendingManager(), address(0x100));
        assertEq(ifaceV2.W0G(), address(0x200));
        assertEq(ifaceV2.lCoreAddr(), address(0x300));
        assertEq(ifaceV2.oracleAddr(), address(0x400));
        assertEq(ifaceV2.lstGimo(), address(0x500));
        assertEq(ifaceV2.gToken(), address(0x600));
        assertEq(ifaceV2.version(), "v2");

        vm.prank(newAdmin);
        ifaceV2.setUpgradeMarker(99);
        assertEq(ifaceV2.upgradeMarker(), 99);
    }
}
