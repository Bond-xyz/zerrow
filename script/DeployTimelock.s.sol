// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/governance/TimelockController.sol";

import "./utils/ScriptBase.sol";
import "../contracts/lendingManager.sol";
import "../contracts/lendingVaults.sol";
import "../contracts/zerrowOracleRedstone.sol";
import "../contracts/coinFactory.sol";
import "../contracts/lendingInterface.sol";

contract DeployTimelock is ScriptBase {
    struct Config {
        address multisig;
        address guardian;
        uint256 delay;
    }

    struct Proxies {
        address manager;
        address vaults;
        address factory;
        address oracle;
        address lendingIface;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        Config memory cfg = _loadConfig();
        Proxies memory p = _loadProxies();

        vm.startBroadcast(deployerKey);

        TimelockController timelock = _deployTimelock(cfg);

        _setGuardians(p, cfg.guardian);
        _initiateTransfers(p, address(timelock));

        _bootstrapAccepts(timelock, p);

        timelock.renounceRole(timelock.TIMELOCK_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.multisig = vm.envAddress("MULTISIG_ADDRESS");
        cfg.guardian = vm.envAddress("GUARDIAN_ADDRESS");
        cfg.delay = _envUintOr("TIMELOCK_DELAY", 48 hours);
    }

    function _loadProxies() internal view returns (Proxies memory p) {
        string memory manifest = vm.readFile(
            _absolutePath(vm.envString("DEPLOYMENT_FILE"))
        );
        p.manager = _readAddress(manifest, ".contracts.lendingManager");
        p.vaults = _readAddress(manifest, ".contracts.lendingVaults");
        p.factory = _readAddress(manifest, ".contracts.coinFactory");
        p.oracle = _readAddress(manifest, ".contracts.oracle");
        p.lendingIface = _readAddress(manifest, ".contracts.lendingInterface");
    }

    function _deployTimelock(
        Config memory cfg
    ) internal returns (TimelockController) {
        address[] memory proposers = new address[](1);
        proposers[0] = cfg.multisig;
        address[] memory executors = new address[](1);
        executors[0] = cfg.multisig;

        return new TimelockController(cfg.delay, proposers, executors);
    }

    function _setGuardians(Proxies memory p, address guardian) internal {
        lendingManager(p.manager).setGuardian(guardian);
        lendingVaults(payable(p.vaults)).setGuardian(guardian);
    }

    function _initiateTransfers(Proxies memory p, address dest) internal {
        lendingManager(p.manager).transferSetter(dest);
        lendingVaults(payable(p.vaults)).transferSetter(dest);
        coinFactory(p.factory).setPA(dest);
        zerrowOracleRedstone(payable(p.oracle)).transferSetter(dest);
        lendingInterface(payable(p.lendingIface)).transferAdmin(dest);
    }

    function _bootstrapAccepts(
        TimelockController timelock,
        Proxies memory p
    ) internal {
        _scheduleAndExecute(
            timelock, p.manager,
            abi.encodeWithSelector(lendingManager.acceptSetter.selector, true),
            keccak256("bootstrap-manager")
        );
        _scheduleAndExecute(
            timelock, p.vaults,
            abi.encodeWithSelector(lendingVaults.acceptSetter.selector, true),
            keccak256("bootstrap-vaults")
        );
        _scheduleAndExecute(
            timelock, p.factory,
            abi.encodeWithSelector(coinFactory.acceptPA.selector, true),
            keccak256("bootstrap-factory")
        );
        _scheduleAndExecute(
            timelock, p.oracle,
            abi.encodeWithSelector(zerrowOracleRedstone.acceptSetter.selector, true),
            keccak256("bootstrap-oracle")
        );
        _scheduleAndExecute(
            timelock, p.lendingIface,
            abi.encodeWithSelector(lendingInterface.acceptAdmin.selector, true),
            keccak256("bootstrap-interface")
        );
    }

    function _scheduleAndExecute(
        TimelockController timelock,
        address target,
        bytes memory data,
        bytes32 salt
    ) internal {
        bytes32 predecessor = bytes32(0);
        uint256 delay = timelock.getMinDelay();

        timelock.schedule(target, 0, data, predecessor, salt, delay);
        timelock.execute(target, 0, data, predecessor, salt);
    }

    function _absolutePath(string memory path) internal view returns (string memory) {
        bytes memory raw = bytes(path);
        if (raw.length > 0 && raw[0] == bytes1(uint8(47))) {
            return path;
        }
        return string(abi.encodePacked(vm.projectRoot(), "/", path));
    }

    function _readAddress(string memory json, string memory key) internal pure returns (address) {
        return vm.parseJsonAddress(json, key);
    }

    function _envUintOr(string memory key, uint256 fallback_) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 value) {
            return value;
        } catch {
            return fallback_;
        }
    }
}
