// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

import {PauserRegistry} from "./PauserRegistry.sol";

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
/// @notice Emergency pause manager for pausable contracts.
/// @dev    Some setups (e.g. a DAO with on-chain voting) cannot respond fast enough
///         in emergency situations. This contract lets the admin delegate pause authority to
///         designated pausers that can act instantly.
///
///         Design:
///         - Immutable admin to avoid ownership exploits/mistakes.
///         - One pauser per pausable for clear accountability.
///         - Single-use pause minimizes damage if pauser is compromised.
///         - Same pause duration for all contracts for simplicity.
///         - Periodic heartbeat required to pause. A committee that cannot prove liveness
///           should not be trusted to respond in an emergency.
///
///         Trust assumptions:
///         - Admin is always honest.
///         - Pausable is a trusted contract upon registration.
///         - Pauser is a trusted multisig committee upon registration.
contract CircuitBreaker {
    using PauserRegistry for PauserRegistry.Storage;

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @notice Admin address.
    address public immutable ADMIN;

    /// @notice Inclusive lower bound for pauseDuration in seconds.
    uint256 public immutable MIN_PAUSE_DURATION;

    /// @notice Inclusive upper bound for pauseDuration in seconds.
    uint256 public immutable MAX_PAUSE_DURATION;

    /// @notice Inclusive lower bound for heartbeatInterval in seconds.
    uint256 public immutable MIN_HEARTBEAT_INTERVAL;

    /// @notice Inclusive upper bound for heartbeatInterval in seconds.
    uint256 public immutable MAX_HEARTBEAT_INTERVAL;

    // =========================================================================
    // State variables
    // =========================================================================

    /// @notice Duration in seconds of the pause applied to the pausable on trigger.
    uint256 public pauseDuration;

    /// @notice Time window in seconds since last heartbeat within which a pauser is considered active.
    uint256 public heartbeatInterval;

    /// @notice Timestamp after which a pauser is no longer eligible to heartbeat or pause.
    mapping(address pauser => uint256 timestamp) public heartbeatExpiry;

    /// @notice Pauser registry tracking pausable-to-pauser registrations.
    PauserRegistry.Storage internal registry;

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

    event PauseDurationUpdated(uint256 previousPauseDuration, uint256 pauseDuration);
    event HeartbeatIntervalUpdated(uint256 previousHeartbeatInterval, uint256 heartbeatInterval);
    event HeartbeatUpdated(address indexed pauser, uint256 heartbeatExpiry);
    event PauseTriggered(address indexed pausable, address indexed pauser, uint256 pauseDuration);

    // =========================================================================
    // Errors
    // =========================================================================

    error SenderNotAdmin();
    error SenderNotPauser();

    error AdminIsZero();

    error MinPauseDurationIsZero();
    error MaxPauseDurationIsZero();
    error MinPauseDurationExceedsMax();

    error PauseDurationBelowMin();
    error PauseDurationAboveMax();
    error PauseDurationUnchanged();

    error MinHeartbeatIntervalIsZero();
    error MaxHeartbeatIntervalIsZero();
    error MinHeartbeatIntervalExceedsMax();

    error HeartbeatIntervalBelowMin();
    error HeartbeatIntervalAboveMax();
    error HeartbeatIntervalUnchanged();

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
    /// @param _minPauseDuration      Inclusive lower bound for pause duration.
    /// @param _maxPauseDuration      Inclusive upper bound for pause duration.
    /// @param _minHeartbeatInterval  Inclusive lower bound for heartbeat interval.
    /// @param _maxHeartbeatInterval  Inclusive upper bound for heartbeat interval.
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

    /// @notice Return the pauser registered for a pausable.
    /// @param  _pausable Pausable contract address.
    function getPauser(address _pausable) external view returns (address) {
        return registry.getPauser(_pausable);
    }

    /// @notice Return all unique pauser addresses currently registered.
    function getPausers() external view returns (address[] memory) {
        return registry.getPausers();
    }

    /// @notice Return the number of unique pausers currently registered.
    function getPauserCount() external view returns (uint256) {
        return registry.getPauserCount();
    }

    /// @notice Return the number of pausables a pauser is currently registered for.
    /// @param  _pauser Pauser address.
    function getPausableCount(address _pauser) external view returns (uint256) {
        return registry.pausableCount[_pauser];
    }

    /// @notice Return whether a pauser's heartbeat window is still valid.
    /// @dev    Only checks the heartbeat expiry, not registration.
    /// @param  _pauser Pauser address.
    function isPauserLive(address _pauser) public view returns (bool) {
        return block.timestamp < heartbeatExpiry[_pauser];
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

    /// @notice Register, replace, or unregister a pauser for a pausable.
    ///         - Previous pauser will be overwritten.
    ///         - Heartbeat updated on registration.
    /// @param  _pausable Pausable contract address.
    /// @param  _pauser New pauser address. Zero unregisters the pauser.
    /// @dev    Does not verify CircuitBreaker has pause permission on the pausable.
    ///         Does not verify pausable implements the correct interface.
    function registerPauser(address _pausable, address _pauser) external onlyAdmin {
        registry.register(_pausable, _pauser);

        if (_pauser != address(0)) _updateHeartbeat(_pauser, false);
    }

    // =========================================================================
    // Pauser functions
    // =========================================================================

    /// @notice Record a liveness proof to remain authorized to pause.
    function heartbeat() public {
        require(registry.isRegistered(msg.sender), SenderNotPauser());
        _updateHeartbeat(msg.sender, true);
    }

    /// @notice Pause a pausable contract.
    ///         - Updates heartbeat.
    ///         - Assumes pausable implements the correct interface.
    ///         - Assumes CircuitBreaker has the pause role for the pausable.
    /// @param  _pausable Pausable contract to pause.
    function pause(address _pausable) external nonReentrant {
        require(msg.sender == registry.getPauser(_pausable), SenderNotPauser());
        _updateHeartbeat(msg.sender, true);

        uint256 duration = pauseDuration;
        IPausable pausable = IPausable(_pausable);

        registry.register(_pausable, address(0));
        pausable.pauseFor(duration);
        require(pausable.isPaused(), PauseFailed());

        emit PauseTriggered(_pausable, msg.sender, duration);
    }

    // =========================================================================
    // Internal functions
    // =========================================================================

    function _updateHeartbeat(address _pauser, bool _requireActive) internal {
        if (_requireActive) require(isPauserLive(_pauser), HeartbeatExpired());
        uint256 expiry = block.timestamp + heartbeatInterval;
        heartbeatExpiry[_pauser] = expiry;
        emit HeartbeatUpdated(_pauser, expiry);
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
