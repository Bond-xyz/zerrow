// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "./utils/ScriptBase.sol";
import "../contracts/lendingManager.sol";
import "../contracts/zerrowOracleRedstone.sol";

contract ConfigureMarkets is ScriptBase {
    struct LendingParams {
        bool enabled;
        uint256 maxLTV;
        uint256 liqPenalty;
        uint256 maxLendingAmountInRIM;
        uint256 bestLendingRatio;
        uint256 reserveFactor;
        uint8 lendingModeNum;
        uint256 homogeneousLTV;
        uint256 depositRate;
        bool isNew;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address lendingManagerAddress = vm.envAddress("LENDING_MANAGER_ADDRESS");
        address oracleAddress = vm.envAddress("ORACLE_ADDRESS");
        string memory assetsPath = _envStringOr(
            "ASSETS_REGISTRY_PATH",
            "../../bond-shared-registry/envs/og-testnet-staging/assets.json"
        );
        string memory feedMapPath = _envStringOr(
            "ORACLE_FEED_MAP_PATH",
            "config/redstone-feed-map.og-testnet-staging.example.json"
        );

        string memory assetManifest = vm.readFile(_absolutePath(assetsPath));
        string memory feedManifest = vm.readFile(_absolutePath(feedMapPath));
        uint256 assetCount = _readUint(assetManifest, ".assetsCount");
        uint256 feedCount = _readUint(feedManifest, ".feedsCount");

        vm.startBroadcast(deployerPrivateKey);

        lendingManager manager = lendingManager(lendingManagerAddress);
        zerrowOracleRedstone oracle = zerrowOracleRedstone(payable(oracleAddress));

        for (uint256 i = 0; i < assetCount; i++) {
            string memory base = _assetBasePath(i);
            address token = _readAddress(assetManifest, _path(base, ".address"));
            bool assetEnabled = _readBool(assetManifest, _path(base, ".enabled"));
            string memory oracleFeedId = _readString(assetManifest, _path(base, ".oracleFeedId"));
            LendingParams memory lendingCfg = _readLendingParams(assetManifest, base);
            bool registered = _isRegistered(manager, token);

            if (!assetEnabled || !lendingCfg.enabled) {
                if (registered) {
                    manager.licensedAssetsReset(
                        token,
                        0,
                        lendingCfg.liqPenalty,
                        0,
                        1,
                        lendingCfg.reserveFactor,
                        lendingCfg.lendingModeNum,
                        0,
                        1
                    );
                }
                continue;
            }

            address feed = _lookupFeed(feedManifest, oracleFeedId, feedCount);
            oracle.setTokenFeed(token, feed);

            if (!registered) {
                manager.licensedAssetsRegister(
                    token,
                    lendingCfg.maxLTV,
                    lendingCfg.liqPenalty,
                    lendingCfg.maxLendingAmountInRIM,
                    lendingCfg.bestLendingRatio,
                    lendingCfg.reserveFactor,
                    lendingCfg.lendingModeNum,
                    lendingCfg.homogeneousLTV,
                    lendingCfg.depositRate,
                    lendingCfg.isNew
                );
                continue;
            }

            manager.licensedAssetsReset(
                token,
                lendingCfg.maxLTV,
                lendingCfg.liqPenalty,
                lendingCfg.maxLendingAmountInRIM,
                lendingCfg.bestLendingRatio,
                lendingCfg.reserveFactor,
                lendingCfg.lendingModeNum,
                lendingCfg.homogeneousLTV,
                lendingCfg.depositRate
            );
        }

        vm.stopBroadcast();
    }

    function _readLendingParams(
        string memory manifest,
        string memory base
    ) internal pure returns (LendingParams memory cfg) {
        cfg.enabled = _readBool(manifest, _path(base, ".lending.enabled"));
        cfg.maxLTV = _readUint(manifest, _path(base, ".lending.maxLTV"));
        cfg.liqPenalty = _readUint(manifest, _path(base, ".lending.liqPenalty"));
        cfg.maxLendingAmountInRIM = _readUint(
            manifest,
            _path(base, ".lending.maxLendingAmountInRIM")
        );
        cfg.bestLendingRatio = _readUint(manifest, _path(base, ".lending.bestLendingRatio"));
        cfg.reserveFactor = _readUint(manifest, _path(base, ".lending.reserveFactor"));
        cfg.lendingModeNum = uint8(_readUint(manifest, _path(base, ".lending.lendingModeNum")));
        cfg.homogeneousLTV = _readUint(manifest, _path(base, ".lending.homogeneousLTV"));
        cfg.depositRate = _readUint(manifest, _path(base, ".lending.depositRate"));
        cfg.isNew = _readBool(manifest, _path(base, ".lending.isNew"));
    }

    function _lookupFeed(
        string memory feedManifest,
        string memory oracleFeedId,
        uint256 feedCount
    ) internal view returns (address feedAddress) {
        for (uint256 i = 0; i < feedCount; i++) {
            string memory base = string(abi.encodePacked(".feeds[", vm.toString(i), "]"));
            string memory candidateFeedId = _readString(feedManifest, _path(base, ".oracleFeedId"));
            if (_stringsEqual(candidateFeedId, oracleFeedId)) {
                feedAddress = _readAddress(feedManifest, _path(base, ".feed"));
                require(feedAddress != address(0), "ConfigureMarkets: zero feed");
                return feedAddress;
            }
        }

        revert("ConfigureMarkets: missing feed mapping");
    }

    function _isRegistered(
        lendingManager manager,
        address token
    ) internal view returns (bool) {
        (address assetAddr, , , , , , , , ) = manager.licensedAssets(token);
        return assetAddr != address(0);
    }

    function _assetBasePath(uint256 index) internal view returns (string memory) {
        return string(abi.encodePacked(".assets[", vm.toString(index), "]"));
    }

    function _path(
        string memory base,
        string memory suffix
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(base, suffix));
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

    function _absolutePath(string memory path) internal view returns (string memory) {
        bytes memory raw = bytes(path);
        if (raw.length > 0 && raw[0] == bytes1(uint8(47))) {
            return path;
        }

        return string(abi.encodePacked(vm.projectRoot(), "/", path));
    }

    function _stringsEqual(
        string memory left,
        string memory right
    ) internal pure returns (bool) {
        return keccak256(bytes(left)) == keccak256(bytes(right));
    }

    function _readUint(
        string memory json,
        string memory key
    ) internal pure returns (uint256) {
        return vm.parseJsonUint(json, key);
    }

    function _readAddress(
        string memory json,
        string memory key
    ) internal pure returns (address) {
        return vm.parseJsonAddress(json, key);
    }

    function _readString(
        string memory json,
        string memory key
    ) internal pure returns (string memory) {
        return vm.parseJsonString(json, key);
    }

    function _readBool(
        string memory json,
        string memory key
    ) internal pure returns (bool) {
        return vm.parseJsonBool(json, key);
    }
}
