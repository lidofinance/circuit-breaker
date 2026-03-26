// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {CircuitBreaker, IPausable} from "../src/CircuitBreaker.sol";

// ---------------------------------------------------------------------------
// Mock: normal pausable that honours pauseFor
// ---------------------------------------------------------------------------
contract MockPausable is IPausable {
    bool private _paused;
    uint256 private _resumeSince;

    function isPaused() external view returns (bool) {
        return _paused;
    }

    function pauseFor(uint256 duration) external {
        _paused = true;
        _resumeSince = block.timestamp + duration;
    }

    function getResumeSinceTimestamp() external view returns (uint256) {
        return _resumeSince;
    }

    function setState(bool paused) external {
        _paused = paused;
    }
}

// ---------------------------------------------------------------------------
// Mock: isPaused() always returns false → PauseFailed
// ---------------------------------------------------------------------------
contract MockPausablePauseFails is IPausable {
    function isPaused() external pure returns (bool) {
        return false;
    }

    function pauseFor(uint256) external {}
}

// ---------------------------------------------------------------------------
// Mock: pauseFor reverts
// ---------------------------------------------------------------------------
contract MockPausableReverting is IPausable {
    function isPaused() external pure returns (bool) {
        return false;
    }

    function pauseFor(uint256) external pure {
        revert("pauseFor: forced revert");
    }
}

// ---------------------------------------------------------------------------
// Mock: reentrancy — calls pause() again from pauseFor()
// ---------------------------------------------------------------------------
contract MockPausableReentrant is IPausable {
    CircuitBreaker private _cb;
    bool private _paused;
    bool private _reentered;

    constructor(CircuitBreaker cb_) {
        _cb = cb_;
    }

    function isPaused() external view returns (bool) {
        return _paused;
    }

    function pauseFor(uint256) external {
        _paused = true;
        if (!_reentered) {
            _reentered = true;
            _cb.pause(address(this));
        }
    }
}

