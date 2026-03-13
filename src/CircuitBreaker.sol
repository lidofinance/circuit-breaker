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
///         A global pause duration is controlled by the admin and applies to all pausables.
///
///         The heartbeat mechanism records pauser's liveness for offchain monitoring in order
///         to surface potentially unresponsive committees (e.g. due to lost keys) to make
///         sure that in case of emergency the committee is ready to pause.
///
/// @dev    Design decisions:
///         - One pauser per pausable. Keeps accountability clear and simple.
///         - Single-use pause. The pauser mapping is deleted on use.
///         - Global pause duration. Controlled by admin, applies to all pausables.
///         - Heartbeat signal for offchain only.
///         - No pauser list. Offchain tracks the list of pausers.
///
///         Implicit assumptions:
///         - Pausables implement IPausable interface.
///         - Pausers are multisigs.
///         - Admin is DAO Agent or other DAO-controlled executor.
contract CircuitBreaker {
    /// @notice Minimum pause duration that can be set by the admin.
    uint256 public constant MIN_PAUSE_DURATION = 3 days;

    /// @notice Maximum pause duration that can be set by the admin.
    uint256 public constant MAX_PAUSE_DURATION = 30 days;

    /// @notice Admin address that can assign pausers and set the global pause duration.
    ///         Assumed to be DAO Agent or other DAO-controlled executor.
    address public immutable ADMIN;

    /// @notice Duration in seconds passed to pauseFor() on trigger. Applies to all pausables.
    ///         Controlled by the admin.
    uint256 public pauseDuration;

    /// @notice Per-pausable pauser address. Entry is deleted upon successful use.
    mapping(address pausable => address pauser) public pausers;

    /// @notice Last timestamp each pauser proved liveness.
    ///         For offchain monitoring only.
    mapping(address pauser => uint256 latestHeartbeat) public latestHeartbeats;

    event AdminSet(address indexed admin);
    event PauseDurationSet(uint256 pauseDuration);
    event PauserSet(address indexed pausable, address indexed pauser);
    event PauserRemoved(address indexed pausable);
    event Paused(address indexed pausable);
    event AlreadyPaused(address indexed pausable);
    event Heartbeat(address indexed sender);

    error ZeroAdmin();
    error ZeroPausable();
    error ZeroPauser();
    error PauseDurationOutOfRange();
    error SenderNotAdmin();
    error SenderNotPauser(address pausable, address pauser);
    error PauseFailed(address pausable);

    modifier onlyAdmin() {
        require(msg.sender == ADMIN, SenderNotAdmin());
        _;
    }

    /// @param _admin Address that can assign pausers and control the global pause duration.
    /// @param _pauseDuration Initial duration in seconds passed to pauseFor() on trigger. Must be within [MIN_PAUSE_DURATION, MAX_PAUSE_DURATION].
    constructor(address _admin, uint256 _pauseDuration) {
        require(_admin != address(0), ZeroAdmin());
        ADMIN = _admin;
        emit AdminSet(_admin);
        
        _setPauseDuration(_pauseDuration);
    }

    /// @notice Set the global pause duration applied to all pausables on trigger.
    /// @param  _pauseDuration Duration in seconds. Must be within [MIN_PAUSE_DURATION, MAX_PAUSE_DURATION].
    function setPauseDuration(uint256 _pauseDuration) external onlyAdmin {
        _setPauseDuration(_pauseDuration);
    }

    /// @notice Assign or replace a pauser for a pausable contract.
    ///         Only 1 pauser per pausable, the previous pauser will be overwritten.
    /// @param  _pausable Pausable contract to assign a pauser to.
    /// @param  _pauser Pauser address to assign to the pausable. Must be non-zero.
    /// @dev    Function does not check whether CircuitBreaker has the permission to pause.
    function setPauser(address _pausable, address _pauser) external onlyAdmin {
        require(_pausable != address(0), ZeroPausable());
        require(_pauser != address(0), ZeroPauser());

        pausers[_pausable] = _pauser;

        emit PauserSet(_pausable, _pauser);
    }

    /// @notice Remove the pauser for a pausable contract.
    /// @param  _pausable Pausable contract to remove the pauser from.
    function removePauser(address _pausable) external onlyAdmin {
        require(_pausable != address(0), ZeroPausable());
        require(pausers[_pausable] != address(0), ZeroPauser());

        delete pausers[_pausable];

        emit PauserRemoved(_pausable);
    }

    /// @notice Record a liveness proof. Called automatically by pause(), but pausers
    ///         can also call it independently to signal they're alive.
    ///         The pausable contract is passed as the parameter to perform auth check
    ///         to prevent strangers from calling this function and creating noise
    ///         for monitoring.
    /// @param  _pausable Any pausable the caller is registered as pauser for.
    function heartbeat(address _pausable) external {
        require(msg.sender == pausers[_pausable], SenderNotPauser(_pausable, pausers[_pausable]));

        _heartbeat();
    }

    /// @notice Pause a pausable contract.
    ///         CircuitBreaker must have the permission to pause the pausable.
    ///         Caller must be the assigned pauser for the pausable.
    ///         If the pausable is already paused, the call is a no-op (emits AlreadyPaused).
    ///         If the pause is successful, the pauser cannot pause the same contract again
    ///         without explicit re-assignment from the admin.
    ///         Updates the caller's heartbeat timestamp.
    ///         Batching can be done externally (e.g. multisig multi-send).
    /// @param  _pausable Contract to pause.
    function pause(address _pausable) external {
        IPausable ipausable = IPausable(_pausable);
        address pauser = pausers[_pausable];

        require(msg.sender == pauser, SenderNotPauser(_pausable, pauser));

        if (ipausable.isPaused()) {
            emit AlreadyPaused(_pausable);
        } else {
            delete pausers[_pausable];
            ipausable.pauseFor(pauseDuration);
            require(ipausable.isPaused(), PauseFailed(_pausable));
            emit Paused(_pausable);
        }

        _heartbeat();
    }

    /// @dev Validates and sets the global pause duration.
    function _setPauseDuration(uint256 _pauseDuration) internal {
        require(_pauseDuration >= MIN_PAUSE_DURATION && _pauseDuration <= MAX_PAUSE_DURATION, PauseDurationOutOfRange());

        pauseDuration = _pauseDuration;

        emit PauseDurationSet(_pauseDuration);
    }

    /// @dev Records liveness without auth check. Used internally by pause() which already
    ///      validates the caller is a registered pauser.
    function _heartbeat() private {
        latestHeartbeats[msg.sender] = block.timestamp;
        emit Heartbeat(msg.sender);
    }
}
