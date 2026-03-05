// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

interface IPausable {
    function isPaused() external view returns (bool);
    function pauseFor(uint256 _duration) external;
}

/// @title  CircuitBreaker
/// @author Lido
/// @notice An emergency pauser contract activated by designated committees.
///
///         Problem:
///         In an emergency situation such as an ongoing exploit, the DAO cannot respond
///         quickly due to the vote duration.
///
///         Solution:
///         A contract that holds pause permissions for critical contracts activated by
///         designated pauser committees. These pausers serve as fast-response delegates for the DAO.
///
///         Pauser can only pause a contract once and must be assigned again by the admin (DAO).
///         This limits the trust exposure of delegating pause power to a multisig.
///
///         Each pausable contract has one pauser but a pauser can have multiple pausables.
///         Each pausable has its own pause duration set by the admin when assigning a pauser.
///         The pause duration persists across pause events and is only changed by admin.
///
///         The heartbeat mechanism records pauser's liveness for offchain monitoring in order
///         to surface potentially unresponsive committees (e.g. due to lost keys) to make
///         sure that in case of emergency the committee is ready to pause.
///
/// @dev    Design decisions:
///         - One pauser per pausable. Keeps accountability clear and simple.
///         - Single-use pause. The pauser mapping is deleted on use.
///         - Per-pausable pause duration. Set once at pauser assignment, not cleared on pause.
///         - Heartbeat signal for offchain only.
///         - No pauser list. Offchain tracks the list of pausers.
///
///         Implicit assumptions:
///         - Pausables implement IPausable interface.
///         - Pausers are multisigs.
///         - Admin is DAO Agent or other DAO-controlled executor.
contract CircuitBreaker {
    error ZeroAdmin();
    error ZeroPauseDuration();
    error ZeroPausable();
    error SenderNotAdmin();
    error EmptyList();
    error SenderNotPauser(address pausable, address pauser);
    error PauseFailed(address pausable);

    event AdminSet(address indexed admin);
    event PauserSet(address indexed pausable, address indexed pauser, uint256 pauseDuration);
    event Paused(address indexed pausable);
    event AlreadyPaused(address indexed pausable);
    event Heartbeat(address indexed sender);

    /// @notice Admin address that can assign pausers and set pause duration.
    ///         Assumed to be DAO Agent or other DAO-controlled executor.
    address public immutable ADMIN;

    /// @notice Pause authorization.
    ///         Pause is single-use, and entry is deleted upon successful use.
    mapping(address pausable => address pauser) public pausers;

    /// @notice Per-pausable pause duration in seconds.
    ///         Set by admin when assigning a pauser. Persists across pause events.
    mapping(address pausable => uint256 pauseDuration) public pauseDurations;

    /// @notice Last timestamp each pauser proved liveness.
    ///         For offchain monitoring only.
    mapping(address pauser => uint256 latestHeartbeat) public latestHeartbeats;

    /// @param _admin Address that can assign pausers and set pause duration.
    constructor(address _admin) {
        require(_admin != address(0), ZeroAdmin());

        ADMIN = _admin;

        emit AdminSet(_admin);
    }

    /// @notice Assign, replace or remove a pauser for a pausable contract.
    ///         Only 1 pauser per pausable, the previous pauser will be overwritten.
    ///         A non-zero pause duration must always be provided.
    ///         The pause duration persists after a pause is triggered and is only
    ///         updated by a subsequent setPauser call with a new duration.
    /// @param  _pausable Pausable contract to assign a pauser to.
    /// @param  _pauser Pauser address to assign to the pausable. Set to address(0) to remove.
    /// @param  _pauseDuration Duration in seconds passed to pauseFor() on trigger. Must be non-zero.
    /// @dev    Function does not check whether CircuitBreaker has the permission to pause.
    function setPauser(address _pausable, address _pauser, uint256 _pauseDuration) external {
        require(msg.sender == ADMIN, SenderNotAdmin());
        require(_pausable != address(0), ZeroPausable());
        require(_pauseDuration > 0, ZeroPauseDuration());

        pausers[_pausable] = _pauser;
        pauseDurations[_pausable] = _pauseDuration;

        emit PauserSet(_pausable, _pauser, _pauseDuration);
    }

    /// @notice Record a liveness proof. Called automatically by pause(), but pausers
    ///         can also call it independently to signal they're alive.
    /// @dev    Callable by any address because the contract does not have the list of pausers.
    ///         Monitoring must filter by known pauser addresses off-chain.
    ///         There is absolutely no benefit for strangers to call this function,
    ///         so there is no reason to guard this function.
    function heartbeat() public {
        latestHeartbeats[msg.sender] = block.timestamp;
        emit Heartbeat(msg.sender);
    }

    /// @notice Pause one or more pausable contracts.
    ///         CircuitBreaker must have the permission to pause every pausable in the list.
    ///         Caller must be the assigned pauser for every non-paused pausable in the list.
    ///         A pausable already paused is skipped.
    ///         If the pause is successful, the pauser cannot pause the same contract again
    ///         without explicit re-assignment from the admin.
    ///         Skipped contracts do not need re-assignment.
    ///         Updates the caller's heartbeat timestamp. 
    /// @dev    The call is atomic: if any pausable reverts, no pausables in the batch get paused.
    ///         This behavior mirrors the basic EVM principle: the state changes entirely or not at all.
    ///         Duplicate entries are skipped (emits AlreadyPaused on subsequent occurrences).
    ///         The pauser mapping is deleted before calling pauseFor to prevent reentrancy.
    ///         The post-condition (isPaused) verifies the contract is paused. If it's not paused, the call reverts.
    ///         The transaction reverts on the first failed pause immediately without trying the rest of the contracts.
    ///         No validation that _pausable is a contract. Calls to non-contract addresses revert.
    /// @param  _pausables Contracts to pause.
    function pause(address[] calldata _pausables) external {
        require(_pausables.length > 0, EmptyList());

        for (uint256 i = 0; i < _pausables.length; i++) {
            address pausable = _pausables[i];
            IPausable ipausable = IPausable(pausable);

            if (ipausable.isPaused()) {
                emit AlreadyPaused(pausable);
            } else {
                address pauser = pausers[pausable];
                require(msg.sender == pauser, SenderNotPauser(pausable, pauser));
                
                delete pausers[pausable];
                ipausable.pauseFor(pauseDurations[pausable]);
                require(ipausable.isPaused(), PauseFailed(pausable));
                emit Paused(pausable);
            }
        }

        heartbeat();
    }
}
