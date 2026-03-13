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
///         The check-in mechanism requires pausers to periodically prove liveness. A pauser
///         that has not checked in within the configured interval cannot pause. This ensures
///         that in case of emergency the committee is ready to respond.
///
/// @dev    Design decisions:
///         - One pauser per pausable. Keeps accountability clear and simple.
///         - Single-use pause. The pauser mapping is deleted on use.
///         - Global pause duration. Controlled by admin, applies to all pausables.
///         - Check-in gates pause. Pauser must have checked in within the interval.
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

    /// @notice Admin address that can assign pausers, set the pause duration, and set the check-in interval.
    ///         Assumed to be DAO Agent or other DAO-controlled executor.
    address public admin;

    /// @notice Duration in seconds passed to pauseFor() on trigger. Applies to all pausables.
    ///         Controlled by the admin.
    uint256 public pauseDuration;

    /// @notice Maximum time in seconds between check-ins for a pauser to remain eligible to pause.
    ///         Controlled by the admin.
    uint256 public checkInInterval;

    /// @notice Per-pausable pauser address. Entry is deleted upon successful use.
    mapping(address pausable => address pauser) public pauser;

    /// @notice Last timestamp each pauser proved liveness.
    ///         A pauser cannot call pause() if their last check-in is older than checkInInterval.
    mapping(address pauser => uint256 latestCheckIn) public latestCheckIn;

    event AdminSet(address indexed admin);
    event PauseDurationSet(uint256 pauseDuration);
    event CheckInIntervalSet(uint256 checkInInterval);
    event PauserSet(address indexed pausable, address indexed pauser);
    event PauserRemoved(address indexed pausable);
    event Paused(address indexed pausable);
    event AlreadyPaused(address indexed pausable);
    event CheckIn(address indexed sender);

    error ZeroAdmin();
    error ZeroPausable();
    error ZeroPauser();
    error PauseDurationOutOfRange();
    error CheckInExpired();
    error SenderNotAdmin();
    error SenderNotPauser(address pausable, address pauser);
    error PauseFailed(address pausable);

    modifier onlyAdmin() {
        require(msg.sender == admin, SenderNotAdmin());
        _;
    }

    /// @param _admin Address that can assign pausers, set the pause duration, and set the check-in interval.
    /// @param _pauseDuration Initial duration in seconds passed to pauseFor() on trigger. Must be within [MIN_PAUSE_DURATION, MAX_PAUSE_DURATION].
    /// @param _checkInInterval Initial check-in interval in seconds.
    constructor(address _admin, uint256 _pauseDuration, uint256 _checkInInterval) {
        _setAdmin(_admin);
        _setPauseDuration(_pauseDuration);
        _setCheckInInterval(_checkInInterval);
    }

    /// @notice Transfer admin role to a new address.
    /// @param  _newAdmin New admin address. Must be non-zero.
    function setAdmin(address _newAdmin) external onlyAdmin {
        _setAdmin(_newAdmin);
    }

    /// @notice Set the global pause duration applied to all pausables on trigger.
    /// @param  _pauseDuration Duration in seconds. Must be within [MIN_PAUSE_DURATION, MAX_PAUSE_DURATION].
    function setPauseDuration(uint256 _pauseDuration) external onlyAdmin {
        _setPauseDuration(_pauseDuration);
    }

    /// @notice Set the check-in interval. Pausers must check in within this interval to remain eligible to pause.
    /// @param  _checkInInterval Interval in seconds.
    function setCheckInInterval(uint256 _checkInInterval) external onlyAdmin {
        _setCheckInInterval(_checkInInterval);
    }

    /// @notice Assign or replace a pauser for a pausable contract.
    ///         Only 1 pauser per pausable, the previous pauser will be overwritten.
    /// @param  _pausable Pausable contract to assign a pauser to.
    /// @param  _pauser Pauser address to assign to the pausable. Must be non-zero.
    /// @dev    Function does not check whether CircuitBreaker has the permission to pause.
    function setPauser(address _pausable, address _pauser) external onlyAdmin {
        require(_pausable != address(0), ZeroPausable());
        require(_pauser != address(0), ZeroPauser());

        pauser[_pausable] = _pauser;

        emit PauserSet(_pausable, _pauser);
    }

    /// @notice Remove the pauser for a pausable contract.
    /// @param  _pausable Pausable contract to remove the pauser from.
    function removePauser(address _pausable) external onlyAdmin {
        require(_pausable != address(0), ZeroPausable());
        require(pauser[_pausable] != address(0), ZeroPauser());

        delete pauser[_pausable];

        emit PauserRemoved(_pausable);
    }

    /// @notice Record a liveness proof. Called automatically by pause(), but pausers
    ///         must also call it independently to maintain eligibility to pause.
    ///         The pausable contract is passed as the parameter to perform auth check
    ///         to prevent strangers from calling this function and creating noise
    ///         for monitoring.
    /// @param  _pausable Any pausable the caller is registered as pauser for.
    function checkIn(address _pausable) external {
        require(msg.sender == pauser[_pausable], SenderNotPauser(_pausable, pauser[_pausable]));

        _checkIn();
    }

    /// @notice Pause a pausable contract.
    ///         CircuitBreaker must have the permission to pause the pausable.
    ///         Caller must be the assigned pauser for the pausable.
    ///         Caller must have checked in within the configured check-in interval.
    ///         If the pausable is already paused, the call is a no-op (emits AlreadyPaused).
    ///         If the pause is successful, the pauser cannot pause the same contract again
    ///         without explicit re-assignment from the admin.
    ///         Updates the caller's check-in timestamp.
    ///         Batching can be done externally (e.g. multisig multi-send).
    /// @param  _pausable Contract to pause.
    function pause(address _pausable) external {
        IPausable ipausable = IPausable(_pausable);
        address assignedPauser = pauser[_pausable];

        require(msg.sender == assignedPauser, SenderNotPauser(_pausable, assignedPauser));
        require(block.timestamp <= latestCheckIn[msg.sender] + checkInInterval, CheckInExpired());

        if (ipausable.isPaused()) {
            emit AlreadyPaused(_pausable);
        } else {
            delete pauser[_pausable];
            ipausable.pauseFor(pauseDuration);
            require(ipausable.isPaused(), PauseFailed(_pausable));
            emit Paused(_pausable);
        }

        _checkIn();
    }

    /// @dev Validates and sets the admin address.
    function _setAdmin(address _newAdmin) internal {
        require(_newAdmin != address(0), ZeroAdmin());

        admin = _newAdmin;

        emit AdminSet(_newAdmin);
    }

    /// @dev Validates and sets the global pause duration.
    function _setPauseDuration(uint256 _pauseDuration) internal {
        require(_pauseDuration >= MIN_PAUSE_DURATION && _pauseDuration <= MAX_PAUSE_DURATION, PauseDurationOutOfRange());

        pauseDuration = _pauseDuration;

        emit PauseDurationSet(_pauseDuration);
    }

    /// @dev Sets the check-in interval.
    function _setCheckInInterval(uint256 _checkInInterval) internal {
        checkInInterval = _checkInInterval;

        emit CheckInIntervalSet(_checkInInterval);
    }

    /// @dev Records liveness without auth check. Used internally by checkIn() and pause(),
    ///      both of which validate the caller is a registered pauser.
    function _checkIn() private {
        latestCheckIn[msg.sender] = block.timestamp;
        emit CheckIn(msg.sender);
    }
}