// ---------------------------------------------------------------------------
// Mock: cross-pausable reentrancy — calls pause() on a different pausable
// ---------------------------------------------------------------------------
contract MockPausableCrossReentrant is IPausable {
    CircuitBreaker private _cb;
    address private _otherPausable;
    bool private _paused;

    constructor(CircuitBreaker cb_, address otherPausable_) {
        _cb = cb_;
        _otherPausable = otherPausable_;
    }

    function isPaused() external view returns (bool) {
        return _paused;
    }

    function pauseFor(uint256) external {
        _paused = true;
        _cb.pause(_otherPausable);
    }
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------
contract CircuitBreakerTest is Test {
    CircuitBreaker internal cb;
    MockPausable internal mockPausable;
    MockPausablePauseFails internal mockPauseFails;
    MockPausableReverting internal mockPauseReverts;

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MIN_PAUSE_DURATION = 3 days;
    uint256 internal constant MAX_PAUSE_DURATION = 30 days;
    uint256 internal constant PAUSE_DURATION = 14 days;

    uint256 internal constant MIN_HEARTBEAT_INTERVAL = 30 days;
    uint256 internal constant MAX_HEARTBEAT_INTERVAL = 1095 days;
    uint256 internal constant HEARTBEAT_INTERVAL = 365 days;

    function setUp() public {
        cb = new CircuitBreaker(
            admin,
            MIN_PAUSE_DURATION,
            MAX_PAUSE_DURATION,
            MIN_HEARTBEAT_INTERVAL,
            MAX_HEARTBEAT_INTERVAL,
            PAUSE_DURATION,
            HEARTBEAT_INTERVAL
        );
        mockPausable = new MockPausable();
        mockPauseFails = new MockPausablePauseFails();
        mockPauseReverts = new MockPausableReverting();
    }

    // =========================================================================
    // constructor
    // =========================================================================

    function test_Constructor_SetsStateAndImmutables() public view {
        assertEq(cb.ADMIN(), admin);
        assertEq(cb.MIN_PAUSE_DURATION(), MIN_PAUSE_DURATION);
        assertEq(cb.MAX_PAUSE_DURATION(), MAX_PAUSE_DURATION);
        assertEq(cb.MIN_HEARTBEAT_INTERVAL(), MIN_HEARTBEAT_INTERVAL);
        assertEq(cb.MAX_HEARTBEAT_INTERVAL(), MAX_HEARTBEAT_INTERVAL);
        assertEq(cb.pauseDuration(), PAUSE_DURATION);
        assertEq(cb.heartbeatInterval(), HEARTBEAT_INTERVAL);
    }

    function test_Constructor_EmitsEvents() public {
        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.CircuitBreakerInitialized(
            admin, MIN_PAUSE_DURATION, MAX_PAUSE_DURATION, MIN_HEARTBEAT_INTERVAL, MAX_HEARTBEAT_INTERVAL
        );
        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.PauseDurationUpdated(0, PAUSE_DURATION);
        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.HeartbeatIntervalUpdated(0, HEARTBEAT_INTERVAL);
        new CircuitBreaker(
            admin,
            MIN_PAUSE_DURATION,
            MAX_PAUSE_DURATION,
            MIN_HEARTBEAT_INTERVAL,
            MAX_HEARTBEAT_INTERVAL,
            PAUSE_DURATION,
            HEARTBEAT_INTERVAL
        );
    }

    function test_Constructor_RevertIf_ZeroAdmin() public {
        vm.expectRevert(CircuitBreaker.AdminIsZero.selector);
        new CircuitBreaker(
            address(0),
            MIN_PAUSE_DURATION,
            MAX_PAUSE_DURATION,
            MIN_HEARTBEAT_INTERVAL,
            MAX_HEARTBEAT_INTERVAL,
            PAUSE_DURATION,
            HEARTBEAT_INTERVAL
        );
    }

    function test_Constructor_RevertIf_ZeroMinPauseDuration() public {
        vm.expectRevert(CircuitBreaker.MinPauseDurationIsZero.selector);
        new CircuitBreaker(
            admin,
            0,
            MAX_PAUSE_DURATION,
            MIN_HEARTBEAT_INTERVAL,
            MAX_HEARTBEAT_INTERVAL,
            PAUSE_DURATION,
            HEARTBEAT_INTERVAL
        );
    }

    function test_Constructor_RevertIf_ZeroMaxPauseDuration() public {
        vm.expectRevert(CircuitBreaker.MaxPauseDurationIsZero.selector);
        new CircuitBreaker(
            admin,
            MIN_PAUSE_DURATION,
            0,
            MIN_HEARTBEAT_INTERVAL,
            MAX_HEARTBEAT_INTERVAL,
            PAUSE_DURATION,
            HEARTBEAT_INTERVAL
        );
    }

    function test_Constructor_RevertIf_MinPauseDurationExceedsMax() public {
        vm.expectRevert(CircuitBreaker.MinPauseDurationExceedsMax.selector);
        new CircuitBreaker(
            admin,
            MAX_PAUSE_DURATION + 1,
            MAX_PAUSE_DURATION,
            MIN_HEARTBEAT_INTERVAL,
            MAX_HEARTBEAT_INTERVAL,
            PAUSE_DURATION,
            HEARTBEAT_INTERVAL
        );
    }

    function test_Constructor_RevertIf_ZeroMinHeartbeatInterval() public {
        vm.expectRevert(CircuitBreaker.MinHeartbeatIntervalIsZero.selector);
        new CircuitBreaker(
            admin, MIN_PAUSE_DURATION, MAX_PAUSE_DURATION, 0, MAX_HEARTBEAT_INTERVAL, PAUSE_DURATION, HEARTBEAT_INTERVAL
        );
    }

    function test_Constructor_RevertIf_ZeroMaxHeartbeatInterval() public {
        vm.expectRevert(CircuitBreaker.MaxHeartbeatIntervalIsZero.selector);
        new CircuitBreaker(
            admin, MIN_PAUSE_DURATION, MAX_PAUSE_DURATION, MIN_HEARTBEAT_INTERVAL, 0, PAUSE_DURATION, HEARTBEAT_INTERVAL
        );
    }

    function test_Constructor_RevertIf_MinHeartbeatIntervalExceedsMax() public {
        vm.expectRevert(CircuitBreaker.MinHeartbeatIntervalExceedsMax.selector);
        new CircuitBreaker(
            admin,
            MIN_PAUSE_DURATION,
            MAX_PAUSE_DURATION,
            MAX_HEARTBEAT_INTERVAL + 1,
            MAX_HEARTBEAT_INTERVAL,
            PAUSE_DURATION,
            HEARTBEAT_INTERVAL
        );
    }

    function test_Constructor_RevertIf_PauseDurationOutOfBounds() public {
        vm.expectRevert(CircuitBreaker.PauseDurationBelowMin.selector);
        new CircuitBreaker(
            admin,
            MIN_PAUSE_DURATION,
            MAX_PAUSE_DURATION,
            MIN_HEARTBEAT_INTERVAL,
            MAX_HEARTBEAT_INTERVAL,
            MIN_PAUSE_DURATION - 1,
            HEARTBEAT_INTERVAL
        );

        vm.expectRevert(CircuitBreaker.PauseDurationAboveMax.selector);
        new CircuitBreaker(
            admin,
            MIN_PAUSE_DURATION,
            MAX_PAUSE_DURATION,
            MIN_HEARTBEAT_INTERVAL,
            MAX_HEARTBEAT_INTERVAL,
            MAX_PAUSE_DURATION + 1,
            HEARTBEAT_INTERVAL
        );
    }

    function test_Constructor_RevertIf_HeartbeatIntervalOutOfBounds() public {
        vm.expectRevert(CircuitBreaker.HeartbeatIntervalBelowMin.selector);
        new CircuitBreaker(
            admin,
            MIN_PAUSE_DURATION,
            MAX_PAUSE_DURATION,
            MIN_HEARTBEAT_INTERVAL,
            MAX_HEARTBEAT_INTERVAL,
            PAUSE_DURATION,
            MIN_HEARTBEAT_INTERVAL - 1
        );

        vm.expectRevert(CircuitBreaker.HeartbeatIntervalAboveMax.selector);
        new CircuitBreaker(
            admin,
            MIN_PAUSE_DURATION,
            MAX_PAUSE_DURATION,
            MIN_HEARTBEAT_INTERVAL,
            MAX_HEARTBEAT_INTERVAL,
            PAUSE_DURATION,
            MAX_HEARTBEAT_INTERVAL + 1
        );
    }

    // =========================================================================
    // setPauseDuration
    // =========================================================================

    function test_SetPauseDuration_UpdatesAndEmits() public {
        uint256 newDuration = MAX_PAUSE_DURATION;

        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.PauseDurationUpdated(PAUSE_DURATION, newDuration);
        vm.prank(admin);
        cb.setPauseDuration(newDuration);

        assertEq(cb.pauseDuration(), newDuration);
    }

    function test_SetPauseDuration_AtBoundaries() public {
        vm.prank(admin);
        cb.setPauseDuration(MAX_PAUSE_DURATION);
        assertEq(cb.pauseDuration(), MAX_PAUSE_DURATION);

        vm.prank(admin);
        cb.setPauseDuration(MIN_PAUSE_DURATION);
        assertEq(cb.pauseDuration(), MIN_PAUSE_DURATION);
    }

    function test_SetPauseDuration_RevertIf_SenderNotAdmin() public {
        vm.expectRevert(CircuitBreaker.SenderNotAdmin.selector);
        vm.prank(stranger);
        cb.setPauseDuration(MAX_PAUSE_DURATION);
    }

    function test_SetPauseDuration_RevertIf_Unchanged() public {
        vm.expectRevert(CircuitBreaker.PauseDurationUnchanged.selector);
        vm.prank(admin);
        cb.setPauseDuration(PAUSE_DURATION);
    }

    function test_SetPauseDuration_RevertIf_OutOfBounds() public {
        vm.startPrank(admin);

        vm.expectRevert(CircuitBreaker.PauseDurationBelowMin.selector);
        cb.setPauseDuration(MIN_PAUSE_DURATION - 1);

        vm.expectRevert(CircuitBreaker.PauseDurationAboveMax.selector);
        cb.setPauseDuration(MAX_PAUSE_DURATION + 1);

        vm.stopPrank();
    }

    // =========================================================================
    // setHeartbeatInterval
    // =========================================================================

    function test_SetHeartbeatInterval_UpdatesAndEmits() public {
        uint256 newInterval = MAX_HEARTBEAT_INTERVAL;

        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.HeartbeatIntervalUpdated(HEARTBEAT_INTERVAL, newInterval);
        vm.prank(admin);
        cb.setHeartbeatInterval(newInterval);

        assertEq(cb.heartbeatInterval(), newInterval);
    }

    function test_SetHeartbeatInterval_AtBoundaries() public {
        vm.prank(admin);
        cb.setHeartbeatInterval(MAX_HEARTBEAT_INTERVAL);
        assertEq(cb.heartbeatInterval(), MAX_HEARTBEAT_INTERVAL);

        vm.prank(admin);
        cb.setHeartbeatInterval(MIN_HEARTBEAT_INTERVAL);
        assertEq(cb.heartbeatInterval(), MIN_HEARTBEAT_INTERVAL);
    }

    function test_SetHeartbeatInterval_DoesNotAffectExistingPausers() public {
        _assignPauser(address(mockPausable), pauser);

        vm.warp(block.timestamp + HEARTBEAT_INTERVAL - 1);
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));

        vm.prank(admin);
        cb.setHeartbeatInterval(MIN_HEARTBEAT_INTERVAL);

        // Pauser's expiry was locked at heartbeat time with the old interval,
        // so reducing the interval does not retroactively invalidate them.
        vm.warp(block.timestamp + MIN_HEARTBEAT_INTERVAL + 1);
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));

        assertTrue(cb.isPauserActive(pauser));
    }

    function test_SetHeartbeatInterval_RevertIf_SenderNotAdmin() public {
        vm.expectRevert(CircuitBreaker.SenderNotAdmin.selector);
        vm.prank(stranger);
        cb.setHeartbeatInterval(MAX_HEARTBEAT_INTERVAL);
    }

    function test_SetHeartbeatInterval_RevertIf_Unchanged() public {
        vm.expectRevert(CircuitBreaker.HeartbeatIntervalUnchanged.selector);
        vm.prank(admin);
        cb.setHeartbeatInterval(HEARTBEAT_INTERVAL);
    }

    function test_SetHeartbeatInterval_RevertIf_OutOfBounds() public {
        vm.startPrank(admin);

        vm.expectRevert(CircuitBreaker.HeartbeatIntervalBelowMin.selector);
        cb.setHeartbeatInterval(MIN_HEARTBEAT_INTERVAL - 1);

        vm.expectRevert(CircuitBreaker.HeartbeatIntervalAboveMax.selector);
        cb.setHeartbeatInterval(MAX_HEARTBEAT_INTERVAL + 1);

        vm.stopPrank();
    }

    // =========================================================================
    // setPauser
    // =========================================================================

    function test_SetPauser_AssignsAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit CircuitBreaker.PauserSet(address(mockPausable), address(0), pauser);
        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.HeartbeatUpdated(pauser);

        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser);

        assertEq(cb.getPauser(address(mockPausable)), pauser);
        assertEq(cb.getHeartbeatExpiry(pauser), block.timestamp + HEARTBEAT_INTERVAL);
    }

    function test_SetPauser_OverridesAndEmits() public {
        address pauser2 = makeAddr("pauser2");
        _assignPauser(address(mockPausable), pauser);

        vm.expectEmit(true, true, true, true);
        emit CircuitBreaker.PauserSet(address(mockPausable), pauser, pauser2);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser2);

        assertEq(cb.getPauser(address(mockPausable)), pauser2);
    }

    function test_SetPauser_RemovesAndEmits() public {
        _assignPauser(address(mockPausable), pauser);

        vm.expectEmit(true, true, true, true);
        emit CircuitBreaker.PauserSet(address(mockPausable), pauser, address(0));

        vm.recordLogs();
        vm.prank(admin);
        cb.setPauser(address(mockPausable), address(0));

        assertEq(cb.getPauser(address(mockPausable)), address(0));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != CircuitBreaker.HeartbeatUpdated.selector);
        }
    }

    function test_SetPauser_SamePauserReassignment() public {
        _assignPauser(address(mockPausable), pauser);

        vm.warp(block.timestamp + HEARTBEAT_INTERVAL / 2);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser);

        assertEq(cb.getHeartbeatExpiry(pauser), block.timestamp + HEARTBEAT_INTERVAL);
    }

    function test_SetPauser_AfterRemoval() public {
        _assignPauser(address(mockPausable), pauser);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), address(0));

        address pauser2 = makeAddr("pauser2");
        _assignPauser(address(mockPausable), pauser2);

        assertEq(cb.getPauser(address(mockPausable)), pauser2);

        vm.prank(pauser2);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
    }

    function test_SetPauser_RevertIf_ZeroPausable() public {
        vm.expectRevert(CircuitBreaker.PausableIsZero.selector);
        vm.prank(admin);
        cb.setPauser(address(0), pauser);
    }

    function test_SetPauser_RevertIf_SenderNotAdmin() public {
        vm.expectRevert(CircuitBreaker.SenderNotAdmin.selector);
        vm.prank(stranger);
        cb.setPauser(address(mockPausable), pauser);
    }

    // =========================================================================
    // heartbeat
    // =========================================================================

    function test_Heartbeat_UpdatesAndEmits() public {
        _assignPauser(address(mockPausable), pauser);

        vm.warp(block.timestamp + 1 hours);
        uint256 ts = block.timestamp;

        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.HeartbeatUpdated(pauser);
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));

        assertEq(cb.getHeartbeatExpiry(pauser), ts + HEARTBEAT_INTERVAL);
    }

    function test_Heartbeat_SucceedsAtExactIntervalBoundary() public {
        _assignPauser(address(mockPausable), pauser);
        vm.warp(block.timestamp + HEARTBEAT_INTERVAL);

        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));

        assertEq(cb.getHeartbeatExpiry(pauser), block.timestamp + HEARTBEAT_INTERVAL);
    }

    function test_Heartbeat_UpdatesTimestampOnSubsequentCall() public {
        _assignPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));
        uint256 ts1 = block.timestamp;

        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));
        uint256 ts2 = block.timestamp;

        assertEq(cb.getHeartbeatExpiry(pauser), ts2 + HEARTBEAT_INTERVAL);
        assertGt(ts2, ts1);
    }

    function test_Heartbeat_TracksEachPauserIndependently() public {
        MockPausable mp2 = new MockPausable();
        address pauser2 = makeAddr("pauser2");
        _assignPauser(address(mockPausable), pauser);
        _assignPauser(address(mp2), pauser2);

        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));
        uint256 ts1 = block.timestamp;

        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauser2);
        cb.heartbeat(address(mp2));
        uint256 ts2 = block.timestamp;

        assertEq(cb.getHeartbeatExpiry(pauser), ts1 + HEARTBEAT_INTERVAL);
        assertEq(cb.getHeartbeatExpiry(pauser2), ts2 + HEARTBEAT_INTERVAL);
    }

    function test_Heartbeat_StillWorksViaOtherPausable_AfterOneConsumed() public {
        MockPausable mp2 = new MockPausable();
        _assignPauser(address(mockPausable), pauser);
        _assignPauser(address(mp2), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauser);
        cb.heartbeat(address(mp2));

        assertEq(cb.getHeartbeatExpiry(pauser), block.timestamp + HEARTBEAT_INTERVAL);
    }

    function test_Heartbeat_RevertIf_SenderNotPauser() public {
        _assignPauser(address(mockPausable), pauser);

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(stranger);
        cb.heartbeat(address(mockPausable));
    }

    function test_Heartbeat_RevertIf_NoPauserAssigned() public {
        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));
    }

    function test_Heartbeat_RevertIf_HeartbeatExpired() public {
        _assignPauser(address(mockPausable), pauser);
        vm.warp(block.timestamp + HEARTBEAT_INTERVAL + 1);

        vm.expectRevert(CircuitBreaker.HeartbeatExpired.selector);
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));
    }

    function test_Heartbeat_RevertIf_PauserConsumedByPause() public {
        _assignPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));
    }

    // =========================================================================
    // isPauserActive
    // =========================================================================

    function test_IsPauserActive() public {
        _assignPauser(address(mockPausable), pauser);
        assertTrue(cb.isPauserActive(pauser));

        vm.warp(block.timestamp + HEARTBEAT_INTERVAL);
        assertTrue(cb.isPauserActive(pauser));

        vm.warp(block.timestamp + 1);
        assertFalse(cb.isPauserActive(pauser));
    }

    // =========================================================================
    // pause
    // =========================================================================

    function test_Pause_HappyPath() public {
        _assignPauser(address(mockPausable), pauser);

        vm.warp(block.timestamp + 1 hours);
        uint256 ts = block.timestamp;

        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.HeartbeatUpdated(pauser);
        vm.expectEmit(true, true, true, true);
        emit CircuitBreaker.PauserSet(address(mockPausable), pauser, address(0));
        vm.expectEmit(true, true, false, true);
        emit CircuitBreaker.PauseTriggered(address(mockPausable), pauser, PAUSE_DURATION);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        assertTrue(mockPausable.isPaused());
        assertEq(mockPausable.getResumeSinceTimestamp(), ts + PAUSE_DURATION);
        assertEq(cb.getPauser(address(mockPausable)), address(0));
        assertEq(cb.getHeartbeatExpiry(pauser), ts + HEARTBEAT_INTERVAL);
    }

    function test_Pause_SingleUse() public {
        _assignPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.pause(address(mockPausable));

        // Cannot pause again even after target unpauses
        mockPausable.setState(false);
        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    function test_Pause_UsesUpdatedPauseDuration() public {
        _assignPauser(address(mockPausable), pauser);

        uint256 newDuration = MAX_PAUSE_DURATION;
        vm.prank(admin);
        cb.setPauseDuration(newDuration);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + newDuration);
    }

    function test_Pause_MultiplePausables_Independent() public {
        MockPausable mp2 = new MockPausable();
        _assignPauser(address(mockPausable), pauser);
        _assignPauser(address(mp2), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        assertEq(cb.getPauser(address(mockPausable)), address(0));
        assertEq(cb.getPauser(address(mp2)), pauser);

        vm.prank(pauser);
        cb.pause(address(mp2));
        assertTrue(mp2.isPaused());
    }

    function test_Pause_CrossPausableHeartbeatThenPause() public {
        MockPausable mp2 = new MockPausable();
        _assignPauser(address(mockPausable), pauser);
        _assignPauser(address(mp2), pauser);

        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));

        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauser);
        cb.pause(address(mp2));

        assertEq(cb.getHeartbeatExpiry(pauser), block.timestamp + HEARTBEAT_INTERVAL);
        assertTrue(mp2.isPaused());
        assertEq(cb.getPauser(address(mockPausable)), pauser);
    }

    function test_Pause_FullLifecycle_AssignPauseRearmPause() public {
        _assignPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
        assertEq(cb.getPauser(address(mockPausable)), address(0));

        mockPausable.setState(false);
        _assignPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + PAUSE_DURATION);
    }

    function test_Pause_AdminIsNotImplicitlyPauser() public {
        _assignPauser(address(mockPausable), pauser);

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(admin);
        cb.pause(address(mockPausable));

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(admin);
        cb.heartbeat(address(mockPausable));
    }

    function test_Pause_RevertIf_NoPauserAssigned() public {
        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    function test_Pause_RevertIf_WrongCaller() public {
        _assignPauser(address(mockPausable), pauser);

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(stranger);
        cb.pause(address(mockPausable));
    }

    function test_Pause_RevertIf_HeartbeatExpired() public {
        _assignPauser(address(mockPausable), pauser);
        vm.warp(block.timestamp + HEARTBEAT_INTERVAL + 1);

        vm.expectRevert(CircuitBreaker.HeartbeatExpired.selector);
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    function test_Pause_RevertIf_PauserSetToZero() public {
        _assignPauser(address(mockPausable), pauser);

        vm.prank(admin);
        cb.setPauser(address(mockPausable), address(0));

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    function test_Pause_RevertIf_PausableIsEOA() public {
        address eoa = makeAddr("eoa");
        _assignPauser(eoa, pauser);

        vm.prank(pauser);
        vm.expectRevert();
        cb.pause(eoa);
    }

    function test_Pause_RevertIf_PauseFailed() public {
        _assignPauser(address(mockPauseFails), pauser);

        vm.expectRevert(CircuitBreaker.PauseFailed.selector);
        vm.prank(pauser);
        cb.pause(address(mockPauseFails));
    }

    function test_Pause_RevertIf_PauseForReverts() public {
        _assignPauser(address(mockPauseReverts), pauser);

        vm.expectRevert("pauseFor: forced revert");
        vm.prank(pauser);
        cb.pause(address(mockPauseReverts));
    }

    function test_Pause_RevertIf_Reentrancy() public {
        MockPausableReentrant reentrant = new MockPausableReentrant(cb);
        _assignPauser(address(reentrant), pauser);

        vm.expectRevert(CircuitBreaker.ReentrantCall.selector);
        vm.prank(pauser);
        cb.pause(address(reentrant));
    }

    function test_Pause_RevertIf_CrossPausableReentrancy() public {
        MockPausable target = new MockPausable();
        MockPausableCrossReentrant reentrant = new MockPausableCrossReentrant(cb, address(target));

        _assignPauser(address(reentrant), pauser);
        _assignPauser(address(target), pauser);

        vm.expectRevert(CircuitBreaker.ReentrantCall.selector);
        vm.prank(pauser);
        cb.pause(address(reentrant));
    }

    // =========================================================================
    // fuzz
    // =========================================================================

    function testFuzz_SetPauseDuration(uint256 duration) public {
        duration = bound(duration, MIN_PAUSE_DURATION, MAX_PAUSE_DURATION);
        vm.assume(duration != PAUSE_DURATION);
        vm.prank(admin);
        cb.setPauseDuration(duration);
        assertEq(cb.pauseDuration(), duration);
    }

    function testFuzz_SetHeartbeatInterval(uint256 interval) public {
        interval = bound(interval, MIN_HEARTBEAT_INTERVAL, MAX_HEARTBEAT_INTERVAL);
        vm.assume(interval != HEARTBEAT_INTERVAL);
        vm.prank(admin);
        cb.setHeartbeatInterval(interval);
        assertEq(cb.heartbeatInterval(), interval);
    }

    // =========================================================================
    // helpers
    // =========================================================================

    function _assignPauser(address _pausable, address _pauser) internal {
        vm.prank(admin);
        cb.setPauser(_pausable, _pauser);
    }
}
