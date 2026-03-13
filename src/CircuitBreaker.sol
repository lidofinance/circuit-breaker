// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

interface IPausable {
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
    uint256 public constant MIN_PAUSE_DURATION = 3 days;

    /// @notice Maximum pause duration that can be set by the admin.
    uint256 public constant MAX_PAUSE_DURATION = 30 days;

    /// @notice Minimum check-in expiry that can be set by the admin.
    uint256 public constant MIN_CHECK_IN_EXPIRY = 30 days;

    /// @notice Maximum check-in expiry that can be set by the admin.
    uint256 public constant MAX_CHECK_IN_EXPIRY = 1095 days;

    /// @notice Admin address that can assign pausers, set the pause duration, and set the check-in expiry.
    ///         Assumed to be DAO Agent or other DAO-controlled executor.
    address public admin;

    /// @notice Duration in seconds passed to pauseFor() on trigger. Applies to all pausables.
    ///         Controlled by the admin.
    uint256 public pauseDuration;

    /// @notice Time in seconds after which a check-in expires and the pauser loses eligibility to pause.
    ///         Controlled by the admin.
    uint256 public checkInExpiry;

    /// @notice Per-pausable pauser address. Entry is deleted upon successful use.
    mapping(address pausable => address pauser) public pauser;

    /// @notice Last timestamp each pauser proved liveness.
    ///         A pauser cannot call pause() if their check-in has expired.
    mapping(address pauser => uint256 latestCheckIn) public latestCheckIn;

    event AdminSet(address indexed admin);
    event PauseDurationSet(uint256 pauseDuration);
    event CheckInExpirySet(uint256 checkInExpiry);
    event PauserSet(address indexed pausable, address indexed pauser, address indexed previousPauser);
    event PauserRemoved(address indexed pausable, address indexed pauser);
    event Paused(address indexed pausable);
    event CheckIn(address indexed pauser);

    error ZeroAdmin();
    error ZeroPausable();
    error ZeroPauser();
    error PauseDurationOutOfRange();
    error CheckInExpiryOutOfRange();
    error CheckInExpired();
    error SenderNotAdmin();
    error SenderNotPauser(address pausable, address pauser);

    modifier onlyAdmin() {
        require(msg.sender == admin, SenderNotAdmin());
        _;
    }

    /// @param _admin Address that can assign pausers, set the pause duration, and set the check-in expiry.
    /// @param _pauseDuration Initial duration in seconds passed to pauseFor() on trigger. Must be within [MIN_PAUSE_DURATION, MAX_PAUSE_DURATION].
    /// @param _checkInExpiry Initial check-in expiry in seconds.
    constructor(address _admin, uint256 _pauseDuration, uint256 _checkInExpiry) {
        _setAdmin(_admin);
        _setPauseDuration(_pauseDuration);
        _setCheckInExpiry(_checkInExpiry);
    }

    // =========================================================================
    // Admin functions
    // =========================================================================

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

    /// @notice Set the check-in expiry. Pausers must check in before expiry to remain eligible to pause.
    /// @param  _checkInExpiry Duration in seconds.
    function setCheckInExpiry(uint256 _checkInExpiry) external onlyAdmin {
        _setCheckInExpiry(_checkInExpiry);
    }

    /// @notice Assign or replace a pauser for a pausable contract.
    ///         Only 1 pauser per pausable, the previous pauser will be overwritten.
    ///         Initializes the pauser's check-in clock.
    /// @param  _pausable Pausable contract to assign a pauser to.
    /// @param  _pauser Pauser address to assign to the pausable. Must be non-zero.
    /// @dev    Function does not check whether CircuitBreaker has the permission to pause.
    function setPauser(address _pausable, address _pauser) external onlyAdmin {
        require(_pausable != address(0), ZeroPausable());

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

        delete pauser[_pausable];

        emit PauserRemoved(_pausable, removedPauser);
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
    function checkIn(address _pausable) public {
        require(msg.sender == pauser[_pausable], SenderNotPauser(_pausable, pauser[_pausable]));
        require(block.timestamp <= latestCheckIn[msg.sender] + checkInExpiry, CheckInExpired());

        _checkIn(msg.sender);
    }

    /// @notice Pause a pausable contract.
    ///         CircuitBreaker must have the permission to pause the pausable.
    ///         Caller must be the assigned pauser for the pausable.
    ///         Caller's check-in must not have expired.
    ///         The pauser cannot pause the same contract again without explicit
    ///         re-assignment from the admin.
    ///         Batching can be done externally (e.g. multisig multi-send).
    /// @param  _pausable Contract to pause.
    function pause(address _pausable) external {
        checkIn(_pausable);

        delete pauser[_pausable];
        IPausable(_pausable).pauseFor(pauseDuration);

        emit Paused(_pausable);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

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

    /// @dev Validates and sets the check-in expiry duration.
    function _setCheckInExpiry(uint256 _checkInExpiry) internal {
        require(_checkInExpiry >= MIN_CHECK_IN_EXPIRY && _checkInExpiry <= MAX_CHECK_IN_EXPIRY, CheckInExpiryOutOfRange());

        checkInExpiry = _checkInExpiry;

        emit CheckInExpirySet(_checkInExpiry);
    }

    /// @dev Sets the check-in timestamp for a pauser. Called by checkIn() (after auth
    ///      and expiry validation) and by setPauser() (to initialize the clock).
    function _checkIn(address _pauser) internal {
        require(_pauser != address(0), ZeroPauser());

        latestCheckIn[_pauser] = block.timestamp;
        emit CheckIn(_pauser);
    }
}
