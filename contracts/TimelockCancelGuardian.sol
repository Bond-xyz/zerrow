// SPDX-License-Identifier: Business Source License 1.1
pragma solidity 0.8.6;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Cancel-only guardian for the Zerrow timelock.
///         Holds PROPOSER_ROLE on the TimelockController (required by OZ 4.2
///         to call cancel()), but only exposes cancel — not schedule.
///         Follows the Compound GovernorAlpha / Aave v2 guardian pattern.
contract TimelockCancelGuardian {
    TimelockController public immutable timelock;
    address public guardian;

    event GuardianTransferred(address indexed oldGuardian, address indexed newGuardian);
    event Abdicated();

    modifier onlyGuardian() {
        require(msg.sender == guardian, "not guardian");
        _;
    }

    constructor(TimelockController _timelock, address _guardian) {
        require(address(_timelock) != address(0), "zero timelock");
        require(_guardian != address(0), "zero guardian");
        timelock = _timelock;
        guardian = _guardian;
    }

    function cancel(bytes32 id) external onlyGuardian {
        timelock.cancel(id);
    }

    function transferGuardian(address newGuardian) external onlyGuardian {
        require(newGuardian != address(0), "zero address");
        emit GuardianTransferred(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Permanently renounce guardian power. Cannot be undone.
    function abdicate() external onlyGuardian {
        emit Abdicated();
        guardian = address(0);
    }
}
