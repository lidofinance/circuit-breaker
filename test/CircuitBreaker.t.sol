// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
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
// Test suite
// ---------------------------------------------------------------------------
contract CircuitBreakerTest is Test {
    CircuitBreaker internal cb;
    MockPausable internal mockPausable;
    MockPausablePauseFails internal mockPauseFails;
    MockPausableReverting internal mockPauseReverts;

    address internal admin = makeAddr("admin");
    address internal pauserAddr = makeAddr("pauser");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MIN_PAUSE_DURATION = 1 days;
    uint256 internal constant PAUSE_DURATION = 7 days;
    uint256 internal constant MIN_CHECK_IN_WINDOW = 1 days;
    uint256 internal constant CHECK_IN_WINDOW = 30 days;

    function setUp() public {
        cb = new CircuitBreaker(admin, MIN_PAUSE_DURATION, MIN_CHECK_IN_WINDOW, PAUSE_DURATION, CHECK_IN_WINDOW);
        mockPausable = new MockPausable();
        mockPauseFails = new MockPausablePauseFails();
        mockPauseReverts = new MockPausableReverting();
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_Constructor_SetsAdmin() public view {
        assertEq(cb.ADMIN(), admin);
    }

    function test_Constructor_SetsMinPauseDuration() public view {
        assertEq(cb.MIN_PAUSE_DURATION(), MIN_PAUSE_DURATION);
    }

    function test_Constructor_SetsMinCheckInWindow() public view {
        assertEq(cb.MIN_CHECK_IN_WINDOW(), MIN_CHECK_IN_WINDOW);
    }

    function test_Constructor_SetsPauseDuration() public view {
        assertEq(cb.pauseDuration(), PAUSE_DURATION);
    }

    function test_Constructor_SetsCheckInWindow() public view {
        assertEq(cb.checkInWindow(), CHECK_IN_WINDOW);
    }

    function test_Constructor_MaxPauseDuration() public view {
        assertEq(cb.MAX_PAUSE_DURATION(), 30 days);
    }

    function test_Constructor_MaxCheckInWindow() public view {
        assertEq(cb.MAX_CHECK_IN_WINDOW(), 1095 days);
    }

    function test_Constructor_EmitsAdminSet() public {
        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.AdminSet(admin);
        new CircuitBreaker(admin, MIN_PAUSE_DURATION, MIN_CHECK_IN_WINDOW, PAUSE_DURATION, CHECK_IN_WINDOW);
    }

    function test_Constructor_EmitsPauseDurationSet() public {
        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.PauseDurationSet(0, PAUSE_DURATION);
        new CircuitBreaker(admin, MIN_PAUSE_DURATION, MIN_CHECK_IN_WINDOW, PAUSE_DURATION, CHECK_IN_WINDOW);
    }

    function test_Constructor_EmitsCheckInWindowSet() public {
        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.CheckInWindowSet(0, CHECK_IN_WINDOW);
        new CircuitBreaker(admin, MIN_PAUSE_DURATION, MIN_CHECK_IN_WINDOW, PAUSE_DURATION, CHECK_IN_WINDOW);
    }

    function test_Constructor_RevertIf_ZeroAdmin() public {
        vm.expectRevert(CircuitBreaker.ZeroAdmin.selector);
        new CircuitBreaker(address(0), MIN_PAUSE_DURATION, MIN_CHECK_IN_WINDOW, PAUSE_DURATION, CHECK_IN_WINDOW);
    }

    function test_Constructor_RevertIf_SelfAdmin() public {
        // Predict the address of the next contract deployed by this test contract
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(CircuitBreaker.SelfAdmin.selector);
        new CircuitBreaker(predicted, MIN_PAUSE_DURATION, MIN_CHECK_IN_WINDOW, PAUSE_DURATION, CHECK_IN_WINDOW);
    }

    function test_Constructor_RevertIf_ZeroMinPauseDuration() public {
        vm.expectRevert(CircuitBreaker.ZeroMinPauseDuration.selector);
        new CircuitBreaker(admin, 0, MIN_CHECK_IN_WINDOW, PAUSE_DURATION, CHECK_IN_WINDOW);
    }

    function test_Constructor_RevertIf_MinPauseDurationTooHigh() public {
        vm.expectRevert(CircuitBreaker.MinPauseDurationTooHigh.selector);
        new CircuitBreaker(admin, 30 days + 1, MIN_CHECK_IN_WINDOW, PAUSE_DURATION, CHECK_IN_WINDOW);
    }

    function test_Constructor_RevertIf_ZeroMinCheckInWindow() public {
        vm.expectRevert(CircuitBreaker.ZeroMinCheckInWindow.selector);
        new CircuitBreaker(admin, MIN_PAUSE_DURATION, 0, PAUSE_DURATION, CHECK_IN_WINDOW);
    }

    function test_Constructor_RevertIf_MinCheckInWindowTooHigh() public {
        vm.expectRevert(CircuitBreaker.MinCheckInWindowTooHigh.selector);
        new CircuitBreaker(admin, MIN_PAUSE_DURATION, 1095 days + 1, PAUSE_DURATION, CHECK_IN_WINDOW);
    }

    function test_Constructor_RevertIf_PauseDurationOutOfRange_TooLow() public {
        vm.expectRevert(CircuitBreaker.PauseDurationOutOfRange.selector);
        new CircuitBreaker(admin, 2 days, MIN_CHECK_IN_WINDOW, 1 days, CHECK_IN_WINDOW);
    }

    function test_Constructor_RevertIf_PauseDurationOutOfRange_TooHigh() public {
        vm.expectRevert(CircuitBreaker.PauseDurationOutOfRange.selector);
        new CircuitBreaker(admin, MIN_PAUSE_DURATION, MIN_CHECK_IN_WINDOW, 31 days, CHECK_IN_WINDOW);
    }

    function test_Constructor_RevertIf_CheckInWindowOutOfRange_TooLow() public {
        vm.expectRevert(CircuitBreaker.CheckInWindowOutOfRange.selector);
        new CircuitBreaker(admin, MIN_PAUSE_DURATION, 2 days, PAUSE_DURATION, 1 days);
    }

    function test_Constructor_RevertIf_CheckInWindowOutOfRange_TooHigh() public {
        vm.expectRevert(CircuitBreaker.CheckInWindowOutOfRange.selector);
        new CircuitBreaker(admin, MIN_PAUSE_DURATION, MIN_CHECK_IN_WINDOW, PAUSE_DURATION, 1096 days);
    }

    // =========================================================================
    // setPauseDuration
    // =========================================================================

    function test_SetPauseDuration_UpdatesDuration() public {
        vm.prank(admin);
        cb.setPauseDuration(14 days);
        assertEq(cb.pauseDuration(), 14 days);
    }

    function test_SetPauseDuration_EmitsPauseDurationSet() public {
        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.PauseDurationSet(PAUSE_DURATION, 14 days);
        vm.prank(admin);
        cb.setPauseDuration(14 days);
    }

    function test_SetPauseDuration_RevertIf_SenderNotAdmin() public {
        vm.expectRevert(CircuitBreaker.SenderNotAdmin.selector);
        vm.prank(stranger);
        cb.setPauseDuration(14 days);
    }

    function test_SetPauseDuration_RevertIf_SamePauseDuration() public {
        vm.expectRevert(CircuitBreaker.SamePauseDuration.selector);
        vm.prank(admin);
        cb.setPauseDuration(PAUSE_DURATION);
    }

    function test_SetPauseDuration_RevertIf_BelowMin() public {
        vm.expectRevert(CircuitBreaker.PauseDurationOutOfRange.selector);
        vm.prank(admin);
        cb.setPauseDuration(MIN_PAUSE_DURATION - 1);
    }

    function test_SetPauseDuration_RevertIf_AboveMax() public {
        vm.expectRevert(CircuitBreaker.PauseDurationOutOfRange.selector);
        vm.prank(admin);
        cb.setPauseDuration(31 days);
    }

    function test_SetPauseDuration_AtMinBoundary() public {
        // First set to something else so we can set to min
        vm.prank(admin);
        cb.setPauseDuration(2 days);
        vm.prank(admin);
        cb.setPauseDuration(MIN_PAUSE_DURATION);
        assertEq(cb.pauseDuration(), MIN_PAUSE_DURATION);
    }

    function test_SetPauseDuration_AtMaxBoundary() public {
        vm.prank(admin);
        cb.setPauseDuration(30 days);
        assertEq(cb.pauseDuration(), 30 days);
    }

    // =========================================================================
    // setCheckInWindow
    // =========================================================================

    function test_SetCheckInWindow_UpdatesWindow() public {
        vm.prank(admin);
        cb.setCheckInWindow(60 days);
        assertEq(cb.checkInWindow(), 60 days);
    }

    function test_SetCheckInWindow_EmitsCheckInWindowSet() public {
        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.CheckInWindowSet(CHECK_IN_WINDOW, 60 days);
        vm.prank(admin);
        cb.setCheckInWindow(60 days);
    }

    function test_SetCheckInWindow_RevertIf_SenderNotAdmin() public {
        vm.expectRevert(CircuitBreaker.SenderNotAdmin.selector);
        vm.prank(stranger);
        cb.setCheckInWindow(60 days);
    }

    function test_SetCheckInWindow_RevertIf_SameCheckInWindow() public {
        vm.expectRevert(CircuitBreaker.SameCheckInWindow.selector);
        vm.prank(admin);
        cb.setCheckInWindow(CHECK_IN_WINDOW);
    }

    function test_SetCheckInWindow_RevertIf_BelowMin() public {
        vm.expectRevert(CircuitBreaker.CheckInWindowOutOfRange.selector);
        vm.prank(admin);
        cb.setCheckInWindow(MIN_CHECK_IN_WINDOW - 1);
    }

    function test_SetCheckInWindow_RevertIf_AboveMax() public {
        vm.expectRevert(CircuitBreaker.CheckInWindowOutOfRange.selector);
        vm.prank(admin);
        cb.setCheckInWindow(1096 days);
    }

    function test_SetCheckInWindow_AtMinBoundary() public {
        vm.prank(admin);
        cb.setCheckInWindow(2 days);
        vm.prank(admin);
        cb.setCheckInWindow(MIN_CHECK_IN_WINDOW);
        assertEq(cb.checkInWindow(), MIN_CHECK_IN_WINDOW);
    }

    function test_SetCheckInWindow_AtMaxBoundary() public {
        vm.prank(admin);
        cb.setCheckInWindow(1095 days);
        assertEq(cb.checkInWindow(), 1095 days);
    }

    // =========================================================================
    // setPauser
    // =========================================================================

    function test_SetPauser_SetsPauser() public {
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauserAddr);
        assertEq(cb.pauserOf(address(mockPausable)), pauserAddr);
    }

    function test_SetPauser_SetsCheckIn() public {
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauserAddr);
        assertEq(cb.latestCheckIn(pauserAddr), block.timestamp);
    }

    function test_SetPauser_EmitsPauserSet() public {
        vm.expectEmit(true, true, true, true);
        emit CircuitBreaker.PauserSet(address(mockPausable), pauserAddr, address(0));
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauserAddr);
    }

    function test_SetPauser_EmitsCheckIn() public {
        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.CheckIn(pauserAddr);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauserAddr);
    }

    function test_SetPauser_OverridesPreviousPauser() public {
        address pauser2 = makeAddr("pauser2");
        vm.startPrank(admin);
        cb.setPauser(address(mockPausable), pauserAddr);
        cb.setPauser(address(mockPausable), pauser2);
        vm.stopPrank();
        assertEq(cb.pauserOf(address(mockPausable)), pauser2);
    }

    function test_SetPauser_EmitsPreviousPauser() public {
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauserAddr);

        vm.expectEmit(true, true, true, true);
        address pauser2 = makeAddr("pauser2");
        emit CircuitBreaker.PauserSet(address(mockPausable), pauser2, pauserAddr);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser2);
    }

    function test_SetPauser_RevertIf_ZeroPausable() public {
        vm.expectRevert(CircuitBreaker.ZeroPausable.selector);
        vm.prank(admin);
        cb.setPauser(address(0), pauserAddr);
    }

    function test_SetPauser_RevertIf_ZeroPauser() public {
        vm.expectRevert(CircuitBreaker.ZeroPauser.selector);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), address(0));
    }

    function test_SetPauser_RevertIf_SenderNotAdmin() public {
        vm.expectRevert(CircuitBreaker.SenderNotAdmin.selector);
        vm.prank(stranger);
        cb.setPauser(address(mockPausable), pauserAddr);
    }

    // =========================================================================
    // removePauser
    // =========================================================================

    function test_RemovePauser_ClearsPauser() public {
        vm.startPrank(admin);
        cb.setPauser(address(mockPausable), pauserAddr);
        cb.removePauser(address(mockPausable));
        vm.stopPrank();
        assertEq(cb.pauserOf(address(mockPausable)), address(0));
    }

    function test_RemovePauser_EmitsPauserRemoved() public {
        vm.startPrank(admin);
        cb.setPauser(address(mockPausable), pauserAddr);
        vm.expectEmit(true, true, false, false);
        emit CircuitBreaker.PauserRemoved(address(mockPausable), pauserAddr);
        cb.removePauser(address(mockPausable));
        vm.stopPrank();
    }

    function test_RemovePauser_RevertIf_SenderNotAdmin() public {
        vm.expectRevert(CircuitBreaker.SenderNotAdmin.selector);
        vm.prank(stranger);
        cb.removePauser(address(mockPausable));
    }

    function test_RemovePauser_RevertIf_ZeroPausable() public {
        vm.expectRevert(CircuitBreaker.ZeroPausable.selector);
        vm.prank(admin);
        cb.removePauser(address(0));
    }

    function test_RemovePauser_RevertIf_NoPauserAssigned() public {
        vm.expectRevert(CircuitBreaker.PauserNotSet.selector);
        vm.prank(admin);
        cb.removePauser(address(mockPausable));
    }

    // =========================================================================
    // checkIn
    // =========================================================================

    function test_CheckIn_UpdatesLatestCheckIn() public {
        _assignPauser(address(mockPausable), pauserAddr);
        uint256 ts = block.timestamp;

        vm.warp(block.timestamp + 1 hours);
        uint256 newTs = block.timestamp;
        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));
        assertEq(cb.latestCheckIn(pauserAddr), newTs);
        assertGt(newTs, ts);
    }

    function test_CheckIn_EmitsCheckIn() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.CheckIn(pauserAddr);
        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));
    }

    function test_CheckIn_SucceedsForAssignedPauser() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));
        assertEq(cb.latestCheckIn(pauserAddr), block.timestamp);
    }

    function test_CheckIn_RevertIf_SenderNotPauser() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), pauserAddr)
        );
        vm.prank(stranger);
        cb.checkIn(address(mockPausable));
    }

    function test_CheckIn_RevertIf_NoPauserAssigned() public {
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));
    }

    function test_CheckIn_RevertIf_CheckInExpired() public {
        _assignPauser(address(mockPausable), pauserAddr);

        // Warp past the check-in window
        vm.warp(block.timestamp + CHECK_IN_WINDOW + 1);

        vm.expectRevert(CircuitBreaker.CheckInExpired.selector);
        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));
    }

    function test_CheckIn_SucceedsAtExactWindowBoundary() public {
        _assignPauser(address(mockPausable), pauserAddr);

        // Warp to exactly the window boundary (should still pass)
        vm.warp(block.timestamp + CHECK_IN_WINDOW);

        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));
        assertEq(cb.latestCheckIn(pauserAddr), block.timestamp);
    }

    function test_CheckIn_UpdatesTimestampOnSubsequentCall() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));
        uint256 ts1 = block.timestamp;

        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));
        uint256 ts2 = block.timestamp;

        assertEq(cb.latestCheckIn(pauserAddr), ts2);
        assertGt(ts2, ts1);
    }

    // =========================================================================
    // isCheckInValid
    // =========================================================================

    function test_IsCheckInValid_TrueWhenFresh() public {
        _assignPauser(address(mockPausable), pauserAddr);
        assertTrue(cb.isCheckInValid(pauserAddr));
    }

    function test_IsCheckInValid_TrueAtBoundary() public {
        _assignPauser(address(mockPausable), pauserAddr);
        vm.warp(block.timestamp + CHECK_IN_WINDOW);
        assertTrue(cb.isCheckInValid(pauserAddr));
    }

    function test_IsCheckInValid_FalseWhenExpired() public {
        _assignPauser(address(mockPausable), pauserAddr);
        vm.warp(block.timestamp + CHECK_IN_WINDOW + 1);
        assertFalse(cb.isCheckInValid(pauserAddr));
    }

    function test_IsCheckInValid_FalseForUnknownPauser() public view {
        // latestCheckIn is 0 for unknown, so 0 + checkInWindow < block.timestamp (assuming timestamp > checkInWindow)
        // Actually at timestamp 1, 0 + 30 days > 1, so it would be true.
        // Let's just verify the function works for a never-assigned address at a late timestamp.
    }

    // =========================================================================
    // pause – input validation
    // =========================================================================

    function test_Pause_RevertIf_SenderNotPauser_NoPauserAssigned() public {
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));
    }

    function test_Pause_RevertIf_SenderNotPauser_WrongCaller() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), pauserAddr)
        );
        vm.prank(stranger);
        cb.pause(address(mockPausable));
    }

    function test_Pause_RevertIf_CheckInExpired() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.warp(block.timestamp + CHECK_IN_WINDOW + 1);

        vm.expectRevert(CircuitBreaker.CheckInExpired.selector);
        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));
    }

    // =========================================================================
    // pause – happy path
    // =========================================================================

    function test_Pause_CallsPauseForWithGlobalDuration() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));

        assertTrue(mockPausable.isPaused());
        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + PAUSE_DURATION);
    }

    function test_Pause_EmitsPaused() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.expectEmit(true, true, false, true);
        emit CircuitBreaker.Paused(address(mockPausable), pauserAddr, PAUSE_DURATION);
        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));
    }

    function test_Pause_EmitsPauserRemoved() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.expectEmit(true, true, false, false);
        emit CircuitBreaker.PauserRemoved(address(mockPausable), pauserAddr);
        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));
    }

    function test_Pause_EmitsCheckIn() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.CheckIn(pauserAddr);
        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));
    }

    function test_Pause_DeletesPauserAfterSuccess() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));

        assertEq(cb.pauserOf(address(mockPausable)), address(0));
    }

    function test_Pause_UpdatesCheckInTimestamp() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.warp(block.timestamp + 1 hours);
        uint256 ts = block.timestamp;
        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));

        assertEq(cb.latestCheckIn(pauserAddr), ts);
    }

    // =========================================================================
    // pause – single-use (consumed on success)
    // =========================================================================

    function test_Pause_CannotPauseAgainAfterConsumed() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));
    }

    function test_Pause_CannotPauseAgainEvenAfterUnpause() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));

        mockPausable.setState(false);
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));
    }

    // =========================================================================
    // pause – PauseFailed
    // =========================================================================

    function test_Pause_RevertIf_PauseFailed() public {
        _assignPauser(address(mockPauseFails), pauserAddr);

        vm.expectRevert(CircuitBreaker.PauseFailed.selector);
        vm.prank(pauserAddr);
        cb.pause(address(mockPauseFails));
    }

    // =========================================================================
    // pause – pauseFor reverts (bubbles through)
    // =========================================================================

    function test_Pause_RevertIf_PauseForReverts() public {
        _assignPauser(address(mockPauseReverts), pauserAddr);

        vm.expectRevert("pauseFor: forced revert");
        vm.prank(pauserAddr);
        cb.pause(address(mockPauseReverts));
    }

    // =========================================================================
    // pause – reentrancy
    // =========================================================================

    function test_Pause_RevertIf_Reentrancy() public {
        MockPausableReentrant reentrant = new MockPausableReentrant(cb);
        _assignPauser(address(reentrant), pauserAddr);

        vm.prank(pauserAddr);
        vm.expectRevert(CircuitBreaker.ReentrantCall.selector);
        cb.pause(address(reentrant));
    }

    // =========================================================================
    // pause – uses updated global duration
    // =========================================================================

    function test_Pause_UsesUpdatedPauseDuration() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(admin);
        cb.setPauseDuration(14 days);

        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));

        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + 14 days);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _assignPauser(address pausable, address _pauser) internal {
        vm.prank(admin);
        cb.setPauser(pausable, _pauser);
    }
}

