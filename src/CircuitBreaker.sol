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
///         - Per-pausable pause duration. Set at pauser assignment, cleared together with pauser on use.
///         - Heartbeat signal for offchain only.
///         - No pauser list. Offchain tracks the list of pausers.
///
///         Implicit assumptions:
///         - Pausables implement IPausable interface.
///         - Pausers are multisigs.
///         - Admin is DAO Agent or other DAO-controlled executor.
contract CircuitBreaker {
    /// @notice Pauser and pause duration for a pausable contract.
    ///         address (20 bytes) + uint64 (8 bytes) pack into one 32-byte storage slot.
    struct PauseConfig {
        address pauser;
        uint64 duration;
    }

    error ZeroAdmin();
    error ZeroPauseDuration();
    error ZeroPausable();
    error ZeroPauser();
    error DurationTooLarge();
    error SenderNotAdmin();
    error SenderNotPauser(address pausable, address pauser);
    error PauseFailed(address pausable);

    event AdminSet(address indexed admin);
    event PauserSet(address indexed pausable, address indexed pauser, uint256 pauseDuration);
    event PauserRemoved(address indexed pausable);
    event Paused(address indexed pausable);
    event AlreadyPaused(address indexed pausable);
    event Heartbeat(address indexed sender);

    /// @notice Admin address that can assign pausers and set pause duration.
    ///         Assumed to be DAO Agent or other DAO-controlled executor.
    address public immutable ADMIN;

    /// @notice Per-pausable pauser and pause duration, packed into one storage slot.
    ///         pauser == address(0) means no pauser is assigned.
    ///         Entry is deleted upon successful use.
    mapping(address pausable => PauseConfig) public pauserConfigs;

    /// @notice Last timestamp each pauser proved liveness.
    ///         For offchain monitoring only.
    mapping(address pauser => uint256 latestHeartbeat) public latestHeartbeats;

    /// @param _admin Address that can assign pausers and set pause duration.
    constructor(address _admin) {
        require(_admin != address(0), ZeroAdmin());

        ADMIN = _admin;

        emit AdminSet(_admin);
    }

    /// @notice Assign or replace a pauser for a pausable contract.
    ///         Only 1 pauser per pausable, the previous pauser will be overwritten.
    ///         The pause duration is cleared together with the pauser on use.
    ///         Re-assigning requires providing a new duration.
    /// @param  _pausable Pausable contract to assign a pauser to.
    /// @param  _pauser Pauser address to assign to the pausable. Must be non-zero.
    /// @param  _pauseDuration Duration in seconds passed to pauseFor() on trigger. Must be non-zero.
    /// @dev    Function does not check whether CircuitBreaker has the permission to pause.
    function setPauser(address _pausable, address _pauser, uint256 _pauseDuration) external {
        require(msg.sender == ADMIN, SenderNotAdmin());
        require(_pausable != address(0), ZeroPausable());
        require(_pauser != address(0), ZeroPauser());
        require(_pauseDuration > 0, ZeroPauseDuration());
        require(_pauseDuration <= type(uint64).max, DurationTooLarge());

        pauserConfigs[_pausable] = PauseConfig(_pauser, uint64(_pauseDuration));

        emit PauserSet(_pausable, _pauser, _pauseDuration);
    }

    /// @notice Remove the pauser for a pausable contract and clear its pause duration.
    /// @param  _pausable Pausable contract to remove the pauser from.
    function removePauser(address _pausable) external {
        require(msg.sender == ADMIN, SenderNotAdmin());
        require(_pausable != address(0), ZeroPausable());
        require(pauserConfigs[_pausable].pauser != address(0), ZeroPauser());

        delete pauserConfigs[_pausable];

        emit PauserRemoved(_pausable);
    }

    /// @notice Record a liveness proof. Called automatically by pause(), but pausers
    ///         can also call it independently to signal they're alive.
    ///         The pausable contract is passed as the parameter to perform auth check
    ///         to prevent strangers from calling this function and creating noise
    ///         for monitoring.
    /// @param  _pausable Any pausable the caller is registered as pauser for.
    function heartbeat(address _pausable) external {
        PauseConfig memory config = pauserConfigs[_pausable];
        require(msg.sender == config.pauser, SenderNotPauser(_pausable, config.pauser));
        
        _heartbeat();
    }

    /// @notice Pause a pausable contract.
    ///         CircuitBreaker must have the permission to pause the pausable.
    ///         Caller must be the assigned pauser for the pausable.
    ///         If the pausable is already paused, the call is a no-op (emits AlreadyPaused).
    ///         If the pause is successful, the pauser cannot pause the same contract again
    ///         without explicit re-assignment from the admin.
    ///         Updates the caller's heartbeat timestamp.
    ///         Batching can be done externally (e.g. multisig multi-send)..
    /// @param  _pausable Contract to pause.
    function pause(address _pausable) external {
        IPausable ipausable = IPausable(_pausable);
        PauseConfig memory config = pauserConfigs[_pausable];

        require(msg.sender == config.pauser, SenderNotPauser(_pausable, config.pauser));

        if (ipausable.isPaused()) {
            emit AlreadyPaused(_pausable);
        } else {
            delete pauserConfigs[_pausable];
            ipausable.pauseFor(config.duration);
            require(ipausable.isPaused(), PauseFailed(_pausable));
            emit Paused(_pausable);
        }

        _heartbeat();
    }

    /// @dev Records liveness without auth check. Used internally by pause() which already
    ///      validates the caller is a registered pauser.
    function _heartbeat() private {
        latestHeartbeats[msg.sender] = block.timestamp;
        emit Heartbeat(msg.sender);
    }
}
