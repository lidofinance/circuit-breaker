// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

/// @title  IPausable
/// @notice Interface pausable contracts must implement for CircuitBreaker compatibility.
interface IPausable {
    /// @notice Whether the contract is currently paused.
    function isPaused() external view returns (bool);

    /// @notice Pause the contract for a given duration.
    /// @param  _duration Duration in seconds.
    function pauseFor(uint256 _duration) external;
}

/// @title  CircuitBreaker
/// @author Lido
/// @notice Instantly pauses contracts in an emergency without a DAO vote.
/// @dev    DAO votes are too slow to respond to active exploits. This contract lets
///         the DAO delegate pause authority to designated pausers that can act instantly.
///
///         Design:
///         - Immutable admin to avoid ownership exploits/mistakes.
///         - One pauser per pausable for clear accountability.
///         - Single-use pause minimizes damage if pauser is compromised.
///         - Same pause duration for all contracts for simplicity.
///         - Periodic heartbeat required to pause. A committee that cannot prove liveness
///           should not be trusted to respond in an emergency.
///
///         Assumptions:
///         - Admin is a DAO agent or other DAO-authorized executor.
///         - Admin is always honest.
///         - Admin can make mistakes.
///         - Pausable implements IPausable.
///         - Pausable is a trusted contract upon assignment.
///         - Pausable can become malicious later.
///         - Pauser is a DAO-approved multisig committee upon assignment.
///         - Pauser can become malicious later.
///         - Pauser can lose access to keys later.
///         - Pauser can make mistakes.
///         - CircuitBreaker has necessary pause roles upon trigger.
contract CircuitBreaker {
    // =========================================================================
    // Immutables
    // =========================================================================

    /// @notice Admin address.
    ///         Assumed to be a DAO agent or other DAO-authorized executor
    address public immutable ADMIN;

    /// @notice Inclusive lower bound for pauseDuration in seconds.
    ///         Configurable for different networks.
    uint256 public immutable MIN_PAUSE_DURATION;

    /// @notice Inclusive upper bound for pauseDuration in seconds.
    ///         Configurable for different networks.
    uint256 public immutable MAX_PAUSE_DURATION;

    /// @notice Inclusive lower bound for heartbeatInterval in seconds.
    ///         Configurable for different networks.
    uint256 public immutable MIN_HEARTBEAT_INTERVAL;

    /// @notice Inclusive upper bound for heartbeatInterval in seconds.
    ///         Configurable for different networks.
    uint256 public immutable MAX_HEARTBEAT_INTERVAL;

    // =========================================================================
    // State variables
    // =========================================================================

    /// @notice Duration in seconds of the pause applied to the pausable on trigger.
    uint256 public pauseDuration;

    /// @notice Timeframe in seconds added to the current timestamp on heartbeat to compute the expiry.
    uint256 public heartbeatInterval;

    /// @notice Per-pausable pauser address.
    mapping(address pausable => address pauser) public getPauser;

    /// @notice Timestamp after which a pauser is no longer eligible to pause or refresh.
    mapping(address pauser => uint256 expiresAt) public getHeartbeatExpiry;

    /// @dev Cross-pausable reentrancy guard.
    bool transient lock;

    // =========================================================================
    // Events
    // =========================================================================

    event CircuitBreakerInitialized(
        address indexed admin,
        uint256 minPauseDuration,
        uint256 maxPauseDuration,
        uint256 minHeartbeatInterval,
        uint256 maxHeartbeatInterval
    );

    event PauserSet(address indexed pausable, address indexed previousPauser, address indexed pauser);
    event PauseDurationUpdated(uint256 previousPauseDuration, uint256 pauseDuration);
    event HeartbeatIntervalUpdated(uint256 previousHeartbeatInterval, uint256 heartbeatInterval);
    event HeartbeatUpdated(address indexed pauser);
    event PauseTriggered(address indexed pausable, address indexed pauser, uint256 pauseDuration);

    // =========================================================================
    // Errors
    // =========================================================================

    error AdminIsZero();

    error MinPauseDurationIsZero();
    error MaxPauseDurationIsZero();
    error MinPauseDurationExceedsMax();

    error MinHeartbeatIntervalIsZero();
    error MaxHeartbeatIntervalIsZero();
    error MinHeartbeatIntervalExceedsMax();

    error PauseDurationBelowMin();
    error PauseDurationAboveMax();
    error PauseDurationUnchanged();

    error HeartbeatIntervalBelowMin();
    error HeartbeatIntervalAboveMax();
    error HeartbeatIntervalUnchanged();

    error PausableIsZero();
    error SenderNotAdmin();
    error SenderNotPauser();

    error HeartbeatExpired();
    error PauseFailed();
    error ReentrantCall();

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier nonReentrant() {
        require(!lock, ReentrantCall());
        lock = true;
        _;
        lock = false;
    }

    modifier onlyAdmin() {
        require(msg.sender == ADMIN, SenderNotAdmin());
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _admin                 Admin address.
    /// @param _minPauseDuration      Lower bound for pause duration.
    /// @param _maxPauseDuration      Upper bound for pause duration.
    /// @param _minHeartbeatInterval  Lower bound for heartbeat interval.
    /// @param _maxHeartbeatInterval  Upper bound for heartbeat interval.
    /// @param _pauseDuration         Initial pause duration.
    /// @param _heartbeatInterval     Initial heartbeat interval.
    constructor(
        address _admin,
        uint256 _minPauseDuration,
        uint256 _maxPauseDuration,
        uint256 _minHeartbeatInterval,
        uint256 _maxHeartbeatInterval,
        uint256 _pauseDuration,
        uint256 _heartbeatInterval
    ) {
        require(_admin != address(0), AdminIsZero());
        require(_minPauseDuration != 0, MinPauseDurationIsZero());
        require(_maxPauseDuration != 0, MaxPauseDurationIsZero());
        require(_minPauseDuration <= _maxPauseDuration, MinPauseDurationExceedsMax());
        require(_minHeartbeatInterval != 0, MinHeartbeatIntervalIsZero());
        require(_maxHeartbeatInterval != 0, MaxHeartbeatIntervalIsZero());
        require(_minHeartbeatInterval <= _maxHeartbeatInterval, MinHeartbeatIntervalExceedsMax());

        ADMIN = _admin;
        MIN_PAUSE_DURATION = _minPauseDuration;
        MAX_PAUSE_DURATION = _maxPauseDuration;
        MIN_HEARTBEAT_INTERVAL = _minHeartbeatInterval;
        MAX_HEARTBEAT_INTERVAL = _maxHeartbeatInterval;

        emit CircuitBreakerInitialized(
            _admin, _minPauseDuration, _maxPauseDuration, _minHeartbeatInterval, _maxHeartbeatInterval
        );

        _setPauseDuration(_pauseDuration);
        _setHeartbeatInterval(_heartbeatInterval);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /// @notice Return whether a pauser can pause or heartbeat at the moment.
    /// @param  _pauser Pauser address.
    function isPauserActive(address _pauser) public view returns (bool) {
        return block.timestamp <= getHeartbeatExpiry[_pauser];
    }

    // =========================================================================
    // Admin functions
    // =========================================================================

    /// @notice Set the pause duration applied on pause.
    /// @param  _pauseDuration New duration in seconds.
    function setPauseDuration(uint256 _pauseDuration) external onlyAdmin {
        require(_pauseDuration != pauseDuration, PauseDurationUnchanged());
        _setPauseDuration(_pauseDuration);
    }

    /// @notice Set the heartbeat interval pausers must maintain to remain active.
    /// @param  _heartbeatInterval New interval in seconds.
    function setHeartbeatInterval(uint256 _heartbeatInterval) external onlyAdmin {
        require(_heartbeatInterval != heartbeatInterval, HeartbeatIntervalUnchanged());
        _setHeartbeatInterval(_heartbeatInterval);
    }

    /// @notice Assign, replace, or remove a pauser for a pausable.
    ///         - Previous pauser will be overwritten.
    ///         - Heartbeat updated on assignment.
    /// @param  _pausable Pausable contract address.
    /// @param  _pauser New pauser address. Zero removes the pauser.
    /// @dev    Does not verify CircuitBreaker has pause permission on the pausable.
    ///         Does not verify pausable implements the correct interface.
    function setPauser(address _pausable, address _pauser) external onlyAdmin {
        _setPauser(_pausable, _pauser);
        
        if (_pauser != address(0)) _updateHeartbeat(_pauser);
    }

    // =========================================================================
    // Pauser functions
    // =========================================================================

    /// @notice Record a liveness proof to remain authorized to pause.
    /// @param  _pausable Pausable the caller is assigned to.
    /// @dev    Requires pausable only for auth lookup, preventing unassigned callers.
    function heartbeat(address _pausable) public {
        require(msg.sender == getPauser[_pausable], SenderNotPauser());
        require(isPauserActive(msg.sender), HeartbeatExpired());

        _updateHeartbeat(msg.sender);
    }

    /// @notice Pause a pausable contract.
    ///         - Updated heartbeat.
    ///         - Assumes pausable implements the correct interface.
    ///         - Assumes CircuitBreaker has the pause role for the pausable.
    /// @param  _pausable Pausable contract to pause.
    function pause(address _pausable) external nonReentrant {
        heartbeat(_pausable);

        uint256 duration = pauseDuration;
        IPausable pausable = IPausable(_pausable);

        _setPauser(_pausable, address(0));
        pausable.pauseFor(duration);
        require(pausable.isPaused(), PauseFailed());

        emit PauseTriggered(_pausable, msg.sender, duration);
    }

    // =========================================================================
    // Internal functions
    // =========================================================================

    function _updateHeartbeat(address _pauser) internal {
        getHeartbeatExpiry[_pauser] = block.timestamp + heartbeatInterval;
        emit HeartbeatUpdated(_pauser);
    }

   function _setPauser(address _pausable, address _pauser) internal {
        require(_pausable != address(0), PausableIsZero());

        address previousPauser = getPauser[_pausable];
        getPauser[_pausable] = _pauser;

        emit PauserSet(_pausable, previousPauser, _pauser);
    }

    function _setPauseDuration(uint256 _pauseDuration) internal {
        require(_pauseDuration >= MIN_PAUSE_DURATION, PauseDurationBelowMin());
        require(_pauseDuration <= MAX_PAUSE_DURATION, PauseDurationAboveMax());

        uint256 previousPauseDuration = pauseDuration;
        pauseDuration = _pauseDuration;

        emit PauseDurationUpdated(previousPauseDuration, _pauseDuration);
    }

    function _setHeartbeatInterval(uint256 _heartbeatInterval) internal {
        require(_heartbeatInterval >= MIN_HEARTBEAT_INTERVAL, HeartbeatIntervalBelowMin());
        require(_heartbeatInterval <= MAX_HEARTBEAT_INTERVAL, HeartbeatIntervalAboveMax());

        uint256 previousHeartbeatInterval = heartbeatInterval;
        heartbeatInterval = _heartbeatInterval;

        emit HeartbeatIntervalUpdated(previousHeartbeatInterval, _heartbeatInterval);
    }
}