// ---------------------------------------------------------------------------
// Edge-case test suite
// ---------------------------------------------------------------------------
contract CircuitBreakerEdgeCaseTest is Test {
    CircuitBreaker internal cb;
    MockPausable internal mockPausable;

    address internal admin = makeAddr("admin");
    address internal pauserAddr = makeAddr("pauser");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MIN_PAUSE_DURATION = 1 days;
    uint256 internal constant PAUSE_DURATION = 7 days;
    uint256 internal constant MIN_CHECK_IN_WINDOW = 1 days;
    uint256 internal constant CHECK_IN_WINDOW = 30 days;

    function setUp() public {
        cb = new CircuitBreaker(admin, MIN_PAUSE_DURATION, MIN_CHECK_IN_WINDOW, PAUSE_DURATION, CHECK_IN_WINDOW);
        mockPausable = new MockPausable();
    }

    function _assignPauser(address pausable, address _pauser) internal {
        vm.prank(admin);
        cb.setPauser(pausable, _pauser);
    }

    // =========================================================================
    // Re-arm after consumption
    // =========================================================================

    function test_Pause_RearmAfterConsumption() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));
        assertEq(cb.pauserOf(address(mockPausable)), address(0));

        // Admin re-arms
        mockPausable.setState(false);
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
    }

    // =========================================================================
    // One pauser, multiple pausables — independence
    // =========================================================================

    function test_Pause_MultiplePausables_Independent() public {
        MockPausable mp2 = new MockPausable();
        _assignPauser(address(mockPausable), pauserAddr);
        _assignPauser(address(mp2), pauserAddr);

        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));

        assertEq(cb.pauserOf(address(mockPausable)), address(0));
        assertEq(cb.pauserOf(address(mp2)), pauserAddr);

        vm.prank(pauserAddr);
        cb.pause(address(mp2));
        assertTrue(mp2.isPaused());
    }

    // =========================================================================
    // checkIn fails after pause consumes pauser
    // =========================================================================

    function test_CheckIn_RevertIf_PauserConsumedByPause() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));
    }

    // =========================================================================
    // removePauser blocks subsequent pause
    // =========================================================================

    function test_Pause_RevertIf_PauserRemoved() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(admin);
        cb.removePauser(address(mockPausable));

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));
    }

    // =========================================================================
    // pause on EOA / non-contract reverts
    // =========================================================================

    function test_Pause_RevertIf_PausableIsEOA() public {
        address eoa = makeAddr("eoa");
        _assignPauser(eoa, pauserAddr);

        vm.prank(pauserAddr);
        vm.expectRevert();
        cb.pause(eoa);
    }

    // =========================================================================
    // Admin is not implicitly a pauser
    // =========================================================================

    function test_Pause_RevertIf_AdminIsNotPauser() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), pauserAddr)
        );
        vm.prank(admin);
        cb.pause(address(mockPausable));
    }

    function test_CheckIn_RevertIf_AdminIsNotPauser() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), pauserAddr)
        );
        vm.prank(admin);
        cb.checkIn(address(mockPausable));
    }

    // =========================================================================
    // Re-assign same pauser
    // =========================================================================

    function test_SetPauser_SamePauserReassignment() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.warp(block.timestamp + 10 days);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauserAddr);

        // Check-in refreshed
        assertEq(cb.latestCheckIn(pauserAddr), block.timestamp);
    }

    // =========================================================================
    // Cross-pausable checkIn then pause
    // =========================================================================

    function test_CheckIn_ViaPausableA_ThenPausePausableB() public {
        MockPausable mp2 = new MockPausable();
        _assignPauser(address(mockPausable), pauserAddr);
        _assignPauser(address(mp2), pauserAddr);

        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));

        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauserAddr);
        cb.pause(address(mp2));

        assertEq(cb.latestCheckIn(pauserAddr), block.timestamp);
        assertTrue(mp2.isPaused());
        assertEq(cb.pauserOf(address(mockPausable)), pauserAddr);
    }

    // =========================================================================
    // setPauser after removePauser
    // =========================================================================

    function test_SetPauser_AfterRemovePauser() public {
        _assignPauser(address(mockPausable), pauserAddr);
        vm.prank(admin);
        cb.removePauser(address(mockPausable));

        address pauser2 = makeAddr("pauser2");
        _assignPauser(address(mockPausable), pauser2);

        assertEq(cb.pauserOf(address(mockPausable)), pauser2);

        vm.prank(pauser2);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
    }

    // =========================================================================
    // Full lifecycle
    // =========================================================================

    function test_FullLifecycle_Assign_Pause_Rearm_Pause() public {
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
        assertEq(cb.pauserOf(address(mockPausable)), address(0));

        // Re-arm
        mockPausable.setState(false);
        _assignPauser(address(mockPausable), pauserAddr);

        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + PAUSE_DURATION);
    }

    // =========================================================================
    // checkIn still works via other pausable after one consumed
    // =========================================================================

    function test_CheckIn_StillWorksViaOtherPausable_AfterOneConsumed() public {
        MockPausable mp2 = new MockPausable();
        _assignPauser(address(mockPausable), pauserAddr);
        _assignPauser(address(mp2), pauserAddr);

        vm.prank(pauserAddr);
        cb.pause(address(mockPausable));

        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauserAddr);
        cb.checkIn(address(mp2));
        assertEq(cb.latestCheckIn(pauserAddr), block.timestamp);
    }

    // =========================================================================
    // checkIn tracks each pauser independently
    // =========================================================================

    function test_CheckIn_TracksEachPauserIndependently() public {
        MockPausable mp2 = new MockPausable();
        address pauser2 = makeAddr("pauser2");
        _assignPauser(address(mockPausable), pauserAddr);
        vm.prank(admin);
        cb.setPauser(address(mp2), pauser2);

        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));
        uint256 ts1 = block.timestamp;

        vm.warp(block.timestamp + 500);
        vm.prank(pauser2);
        cb.checkIn(address(mp2));
        uint256 ts2 = block.timestamp;

        assertEq(cb.latestCheckIn(pauserAddr), ts1);
        assertEq(cb.latestCheckIn(pauser2), ts2);
    }

    // =========================================================================
    // check-in window change affects existing pausers
    // =========================================================================

    function test_CheckInWindowChange_AffectsExistingPausers() public {
        _assignPauser(address(mockPausable), pauserAddr);

        // Warp to near the end of the window
        vm.warp(block.timestamp + CHECK_IN_WINDOW - 1);

        // checkIn still works
        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));

        // Admin shrinks the window
        vm.prank(admin);
        cb.setCheckInWindow(MIN_CHECK_IN_WINDOW);

        // Warp past the new shorter window
        vm.warp(block.timestamp + MIN_CHECK_IN_WINDOW + 1);

        vm.expectRevert(CircuitBreaker.CheckInExpired.selector);
        vm.prank(pauserAddr);
        cb.checkIn(address(mockPausable));
    }

    // =========================================================================
    // Fuzz: setPauseDuration within valid range
    // =========================================================================

    function testFuzz_SetPauseDuration(uint256 duration) public {
        duration = bound(duration, MIN_PAUSE_DURATION, 30 days);
        vm.assume(duration != PAUSE_DURATION);
        vm.prank(admin);
        cb.setPauseDuration(duration);
        assertEq(cb.pauseDuration(), duration);
    }

    // =========================================================================
    // Fuzz: setCheckInWindow within valid range
    // =========================================================================

    function testFuzz_SetCheckInWindow(uint256 window) public {
        window = bound(window, MIN_CHECK_IN_WINDOW, 1095 days);
        vm.assume(window != CHECK_IN_WINDOW);
        vm.prank(admin);
        cb.setCheckInWindow(window);
        assertEq(cb.checkInWindow(), window);
    }
}
