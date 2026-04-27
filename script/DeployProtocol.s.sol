// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "./utils/ScriptBase.sol";
import "../contracts/coinFactory.sol";
import "../contracts/lendingCoreAlgorithm.sol";
import "../contracts/lendingInterface.sol";
import "../contracts/lendingManager.sol";
import "../contracts/lendingVaults.sol";
import "../contracts/rewardRecordMock.sol";
import "../contracts/template/depositOrLoanCoin.sol";
import "../contracts/zerrowOracleRedstone.sol";

contract DeployProtocol is ScriptBase {
    struct DeployConfig {
        string environment;
        string deploymentFile;
        address wrappedToken;
        address rewardContract;
        address riskIsolationModeAcceptAsset;
        uint256 normalHealthFactorBps;
        uint256 homogeneousHealthFactorBps;
        uint256 rewardDepositType;
        uint256 rewardLoanType;
        uint256 oracleMaxStaleness;
        address st0gAddress;
        bool deployMockReward;
    }

    struct Deployment {
        address deployer;
        address rewardContract;
        address lendingManagerImplementation;
        address lendingManager;
        address lendingVaultsImplementation;
        address lendingVaults;
        address coinFactoryImplementation;
        address coinFactory;
        address oracleImplementation;
        address oracle;
        address depositOrLoanCoinImplementation;
        address depositOrLoanCoinBeacon;
        address lendingCoreAlgorithm;
        address lendingInterfaceImplementation;
        address lendingInterface;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        DeployConfig memory cfg = _loadConfig();
        _validateConfig(cfg);

        Deployment memory deployed;
        deployed.deployer = deployer;

        vm.startBroadcast(deployerPrivateKey);

        deployed.rewardContract = _deployRewardContract(cfg);
        deployed.lendingManagerImplementation = address(new lendingManager());
        deployed.lendingManager = address(
            new ERC1967Proxy(
                deployed.lendingManagerImplementation,
                abi.encodeWithSelector(lendingManager.initialize.selector, deployer)
            )
        );

        deployed.lendingVaultsImplementation = address(new lendingVaults());
        deployed.lendingVaults = address(
            new ERC1967Proxy(
                deployed.lendingVaultsImplementation,
                abi.encodeWithSelector(lendingVaults.initialize.selector, deployer)
            )
        );

        deployed.coinFactoryImplementation = address(new coinFactory());
        deployed.coinFactory = address(
            new ERC1967Proxy(
                deployed.coinFactoryImplementation,
                abi.encodeWithSelector(coinFactory.initialize.selector, deployer)
            )
        );

        deployed.oracleImplementation = address(new zerrowOracleRedstone());
        deployed.oracle = address(
            new ERC1967Proxy(
                deployed.oracleImplementation,
                abi.encodeWithSelector(zerrowOracleRedstone.initialize.selector, deployer)
            )
        );

        deployed.depositOrLoanCoinImplementation = address(new depositOrLoanCoin());
        deployed.depositOrLoanCoinBeacon = address(
            new UpgradeableBeacon(deployed.depositOrLoanCoinImplementation)
        );

        deployed.lendingCoreAlgorithm = address(
            new lendingCoreAlgorithm(deployed.lendingManager)
        );

        deployed.lendingInterfaceImplementation = address(new lendingInterface());
        deployed.lendingInterface = address(
            new ERC1967Proxy(
                deployed.lendingInterfaceImplementation,
                abi.encodeWithSelector(
                    lendingInterface.initialize.selector,
                    deployed.lendingManager,
                    cfg.wrappedToken,
                    deployed.oracle,
                    deployed.lendingCoreAlgorithm
                )
            )
        );

        coinFactory(deployed.coinFactory).setBeacon(deployed.depositOrLoanCoinBeacon);
        coinFactory(deployed.coinFactory).settings(
            deployed.lendingManager,
            deployed.rewardContract
        );
        coinFactory(deployed.coinFactory).rewardTypeSetup(
            cfg.rewardDepositType,
            cfg.rewardLoanType
        );

        lendingVaults(payable(deployed.lendingVaults)).setManager(deployed.lendingManager);

        lendingManager(deployed.lendingManager).setup(
            deployed.coinFactory,
            deployed.lendingVaults,
            cfg.riskIsolationModeAcceptAsset,
            deployed.lendingCoreAlgorithm,
            deployed.oracle
        );
        lendingManager(deployed.lendingManager).setFloorOfHealthFactor(
            _bpsToWad(cfg.normalHealthFactorBps),
            _bpsToWad(cfg.homogeneousHealthFactorBps)
        );
        lendingManager(deployed.lendingManager).xInterfacesetting(
            deployed.lendingInterface,
            true
        );

        if (cfg.oracleMaxStaleness != zerrowOracleRedstone(payable(deployed.oracle)).maxStaleness()) {
            zerrowOracleRedstone(payable(deployed.oracle)).setMaxStaleness(
                cfg.oracleMaxStaleness
            );
        }

        if (cfg.st0gAddress != address(0)) {
            zerrowOracleRedstone(payable(deployed.oracle)).setSt0gAdr(cfg.st0gAddress);
        }

        vm.stopBroadcast();

        _writeDeployment(cfg, deployed);
    }

    function _loadConfig() internal view returns (DeployConfig memory cfg) {
        cfg.environment = _envStringOr("BOND_ENV", "staging");
        cfg.deploymentFile = _envStringOr(
            "DEPLOYMENT_FILE",
            _defaultDeploymentFile(cfg.environment, block.chainid)
        );
        cfg.wrappedToken = vm.envAddress("W0G_ADDRESS");
        cfg.deployMockReward = _envBoolOr("DEPLOY_MOCK_REWARD", false);
        cfg.rewardContract = _envAddressOr("REWARD_CONTRACT_ADDRESS", address(0));
        cfg.riskIsolationModeAcceptAsset = _envAddressOr(
            "RISK_ISOLATION_MODE_ACCEPT_ASSET",
            cfg.wrappedToken
        );
        cfg.normalHealthFactorBps = _envUintOr("NORMAL_HEALTH_FACTOR_BPS", 12000);
        cfg.homogeneousHealthFactorBps = _envUintOr(
            "HOMOGENEOUS_HEALTH_FACTOR_BPS",
            10300
        );
        cfg.rewardDepositType = _envUintOr("REWARD_DEPOSIT_TYPE", 1);
        cfg.rewardLoanType = _envUintOr("REWARD_LOAN_TYPE", 2);
        cfg.oracleMaxStaleness = _envUintOr("ORACLE_MAX_STALENESS", 25200);
        cfg.st0gAddress = _envAddressOr("ST0G_ADDRESS", address(0));
    }

    function _validateConfig(DeployConfig memory cfg) internal view {
        require(cfg.wrappedToken != address(0), "DeployProtocol: W0G_ADDRESS required");
        require(
            cfg.riskIsolationModeAcceptAsset != address(0),
            "DeployProtocol: RIM asset required"
        );
        require(
            cfg.rewardDepositType != 0 && cfg.rewardLoanType != 0,
            "DeployProtocol: reward types required"
        );
        require(
            cfg.rewardDepositType != cfg.rewardLoanType,
            "DeployProtocol: reward types must differ"
        );
        require(
            cfg.normalHealthFactorBps > cfg.homogeneousHealthFactorBps,
            "DeployProtocol: normal HF must exceed homogeneous HF"
        );
        require(
            cfg.homogeneousHealthFactorBps >= 10000,
            "DeployProtocol: homogeneous HF must be at least 100%"
        );
        require(
            cfg.oracleMaxStaleness >= 3600 && cfg.oracleMaxStaleness <= 86400,
            "DeployProtocol: invalid oracle staleness"
        );
        _requireAddressHasCode(cfg.wrappedToken, "DeployProtocol: W0G_ADDRESS has no bytecode");
        if (!cfg.deployMockReward) {
            require(
                cfg.rewardContract != address(0),
                "DeployProtocol: REWARD_CONTRACT_ADDRESS required"
            );
            _requireAddressHasCode(
                cfg.rewardContract,
                "DeployProtocol: reward contract has no bytecode"
            );
        }
    }

    function _deployRewardContract(
        DeployConfig memory cfg
    ) internal returns (address rewardContract) {
        if (cfg.deployMockReward) {
            rewardContract = address(new rewardRecordMock());
        } else {
            rewardContract = cfg.rewardContract;
        }
    }

    function _requireAddressHasCode(address target, string memory err) internal view {
        require(target.code.length > 0, err);
    }

    function _bpsToWad(uint256 bps) internal pure returns (uint256) {
        return (bps * 1 ether) / 10000;
    }

    function _envStringOr(
        string memory key,
        string memory fallbackValue
    ) internal view returns (string memory) {
        try vm.envString(key) returns (string memory value) {
            return value;
        } catch {
            return fallbackValue;
        }
    }

    function _envUintOr(
        string memory key,
        uint256 fallbackValue
    ) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 value) {
            return value;
        } catch {
            return fallbackValue;
        }
    }

    function _envBoolOr(
        string memory key,
        bool fallbackValue
    ) internal view returns (bool) {
        try vm.envString(key) returns (string memory rawValue) {
            if (
                _stringsEqual(rawValue, "1") ||
                _stringsEqual(rawValue, "true") ||
                _stringsEqual(rawValue, "TRUE") ||
                _stringsEqual(rawValue, "yes") ||
                _stringsEqual(rawValue, "YES")
            ) {
                return true;
            }

            if (
                _stringsEqual(rawValue, "0") ||
                _stringsEqual(rawValue, "false") ||
                _stringsEqual(rawValue, "FALSE") ||
                _stringsEqual(rawValue, "no") ||
                _stringsEqual(rawValue, "NO")
            ) {
                return false;
            }

            revert("DeployProtocol: invalid boolean env value");
        } catch {
            return fallbackValue;
        }
    }

    function _envAddressOr(
        string memory key,
        address fallbackValue
    ) internal view returns (address) {
        try vm.envAddress(key) returns (address value) {
            return value;
        } catch {
            return fallbackValue;
        }
    }

    function _defaultDeploymentFile(
        string memory environment,
        uint256 chainId
    ) internal pure returns (string memory) {
        if (chainId == 16602 && _stringsEqual(environment, "staging")) {
            return "deployments/og-testnet-staging.json";
        }

        if (chainId == 16661 && _stringsEqual(environment, "prod")) {
            return "deployments/og-mainnet-prod.json";
        }

        return
            string(
                abi.encodePacked(
                    "deployments/",
                    environment,
                    "-",
                    _uintToString(chainId),
                    ".json"
                )
            );
    }

    function _blockExplorer(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 16602) {
            return "https://chainscan-galileo.0g.ai";
        }

        if (chainId == 16661) {
            return "https://chainscan.0g.ai";
        }

        return "";
    }

    function _writeDeployment(
        DeployConfig memory cfg,
        Deployment memory deployed
    ) internal {
        string memory path = _absolutePath(cfg.deploymentFile);
        vm.writeFile(path, _deploymentJson(cfg, deployed));
    }

    function _absolutePath(string memory path) internal view returns (string memory) {
        bytes memory raw = bytes(path);
        if (raw.length > 0 && raw[0] == bytes1(uint8(47))) {
            return path;
        }

        return string(abi.encodePacked(vm.projectRoot(), "/", path));
    }

    function _deploymentJson(
        DeployConfig memory cfg,
        Deployment memory deployed
    ) internal view returns (string memory) {
        string memory header = string(
            abi.encodePacked(
                "{\n",
                '  "environment": "',
                cfg.environment,
                '",\n',
                '  "chainId": ',
                vm.toString(block.chainid),
                ",\n",
                '  "timestamp": ',
                vm.toString(block.timestamp),
                ",\n",
                '  "deployer": "',
                vm.toString(deployed.deployer),
                '",\n',
                '  "blockExplorer": "',
                _blockExplorer(block.chainid),
                '"'
            )
        );
        string memory contractsJson = _contractsJson(cfg, deployed);
        string memory implementationsJson = _implementationsJson(deployed);
        string memory rolesJson = _rolesJson(deployed);

        return
            string(
                abi.encodePacked(
                    header,
                    ",\n",
                    contractsJson,
                    ",\n",
                    implementationsJson,
                    ",\n",
                    rolesJson,
                    "\n",
                    "}\n"
                )
            );
    }

    function _contractsJson(
        DeployConfig memory cfg,
        Deployment memory deployed
    ) internal view returns (string memory) {
        string memory first = string(
            abi.encodePacked(
                _jsonAddressLine("w0G", vm.toString(cfg.wrappedToken), true),
                _jsonAddressLine(
                    "lendingManager",
                    vm.toString(deployed.lendingManager),
                    true
                ),
                _jsonAddressLine(
                    "lendingInterface",
                    vm.toString(deployed.lendingInterface),
                    true
                ),
                _jsonAddressLine("coinFactory", vm.toString(deployed.coinFactory), true)
            )
        );
        string memory second = string(
            abi.encodePacked(
                _jsonAddressLine(
                    "lendingCoreAlgorithm",
                    vm.toString(deployed.lendingCoreAlgorithm),
                    true
                ),
                _jsonAddressLine(
                    "lendingVaults",
                    vm.toString(deployed.lendingVaults),
                    true
                ),
                _jsonAddressLine("oracle", vm.toString(deployed.oracle), true),
                _jsonAddressLine(
                    "rewardContract",
                    vm.toString(deployed.rewardContract),
                    true
                ),
                _jsonAddressLine(
                    "depositOrLoanCoinBeacon",
                    vm.toString(deployed.depositOrLoanCoinBeacon),
                    false
                )
            )
        );
        return
            string(
                abi.encodePacked(
                    '  "contracts": {\n',
                    first,
                    second,
                    "  }"
                )
            );
    }

    function _implementationsJson(
        Deployment memory deployed
    ) internal view returns (string memory) {
        string memory first = string(
            abi.encodePacked(
                _jsonAddressLine(
                    "lendingManager",
                    vm.toString(deployed.lendingManagerImplementation),
                    true
                ),
                _jsonAddressLine(
                    "lendingInterface",
                    vm.toString(deployed.lendingInterfaceImplementation),
                    true
                ),
                _jsonAddressLine(
                    "coinFactory",
                    vm.toString(deployed.coinFactoryImplementation),
                    true
                )
            )
        );
        string memory second = string(
            abi.encodePacked(
                _jsonAddressLine(
                    "lendingVaults",
                    vm.toString(deployed.lendingVaultsImplementation),
                    true
                ),
                _jsonAddressLine(
                    "oracle",
                    vm.toString(deployed.oracleImplementation),
                    true
                ),
                _jsonAddressLine(
                    "depositOrLoanCoin",
                    vm.toString(deployed.depositOrLoanCoinImplementation),
                    false
                )
            )
        );
        return
            string(
                abi.encodePacked(
                    '  "implementations": {\n',
                    first,
                    second,
                    "  }"
                )
            );
    }

    function _rolesJson(
        Deployment memory deployed
    ) internal view returns (string memory) {
        return
            string(
                abi.encodePacked(
                    '  "roles": {\n',
                    _jsonAddressLine(
                        "initialProtocolAdmin",
                        vm.toString(deployed.deployer),
                        true
                    ),
                    _jsonAddressLine(
                        "initialLendingInterfaceAdmin",
                        vm.toString(deployed.deployer),
                        true
                    ),
                    _jsonAddressLine(
                        "initialDepositOrLoanCoinBeaconOwner",
                        vm.toString(deployed.deployer),
                        false
                    ),
                    "  }"
                )
            );
    }

    function _jsonAddressLine(
        string memory key,
        string memory value,
        bool trailingComma
    ) internal pure returns (string memory) {
        if (trailingComma) {
            return
                string(
                    abi.encodePacked('    "', key, '": "', value, '",\n')
                );
        }

        return string(abi.encodePacked('    "', key, '": "', value, '"\n'));
    }

    function _stringsEqual(
        string memory left,
        string memory right
    ) internal pure returns (bool) {
        return keccak256(bytes(left)) == keccak256(bytes(right));
    }

    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
