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
///         whose check-in has expired cannot pause. This ensures
///         that in case of emergency the committee is ready to respond.
///
/// @dev    Design decisions:
///         - One pauser per pausable. Keeps accountability clear and simple.
///         - Single-use pause. The pauser mapping is deleted on use.
///         - Global pause duration. Controlled by admin, applies to all pausables.
///         - Check-in gates pause. Pauser's check-in must not have expired.
///         - No pauser list. Offchain tracks the list of pausers.
///
///         Implicit assumptions:
///         - Pausables implement IPausable interface.
///         - Pausers are multisigs.
///         - Admin is DAO Agent or other DAO-controlled executor.
contract CircuitBreaker {
    /// @notice Minimum pause duration that can be set by the admin.
    uint256 public immutable MIN_PAUSE_DURATION;

    /// @notice Maximum pause duration that can be set by the admin.
    uint256 public constant MAX_PAUSE_DURATION = 30 days;

    /// @notice Minimum check-in window that can be set by the admin.
    uint256 public immutable MIN_CHECK_IN_WINDOW;

    /// @notice Maximum check-in window that can be set by the admin.
    uint256 public constant MAX_CHECK_IN_WINDOW = 1095 days;

    /// @notice Admin address that can assign pausers, set the pause duration, and set the check-in window.
    ///         Assumed to be DAO Agent or other DAO-controlled executor.
    address public immutable ADMIN;

    /// @notice Duration in seconds passed to pauseFor() on trigger. Applies to all pausables.
    ///         Controlled by the admin.
    uint256 public pauseDuration;

    /// @notice Duration in seconds within which a pauser must check in to remain eligible to pause.
    ///         Controlled by the admin.
    uint256 public checkInWindow;

    /// @notice Per-pausable pauser address. Entry is deleted upon successful use.
    mapping(address pausable => address pauser) public pauser;

    /// @notice Last timestamp each pauser proved liveness.
    ///         A pauser cannot call pause() if their check-in has expired.
    mapping(address pauser => uint256 latestCheckIn) public latestCheckIn;

    event AdminSet(address indexed admin);
    event PauseDurationSet(
        uint256 previousPauseDuration,
        uint256 pauseDuration
    );
    event CheckInWindowSet(
        uint256 previousCheckInWindow,
        uint256 checkInWindow
    );
    event PauserSet(
        address indexed pausable,
        address indexed pauser,
        address indexed previousPauser
    );
    event PauserRemoved(address indexed pausable, address indexed pauser);
    event Paused(
        address indexed pausable,
        address indexed pauser,
        uint256 pauseDuration
    );
    event CheckIn(address indexed pauser);

    error ZeroAdmin();
    error SelfAdmin();
    error ZeroPausable();
    error ZeroPauser();
    error ZeroMinPauseDuration();
    error MinPauseDurationTooHigh();
    error ZeroMinCheckInWindow();
    error MinCheckInWindowTooHigh();
    error PauseDurationOutOfRange();
    error SamePauseDuration();
    error CheckInWindowOutOfRange();
    error SameCheckInWindow();
    error CheckInExpired();
    error SenderNotAdmin();
    error SenderNotPauser(address pausable, address pauser);
    error PauseFailed();
    error ReentrantCall();

    /// @dev Transient reentrancy lock
    bool transient _lock;

    modifier nonReentrant() {
        require(!_lock, ReentrantCall());
        _lock = true;
        _;
        _lock = false;
    }

    modifier onlyAdmin() {
        require(msg.sender == ADMIN, SenderNotAdmin());
        _;
    }

    /// @param _admin Address that can assign pausers, set the pause duration, and set the check-in window.
    /// @param _minPauseDuration Minimum pause duration in seconds. Must be <= MAX_PAUSE_DURATION.
    /// @param _minCheckInWindow Minimum check-in window in seconds. Must be <= MAX_CHECK_IN_WINDOW.
    /// @param _pauseDuration Initial pause duration in seconds.
    /// @param _checkInWindow Initial check-in window in seconds.
    constructor(
        address _admin,
        uint256 _minPauseDuration,
        uint256 _minCheckInWindow,
        uint256 _pauseDuration,
        uint256 _checkInWindow
    ) {
        require(_admin != address(0), ZeroAdmin());
        require(_admin != address(this), SelfAdmin());
        require(_minPauseDuration != 0, ZeroMinPauseDuration());
        require(
            _minPauseDuration <= MAX_PAUSE_DURATION,
            MinPauseDurationTooHigh()
        );
        require(_minCheckInWindow != 0, ZeroMinCheckInWindow());
        require(
            _minCheckInWindow <= MAX_CHECK_IN_WINDOW,
            MinCheckInWindowTooHigh()
        );

        ADMIN = _admin;
        emit AdminSet(_admin);

        MIN_PAUSE_DURATION = _minPauseDuration;
        MIN_CHECK_IN_WINDOW = _minCheckInWindow;

        _setPauseDuration(_pauseDuration);
        _setCheckInWindow(_checkInWindow);
    }

    // =========================================================================
    // Admin functions
    // =========================================================================

    /// @notice Set the global pause duration applied to all pausables on trigger.
    /// @param  _pauseDuration Duration in seconds. Must be within [MIN_PAUSE_DURATION, MAX_PAUSE_DURATION].
    function setPauseDuration(uint256 _pauseDuration) external onlyAdmin {
        _setPauseDuration(_pauseDuration);
    }

    /// @notice Set the check-in window. Pausers must check in within this window to remain eligible to pause.
    /// @param  _checkInWindow Duration in seconds.
    function setCheckInWindow(uint256 _checkInWindow) external onlyAdmin {
        _setCheckInWindow(_checkInWindow);
    }

    /// @notice Assign or replace a pauser for a pausable contract.
    ///         Only 1 pauser per pausable, the previous pauser will be overwritten.
    ///         The pauser's check-in is set to the current timestamp on assignment.
    /// @param  _pausable Pausable contract to assign a pauser to.
    /// @param  _pauser Pauser address to assign to the pausable. Must be non-zero.
    /// @dev    Function does not check whether CircuitBreaker has the permission to pause.
    function setPauser(address _pausable, address _pauser) external onlyAdmin {
        require(_pausable != address(0), ZeroPausable());
        require(_pauser != address(0), ZeroPauser());

        address previousPauser = pauser[_pausable];
        pauser[_pausable] = _pauser;
        emit PauserSet(_pausable, _pauser, previousPauser);

        _checkIn(_pauser);
    }

    /// @notice Remove the pauser for a pausable contract.
    /// @param  _pausable Pausable contract to remove the pauser from.
    function removePauser(address _pausable) external onlyAdmin {
        require(_pausable != address(0), ZeroPausable());
        address removedPauser = pauser[_pausable];
        require(removedPauser != address(0), ZeroPauser());

        _removePauser(_pausable, removedPauser);
    }

    // =========================================================================
    // Pauser functions
    // =========================================================================

    /// @notice Record a liveness proof. Called by pausers to maintain eligibility to pause.
    ///         Also called internally by pause().
    ///         The pausable contract is passed as the parameter to perform auth check
    ///         to prevent strangers from calling this function and creating noise
    ///         for monitoring.
    /// @param  _pausable Any pausable the caller is registered as pauser for.
    /// @return assignedPauser The pauser address assigned to the pausable.
    function checkIn(
        address _pausable
    ) public returns (address assignedPauser) {
        assignedPauser = pauser[_pausable];
        require(
            msg.sender == assignedPauser,
            SenderNotPauser(_pausable, assignedPauser)
        );
        require(
            block.timestamp <= latestCheckIn[msg.sender] + checkInWindow,
            CheckInExpired()
        );

        _checkIn(msg.sender);
    }

    /// @notice Returns whether a pauser's check-in is valid (not expired).
    /// @param  _pauser Address of the pauser to check.
    function isCheckInValid(address _pauser) external view returns (bool) {
        return block.timestamp <= latestCheckIn[_pauser] + checkInWindow;
    }

    /// @notice Pause a pausable contract.
    ///         CircuitBreaker must have the permission to pause the pausable.
    ///         Caller must be the assigned pauser for the pausable.
    ///         Caller's check-in must not have expired.
    ///         The pauser cannot pause the same contract again without explicit
    ///         re-assignment from the admin.
    ///         Batching can be done externally (e.g. multisig multi-send).
    /// @param  _pausable Contract to pause.
    function pause(address _pausable) external nonReentrant {
        address assignedPauser = checkIn(_pausable);

        uint256 _pauseDuration = pauseDuration;
        IPausable _iPausable = IPausable(_pausable);

        _removePauser(_pausable, assignedPauser);
        _iPausable.pauseFor(_pauseDuration);
        require(_iPausable.isPaused(), PauseFailed());

        emit Paused(_pausable, assignedPauser, _pauseDuration);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Validates and sets the global pause duration.
    function _setPauseDuration(uint256 _pauseDuration) internal {
        require(_pauseDuration != pauseDuration, SamePauseDuration());
        require(
            _pauseDuration >= MIN_PAUSE_DURATION &&
                _pauseDuration <= MAX_PAUSE_DURATION,
            PauseDurationOutOfRange()
        );

        uint256 previousPauseDuration = pauseDuration;
        pauseDuration = _pauseDuration;

        emit PauseDurationSet(previousPauseDuration, _pauseDuration);
    }

    /// @dev Validates and sets the check-in window duration.
    function _setCheckInWindow(uint256 _checkInWindow) internal {
        require(_checkInWindow != checkInWindow, SameCheckInWindow());
        require(
            _checkInWindow >= MIN_CHECK_IN_WINDOW &&
                _checkInWindow <= MAX_CHECK_IN_WINDOW,
            CheckInWindowOutOfRange()
        );

        uint256 previousCheckInWindow = checkInWindow;
        checkInWindow = _checkInWindow;

        emit CheckInWindowSet(previousCheckInWindow, _checkInWindow);
    }

    /// @dev Removes a pauser from a pausable and emits the removal event.
    function _removePauser(address _pausable, address _pauser) internal {
        delete pauser[_pausable];
        emit PauserRemoved(_pausable, _pauser);
    }

    /// @dev Records a check-in for the given pauser.
    function _checkIn(address _pauser) internal {
        latestCheckIn[_pauser] = block.timestamp;
        emit CheckIn(_pauser);
    }
}
