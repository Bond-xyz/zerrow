// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

import "./interfaces/iDepositOrLoanCoin.sol";
import "./LendingManagerTypes.sol";

library LendingManagerAdminLib {
    error OnlySetter();
    error PermissionForbidden();
    error CannotTransferToZero();
    error ZeroAddress();
    error NormalFloorTooLow();
    error HomogeneousFloorTooLow();
    error NormalFloorTooHigh();
    error HomogeneousFloorTooHigh();
    error HomogeneousFloorMustBeBelowNormal();

    event InterfaceApproval(address indexed user, address indexed iface, bool approved);
    event InterfaceSetup(address _xInterface, bool _ToF);
    event FloorOfHealthFactorSetup(uint normal, uint homogeneous);
    event TransferSetterCancelled(address indexed cancelledPending);

    function transferSetter(address caller, address setter, address nextSetter) public pure returns (address) {
        _requireSetter(caller, setter);
        if (nextSetter == address(0)) revert CannotTransferToZero();
        return nextSetter;
    }

    function acceptSetter(
        address caller,
        address pendingSetter,
        address currentSetter,
        bool acceptTransfer
    ) public pure returns (address acceptedSetter, address clearedPendingSetter) {
        if (caller != pendingSetter) revert PermissionForbidden();
        acceptedSetter = acceptTransfer ? pendingSetter : currentSetter;
        clearedPendingSetter = address(0);
    }

    function cancelTransferSetter(address caller, address setter, address pendingSetter) public {
        _requireSetter(caller, setter);
        emit TransferSetterCancelled(pendingSetter);
    }

    function validateSetup(
        mapping(address => LendingManagerTypes.LicensedAsset) storage licensedAssets,
        address[] storage assetsSerialNumber,
        mapping(address => uint) storage riskIsolationModeLendingNetAmount,
        address caller,
        address setter,
        address currentRiskIsolationModeAcceptAssets,
        address newCoinFactory,
        address newLendingVault,
        address newRiskIsolationModeAcceptAssets,
        address newCoreAlgorithm,
        address newOracle
    ) public view {
        _requireSetter(caller, setter);
        if (newCoinFactory == address(0) || newLendingVault == address(0)
            || newCoreAlgorithm == address(0) || newOracle == address(0)) revert ZeroAddress();

        if (newRiskIsolationModeAcceptAssets != currentRiskIsolationModeAcceptAssets
            && currentRiskIsolationModeAcceptAssets != address(0)) {
            for (uint assetIndex = 0; assetIndex < assetsSerialNumber.length; assetIndex++) {
                address asset = assetsSerialNumber[assetIndex];
                if (licensedAssets[asset].maxLendingAmountInRIM > 0) {
                    require(riskIsolationModeLendingNetAmount[asset] == 0, "Lending Manager: outstanding RIM debt");
                }
            }
        }
    }

    function setInterface(
        mapping(address => bool) storage xInterface,
        address[] storage interfaceArray,
        mapping(address => uint256) storage interfaceVersion,
        address caller,
        address setter,
        address targetInterface,
        bool enabled
    ) public {
        _requireSetter(caller, setter);
        uint lengthTemp = interfaceArray.length;
        if (!enabled) {
            xInterface[targetInterface] = false;
            interfaceVersion[targetInterface] += 1;
            for (uint interfaceIndex = 0; interfaceIndex != lengthTemp; interfaceIndex++) {
                if (interfaceArray[interfaceIndex] == targetInterface) {
                    interfaceArray[interfaceIndex] = interfaceArray[lengthTemp - 1];
                    interfaceArray.pop();
                    break;
                }
            }
        } else if (!xInterface[targetInterface]) {
            xInterface[targetInterface] = true;
            interfaceArray.push(targetInterface);
        }
        emit InterfaceSetup(targetInterface, enabled);
    }

    function setInterfaceApproval(
        address[] storage interfaceArray,
        mapping(address => mapping(address => bool)) storage interfaceApproval,
        mapping(address => uint256) storage interfaceVersion,
        mapping(address => mapping(address => uint256)) storage interfaceApprovalVersion,
        address user,
        bool approved
    ) public {
        uint lengthTemp = interfaceArray.length;
        for (uint interfaceIndex = 0; interfaceIndex != lengthTemp; interfaceIndex++) {
            address iface = interfaceArray[interfaceIndex];
            interfaceApproval[user][iface] = approved;
            interfaceApprovalVersion[user][iface] = interfaceVersion[iface];
            emit InterfaceApproval(user, iface, approved);
        }
    }

    function validateFloorOfHealthFactor(
        address caller,
        address setter,
        uint normal,
        uint homogeneous
    ) public {
        _requireSetter(caller, setter);
        if (normal < 1 ether) revert NormalFloorTooLow();
        if (homogeneous < 1 ether) revert HomogeneousFloorTooLow();
        if (normal > 100 ether) revert NormalFloorTooHigh();
        if (homogeneous > 100 ether) revert HomogeneousFloorTooHigh();
        if (normal <= homogeneous) revert HomogeneousFloorMustBeBelowNormal();
        emit FloorOfHealthFactorSetup(normal, homogeneous);
    }

    function coinMintLockerSetup(address caller, address setter, address coin, bool tOF) public {
        _requireSetter(caller, setter);
        iDepositOrLoanCoin(coin).mintLockerSetup(tOF);
    }

    function coinRewardContractSetup(
        address caller,
        address setter,
        address coin,
        address rewardContract
    ) public {
        _requireSetter(caller, setter);
        iDepositOrLoanCoin(coin).rewardContractSetup(rewardContract);
    }

    function coinTransferSetter(address caller, address setter, address coin, address newSetter) public {
        _requireSetter(caller, setter);
        iDepositOrLoanCoin(coin).transferSetter(newSetter);
    }

    function _requireSetter(address caller, address setter) private pure {
        if (caller != setter) revert OnlySetter();
    }
}
