// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "./utils/ScriptBase.sol";
import "../contracts/coinFactory.sol";
import "../contracts/lendingCoreAlgorithm.sol";
import "../contracts/lendingInterface.sol";
import "../contracts/lendingManager.sol";
import "../contracts/lendingVaults.sol";
import "../contracts/lstInterface.sol";
import "../contracts/template/depositOrLoanCoin.sol";
import "../contracts/zerrowOracleRedstone.sol";

interface IUpgradeable {
    function upgradeTo(address newImplementation) external;
}

contract UpgradeContract is ScriptBase {
    function run() external {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        string memory target = vm.envString("UPGRADE_TARGET");
        string memory deploymentFile = vm.envString("DEPLOYMENT_FILE");
        string memory manifest = vm.readFile(_absolutePath(deploymentFile));

        vm.startBroadcast(adminKey);

        if (_eq(target, "lendingManager")) {
            _upgradeUUPS(manifest, target);
        } else if (_eq(target, "lendingVaults")) {
            _upgradeUUPS(manifest, target);
        } else if (_eq(target, "coinFactory")) {
            _upgradeUUPS(manifest, target);
        } else if (_eq(target, "oracle")) {
            _upgradeUUPS(manifest, target);
        } else if (_eq(target, "lendingInterface")) {
            _upgradeUUPS(manifest, target);
        } else if (_eq(target, "lstInterface")) {
            _upgradeUUPS(manifest, target);
        } else if (_eq(target, "depositOrLoanCoin")) {
            _upgradeBeacon(manifest);
        } else if (_eq(target, "lendingCoreAlgorithm")) {
            _upgradeCoreAlgorithm(manifest);
        } else {
            revert("UpgradeContract: unknown target");
        }

        vm.stopBroadcast();
    }

    function _upgradeUUPS(string memory manifest, string memory target) internal {
        address proxy = _readAddress(manifest, _contractPath(target));
        address oldImpl = _readAddress(manifest, _implPath(target));

        address newImpl = _deployImplementation(target);
        require(newImpl != oldImpl, "UpgradeContract: new impl matches old impl");

        IUpgradeable(proxy).upgradeTo(newImpl);
    }

    function _upgradeBeacon(string memory manifest) internal {
        address beacon = _readAddress(manifest, ".contracts.depositOrLoanCoinBeacon");
        address oldImpl = _readAddress(manifest, ".implementations.depositOrLoanCoin");

        address newImpl = address(new depositOrLoanCoin());
        require(newImpl != oldImpl, "UpgradeContract: new impl matches old impl");

        UpgradeableBeacon(beacon).upgradeTo(newImpl);
    }

    function _upgradeCoreAlgorithm(string memory manifest) internal {
        address managerProxy = _readAddress(manifest, ".contracts.lendingManager");
        lendingManager mgr = lendingManager(managerProxy);

        address newAlgo = address(new lendingCoreAlgorithm(managerProxy));

        mgr.setup(
            mgr.coinFactory(),
            mgr.lendingVault(),
            mgr.riskIsolationModeAcceptAssets(),
            newAlgo,
            mgr.oracleAddr()
        );
    }

    function _deployImplementation(
        string memory target
    ) internal returns (address) {
        if (_eq(target, "lendingManager")) return address(new lendingManager());
        if (_eq(target, "lendingVaults")) return address(new lendingVaults());
        if (_eq(target, "coinFactory")) return address(new coinFactory());
        if (_eq(target, "oracle")) return address(new zerrowOracleRedstone());
        if (_eq(target, "lendingInterface")) return address(new lendingInterface());
        if (_eq(target, "lstInterface")) return address(new lstInterface());
        revert("UpgradeContract: cannot deploy target");
    }

    function _contractPath(
        string memory target
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(".contracts.", target));
    }

    function _implPath(
        string memory target
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(".implementations.", target));
    }

    function _absolutePath(
        string memory path
    ) internal view returns (string memory) {
        bytes memory raw = bytes(path);
        if (raw.length > 0 && raw[0] == bytes1(uint8(47))) {
            return path;
        }
        return string(abi.encodePacked(vm.projectRoot(), "/", path));
    }

    function _readAddress(
        string memory json,
        string memory key
    ) internal pure returns (address) {
        return vm.parseJsonAddress(json, key);
    }

    function _eq(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
