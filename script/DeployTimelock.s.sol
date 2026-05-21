// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "./utils/ScriptBase.sol";
import "../contracts/lendingManager.sol";
import "../contracts/lendingVaults.sol";
import "../contracts/zerrowOracleRedstone.sol";
import "../contracts/coinFactory.sol";
import "../contracts/lendingInterface.sol";
import "../contracts/TimelockCancelGuardian.sol";

/**
 * @title ScheduleTimelock
 * @notice Phase 1: Deploy the timelock, set guardians, initiate ownership
 *         transfers, and schedule the bootstrap accept calls.
 *         Run this first, then wait >= MIN_DELAY before running ExecuteTimelock.
 */
contract ScheduleTimelock is ScriptBase {
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
        address beacon;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        Config memory cfg = _loadConfig();
        Proxies memory p = _loadProxies();

        vm.startBroadcast(deployerKey);

        TimelockController timelock = _deployTimelock(cfg);

        TimelockCancelGuardian cancelGuardian = new TimelockCancelGuardian(
            timelock,
            cfg.guardian
        );
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(cancelGuardian));

        _setGuardians(p, cfg.guardian);
        _initiateTransfers(p, address(timelock));

        _scheduleBootstrap(timelock, p);

        // Transfer UpgradeableBeacon ownership to timelock (immediate, not two-step)
        UpgradeableBeacon(p.beacon).transferOwnership(address(timelock));
        require(
            UpgradeableBeacon(p.beacon).owner() == address(timelock),
            "DeployTimelock: beacon ownership transfer failed"
        );

        timelock.renounceRole(timelock.TIMELOCK_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.multisig = vm.envAddress("MULTISIG_ADDRESS");
        require(cfg.multisig != address(0), "DeployTimelock: MULTISIG_ADDRESS not set");
        cfg.guardian = vm.envAddress("GUARDIAN_ADDRESS");
        require(cfg.guardian != address(0), "DeployTimelock: GUARDIAN_ADDRESS not set");
        cfg.delay = _envUintOr("TIMELOCK_DELAY", 24 hours);
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
        p.beacon = _readAddress(manifest, ".contracts.depositOrLoanCoinBeacon");
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

    function _scheduleBootstrap(
        TimelockController timelock,
        Proxies memory p
    ) internal {
        uint256 delay = timelock.getMinDelay();

        _schedule(
            timelock, p.manager,
            abi.encodeWithSelector(lendingManager.acceptSetter.selector, true),
            keccak256("bootstrap-manager"),
            delay
        );
        _schedule(
            timelock, p.vaults,
            abi.encodeWithSelector(lendingVaults.acceptSetter.selector, true),
            keccak256("bootstrap-vaults"),
            delay
        );
        _schedule(
            timelock, p.factory,
            abi.encodeWithSelector(coinFactory.acceptPA.selector, true),
            keccak256("bootstrap-factory"),
            delay
        );
        _schedule(
            timelock, p.oracle,
            abi.encodeWithSelector(zerrowOracleRedstone.acceptSetter.selector, true),
            keccak256("bootstrap-oracle"),
            delay
        );
        _schedule(
            timelock, p.lendingIface,
            abi.encodeWithSelector(lendingInterface.acceptAdmin.selector, true),
            keccak256("bootstrap-interface"),
            delay
        );
    }

    function _schedule(
        TimelockController timelock,
        address target,
        bytes memory data,
        bytes32 salt,
        uint256 delay
    ) internal {
        bytes32 predecessor = bytes32(0);
        timelock.schedule(target, 0, data, predecessor, salt, delay);
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

/**
 * @title ExecuteTimelock
 * @notice Phase 2: Execute the bootstrap accept calls after MIN_DELAY has elapsed.
 *         Run this only after the delay period from ScheduleTimelock has passed.
 */
contract ExecuteTimelock is ScriptBase {
    struct Proxies {
        address manager;
        address vaults;
        address factory;
        address oracle;
        address lendingIface;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address timelockAddr = vm.envAddress("TIMELOCK_ADDRESS");
        require(timelockAddr != address(0), "ExecuteTimelock: TIMELOCK_ADDRESS not set");

        Proxies memory p = _loadProxies();
        TimelockController timelock = TimelockController(payable(timelockAddr));

        vm.startBroadcast(deployerKey);

        _execute(
            timelock, p.manager,
            abi.encodeWithSelector(lendingManager.acceptSetter.selector, true),
            keccak256("bootstrap-manager")
        );
        _execute(
            timelock, p.vaults,
            abi.encodeWithSelector(lendingVaults.acceptSetter.selector, true),
            keccak256("bootstrap-vaults")
        );
        _execute(
            timelock, p.factory,
            abi.encodeWithSelector(coinFactory.acceptPA.selector, true),
            keccak256("bootstrap-factory")
        );
        _execute(
            timelock, p.oracle,
            abi.encodeWithSelector(zerrowOracleRedstone.acceptSetter.selector, true),
            keccak256("bootstrap-oracle")
        );
        _execute(
            timelock, p.lendingIface,
            abi.encodeWithSelector(lendingInterface.acceptAdmin.selector, true),
            keccak256("bootstrap-interface")
        );

        vm.stopBroadcast();
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

    function _execute(
        TimelockController timelock,
        address target,
        bytes memory data,
        bytes32 salt
    ) internal {
        bytes32 predecessor = bytes32(0);
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
}
