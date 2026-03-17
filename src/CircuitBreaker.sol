// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

/// @title  IPausable
/// @notice Interface that pausable contracts must implement to be compatible with CircuitBreaker.
interface IPausable {
    /// @notice Returns whether the contract is currently paused.
    /// @return bool whether the contract is currently paused.
    function isPaused() external view returns (bool);

    /// @notice Pauses the contract for a given duration.
    /// @param  _duration Pause duration in seconds.
    function pauseFor(uint256 _duration) external;
}

/// @title  CircuitBreaker
/// @author Lido
/// @notice Instantly pauses contracts in an emergency without a DAO vote.
/// @dev    DAO votes are too slow to respond to active exploits. This contract lets
///         the DAO delegate pause authority to designated pausers that can act instantly.
///
///         Design:
///         - Immutable admin for robustness.
///         - One pauser per pausable for clear accountability.
///         - Single-use pause reducing trust surface.
///         - Same pause duration for all contracts for simplicity.
///         - Periodic check-in required to pause. A committee that cannot prove liveness
///           should not be trusted to respond in an emergency.
///
///         Assumptions:
///         - Admin is a DAO agent or equivalent executor.
///         - Admin is never malicious but can make mistakes.
///         - Pausable implements IPausable.
///         - Pausable is a trusted contract upon assignment.
///         - Pausable can later be exploited.
///         - Pauser is a DAO-approved multisig committee upon assignment.
///         - Pauser can later be compromised, lose access, or become malicious.
///         - Pauser can make mistakes.
///         - CircuitBreaker has necessary pause roles upon trigger.
contract CircuitBreaker {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum pause duration that can be set by the admin.
    uint256 public constant MAX_PAUSE_DURATION = 30 days;

    /// @notice Maximum check-in window that can be set by the admin.
    uint256 public constant MAX_CHECK_IN_WINDOW = 1095 days;

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @notice Minimum pause duration that can be set by the admin.
    uint256 public immutable MIN_PAUSE_DURATION;

    /// @notice Minimum check-in window that can be set by the admin.
    uint256 public immutable MIN_CHECK_IN_WINDOW;

    /// @notice Admin address that can assign pausers, set the pause duration, and set the check-in window.
    address public immutable ADMIN;

    // =========================================================================
    // State variables
    // =========================================================================

    /// @notice Duration in seconds passed to pauseFor() on trigger. Applies to all pausables.
    uint256 public pauseDuration;

    /// @notice Duration in seconds within which a pauser must check in to remain eligible to pause.
    uint256 public checkInWindow;

    /// @notice Per-pausable pauser address. Entry is deleted upon successful use.
    mapping(address pausable => address pauser) public pauserOf;

    /// @notice Latest timestamp a pauser proved liveness.
    mapping(address pauser => uint256 timestamp) public latestCheckIn;

    /// @dev Transient reentrancy lock.
    bool transient _lock;

    // =========================================================================
    // Events
    // =========================================================================

    event AdminSet(address indexed admin);

    event PauseDurationSet(uint256 previousPauseDuration, uint256 pauseDuration);
    event CheckInWindowSet(uint256 previousCheckInWindow, uint256 checkInWindow);

    event PauserSet(address indexed pausable, address indexed pauser, address indexed previousPauser);
    event CheckedIn(address indexed pauser);

    event Paused(address indexed pausable, address indexed pauser, uint256 pauseDuration);

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroAdmin();
    error SelfAdmin();
    error ZeroMinPauseDuration();
    error MinPauseDurationTooHigh();
    error ZeroMinCheckInWindow();
    error MinCheckInWindowTooHigh();

    error PauseDurationOutOfRange();
    error SamePauseDuration();
    error CheckInWindowOutOfRange();
    error SameCheckInWindow();

    error ZeroPausable();
    error SenderNotAdmin(address expectedAdmin);
    error SenderNotPauser(address pausable, address assignedPauser);

    error CheckInExpired();
    error PauseFailed();
    error ReentrantCall();

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier nonReentrant() {
        require(!_lock, ReentrantCall());
        _lock = true;
        _;
        _lock = false;
    }

    modifier onlyAdmin() {
        require(msg.sender == ADMIN, SenderNotAdmin(ADMIN));
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _admin Admin address. Must not be zero or self.
    /// @param _minPauseDuration Minimum pause duration in seconds. Must be <= MAX_PAUSE_DURATION.
    /// @param _minCheckInWindow Minimum check-in window in seconds. Must be <= MAX_CHECK_IN_WINDOW.
    /// @param _pauseDuration Initial pause duration in seconds. Must be within [_minPauseDuration, MAX_PAUSE_DURATION].
    /// @param _checkInWindow Initial check-in window in seconds. Must be within [_minCheckInWindow, MAX_CHECK_IN_WINDOW].
    constructor(
        address _admin,
        uint256 _minPauseDuration,
        uint256 _minCheckInWindow,
        uint256 _pauseDuration,
        uint256 _checkInWindow
    ) {
        // --- Immutable configuration ---

        require(_admin != address(0), ZeroAdmin());
        require(_admin != address(this), SelfAdmin());
        require(_minPauseDuration != 0, ZeroMinPauseDuration());
        require(_minPauseDuration <= MAX_PAUSE_DURATION, MinPauseDurationTooHigh());
        require(_minCheckInWindow != 0, ZeroMinCheckInWindow());
        require(_minCheckInWindow <= MAX_CHECK_IN_WINDOW, MinCheckInWindowTooHigh());

        ADMIN = _admin;
        MIN_PAUSE_DURATION = _minPauseDuration;
        MIN_CHECK_IN_WINDOW = _minCheckInWindow;

        emit AdminSet(_admin);

        // --- Initial mutable state ---

        require(
            _pauseDuration >= MIN_PAUSE_DURATION && _pauseDuration <= MAX_PAUSE_DURATION, PauseDurationOutOfRange()
        );
        require(
            _checkInWindow >= MIN_CHECK_IN_WINDOW && _checkInWindow <= MAX_CHECK_IN_WINDOW, CheckInWindowOutOfRange()
        );

        pauseDuration = _pauseDuration;
        emit PauseDurationSet(0, _pauseDuration);

        checkInWindow = _checkInWindow;
        emit CheckInWindowSet(0, _checkInWindow);
    }

    // =========================================================================
    // Admin functions
    // =========================================================================

    /// @notice Set the global pause duration applied to all pausables on trigger.
    /// @param  _pauseDuration New pause duration in seconds. Must be within [MIN_PAUSE_DURATION, MAX_PAUSE_DURATION].
    function setPauseDuration(uint256 _pauseDuration) external onlyAdmin {
        uint256 previousPauseDuration = pauseDuration;
        require(_pauseDuration != previousPauseDuration, SamePauseDuration());
        require(
            _pauseDuration >= MIN_PAUSE_DURATION && _pauseDuration <= MAX_PAUSE_DURATION, PauseDurationOutOfRange()
        );

        pauseDuration = _pauseDuration;

        emit PauseDurationSet(previousPauseDuration, _pauseDuration);
    }

    /// @notice Set the check-in window. Pausers must check in within this window to remain eligible to pause.
    /// @param  _checkInWindow New check-in window in seconds. Must be within [MIN_CHECK_IN_WINDOW, MAX_CHECK_IN_WINDOW].
    function setCheckInWindow(uint256 _checkInWindow) external onlyAdmin {
        uint256 previousCheckInWindow = checkInWindow;
        require(_checkInWindow != previousCheckInWindow, SameCheckInWindow());
        require(
            _checkInWindow >= MIN_CHECK_IN_WINDOW && _checkInWindow <= MAX_CHECK_IN_WINDOW, CheckInWindowOutOfRange()
        );

        checkInWindow = _checkInWindow;

        emit CheckInWindowSet(previousCheckInWindow, _checkInWindow);
    }

    /// @notice Assign, replace, or remove a pauser for a pausable contract.
    ///         Only 1 pauser per pausable, the previous pauser will be overwritten.
    ///         The pauser's check-in is set to the current timestamp on assignment,
    ///         implying the admin must have confirmed the liveness
    ///         of the assigned pauser outside of this contract. 
    ///         Pass address(0) as _pauser to remove the pauser.
    /// @param  _pausable Pausable contract address.
    /// @param  _pauser New pauser address. Zero address removes the pauser.
    /// @dev    Function does not check whether CircuitBreaker has the permission to pause.
    ///         Re-assigning the same pauser is permitted and refreshes their check-in timestamp.
    ///         Removal is combined with assignment to prevent a front-running attack where
    ///         the pauser pauses the contract between a removePauser and setPauser call,
    ///         causing the DAO vote enactment to revert.
    function setPauser(address _pausable, address _pauser) external onlyAdmin {
        require(_pausable != address(0), ZeroPausable());

        address previousPauser = pauserOf[_pausable];
        pauserOf[_pausable] = _pauser;

        if (_pauser != address(0)) {
            latestCheckIn[_pauser] = block.timestamp;
            emit CheckedIn(_pauser);
        }

        emit PauserSet(_pausable, _pauser, previousPauser);
    }

    // =========================================================================
    // Pauser functions
    // =========================================================================

    /// @notice Record a liveness proof. Called by pausers to maintain eligibility to pause.
    ///         Also invoked by `pause()` before triggering the pause.
    /// @param  _pausable Pausable contract the caller is registered as pauser for.
    /// @dev    The pausable contract is passed as the parameter to perform auth check
    ///         to prevent strangers from calling this function and creating noise
    ///         for monitoring.
    function checkIn(address _pausable) public {
        address assignedPauser = pauserOf[_pausable];
        require(msg.sender == assignedPauser, SenderNotPauser(_pausable, assignedPauser));
        require(block.timestamp <= latestCheckIn[msg.sender] + checkInWindow, CheckInExpired());

        latestCheckIn[msg.sender] = block.timestamp;
        emit CheckedIn(msg.sender);
    }

    /// @notice Pause a pausable contract.
    ///         CircuitBreaker must have the permission to pause the pausable.
    ///         Caller must be the assigned pauser for the pausable.
    ///         Caller's check-in must not have expired.
    ///         The pauser cannot pause the same contract again without explicit
    ///         re-assignment from the admin.
    ///         Batching can be done externally (e.g. multisig multi-send).
    /// @param  _pausable Pausable contract to pause.
    function pause(address _pausable) external nonReentrant {
        checkIn(_pausable);

        uint256 duration = pauseDuration;
        IPausable pausable = IPausable(_pausable);

        pausable.pauseFor(duration);
        require(pausable.isPaused(), PauseFailed());

        delete pauserOf[_pausable];

        emit PauserSet(_pausable, address(0), msg.sender);
        emit Paused(_pausable, msg.sender, duration);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /// @notice Returns whether a pauser's check-in is valid (not expired).
    /// @param  _pauser Pauser address to check.
    /// @return True if the pauser's check-in has not expired.
    function isCheckInValid(address _pauser) external view returns (bool) {
        return block.timestamp <= latestCheckIn[_pauser] + checkInWindow;
    }
}
