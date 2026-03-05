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

    function getResumeSinceTimestamp() external view returns (uint256) {
        return _resumeSince;
    }

    function pauseFor(uint256 duration) external {
        _paused = true;
        _resumeSince = block.timestamp + duration;
    }

    // Test helper: set arbitrary state without going through pauseFor
    function setState(bool paused, uint256 resumeSince) external {
        _paused = paused;
        _resumeSince = resumeSince;
    }
}

// ---------------------------------------------------------------------------
// Mock: triggers PauseFailed.
// isPaused() returns true before pauseFor is called so getResumeSinceTimestamp()
// is reached. getResumeSinceTimestamp() returns 0 so the AlreadyPaused condition
// is false → else branch executes. pauseFor() flips the flag so the post-call
// isPaused() check returns false → PauseFailed.
// ---------------------------------------------------------------------------
contract MockPausablePauseFails is IPausable {
    bool private _called;

    function isPaused() external view returns (bool) {
        return !_called;
    }

    function getResumeSinceTimestamp() external pure returns (uint256) {
        return 0;
    }

    function pauseFor(uint256) external {
        _called = true;
    }
}

// ---------------------------------------------------------------------------
// Mock: pauseFor reverts → call site bubbles up the revert.
// isPaused() returns true so getResumeSinceTimestamp() is reached.
// getResumeSinceTimestamp() returns 0 → AlreadyPaused condition false →
// else branch executes → pauseFor reverts.
// ---------------------------------------------------------------------------
contract MockPausableReverting is IPausable {
    function isPaused() external pure returns (bool) {
        return true;
    }

    function getResumeSinceTimestamp() external pure returns (uint256) {
        return 0;
    }

    function pauseFor(uint256) external pure {
        revert("pauseFor: forced revert");
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

    uint256 internal constant PAUSE_DURATION = 1 days;

    function setUp() public {
        cb = new CircuitBreaker(admin);
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

    function test_Constructor_EmitsAdminSet() public {
        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.AdminSet(admin);
        new CircuitBreaker(admin);
    }

    function test_Constructor_RevertIf_ZeroAdmin() public {
        vm.expectRevert(CircuitBreaker.ZeroAdmin.selector);
        new CircuitBreaker(address(0));
    }

    // =========================================================================
    // setPauser
    // =========================================================================

    function test_SetPauser_SetsPauser() public {
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
        assertEq(cb.pausers(address(mockPausable)), pauser);
    }

    function test_SetPauser_SetsPauseDuration() public {
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
        assertEq(cb.pauseDurations(address(mockPausable)), PAUSE_DURATION);
    }

    function test_SetPauser_EmitsPauserSet() public {
        vm.expectEmit(true, true, false, true);
        emit CircuitBreaker.PauserSet(address(mockPausable), pauser, PAUSE_DURATION);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
    }

    function test_SetPauser_OverridesPreviousPauser() public {
        address pauser2 = makeAddr("pauser2");
        uint256 newDuration = 7 days;
        vm.startPrank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
        cb.setPauser(address(mockPausable), pauser2, newDuration);
        vm.stopPrank();
        assertEq(cb.pausers(address(mockPausable)), pauser2);
        assertEq(cb.pauseDurations(address(mockPausable)), newDuration);
    }

    function test_SetPauser_RemovesPauser_WhenZeroAddress() public {
        vm.startPrank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
        cb.setPauser(address(mockPausable), address(0), PAUSE_DURATION);
        vm.stopPrank();
        assertEq(cb.pausers(address(mockPausable)), address(0));
    }

    function test_SetPauser_RevertIf_SenderNotAdmin() public {
        vm.expectRevert(CircuitBreaker.SenderNotAdmin.selector);
        vm.prank(stranger);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
    }

    function test_SetPauser_RevertIf_ZeroPausable() public {
        vm.expectRevert(CircuitBreaker.ZeroPausable.selector);
        vm.prank(admin);
        cb.setPauser(address(0), pauser, PAUSE_DURATION);
    }

    function test_SetPauser_RevertIf_ZeroPauseDuration() public {
        vm.expectRevert(CircuitBreaker.ZeroPauseDuration.selector);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, 0);
    }

    // =========================================================================
    // pause – input validation
    // =========================================================================

    function test_Pause_RevertIf_EmptyList() public {
        vm.expectRevert(CircuitBreaker.EmptyList.selector);
        vm.prank(pauser);
        cb.pause(new address[](0));
    }

    function test_Pause_RevertIf_SenderNotPauser_NoPauserAssigned() public {
        // pausers[pausable] == address(0), which never equals a real caller
        address[] memory list = _list(address(mockPausable));
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauser);
        cb.pause(list);
    }

    function test_Pause_RevertIf_SenderNotPauser_WrongCaller() public {
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);

        address[] memory list = _list(address(mockPausable));
        // pauser is the assigned address; stranger is the wrong caller
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), pauser)
        );
        vm.prank(stranger);
        cb.pause(list);
    }

    // =========================================================================
    // pause – happy path (not already paused)
    // =========================================================================

    function test_Pause_EmitsPaused() public {
        _assignPauser(address(mockPausable), pauser);
        address[] memory list = _list(address(mockPausable));

        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.Paused(address(mockPausable));
        vm.prank(pauser);
        cb.pause(list);
    }

    function test_Pause_CallsPauseFor_WithConfiguredDuration() public {
        _assignPauser(address(mockPausable), pauser);
        address[] memory list = _list(address(mockPausable));

        vm.prank(pauser);
        cb.pause(list);

        assertTrue(mockPausable.isPaused());
        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + PAUSE_DURATION);
    }

    function test_Pause_DeletesPauser_AfterSuccess() public {
        _assignPauser(address(mockPausable), pauser);
        address[] memory list = _list(address(mockPausable));

        vm.prank(pauser);
        cb.pause(list);

        assertEq(cb.pausers(address(mockPausable)), address(0));
    }

    function test_Pause_UpdatesHeartbeat_AfterSuccess() public {
        _assignPauser(address(mockPausable), pauser);
        address[] memory list = _list(address(mockPausable));

        uint256 ts = block.timestamp;
        vm.prank(pauser);
        cb.pause(list);

        assertEq(cb.latestHeartbeats(pauser), ts);
    }

    function test_Pause_EmitsHeartbeat_AfterSuccess() public {
        _assignPauser(address(mockPausable), pauser);
        address[] memory list = _list(address(mockPausable));

        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.Heartbeat(pauser);
        vm.prank(pauser);
        cb.pause(list);
    }

    // =========================================================================
    // pause – single-use pauser (pauser slot consumed on success)
    // =========================================================================

    function test_Pause_CannotPauseAgain_AfterPauserConsumed() public {
        _assignPauser(address(mockPausable), pauser);
        address[] memory list = _list(address(mockPausable));

        vm.prank(pauser);
        cb.pause(list);

        // Pauser mapping deleted; second call must revert
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauser);
        cb.pause(list);
    }

    // =========================================================================
    // pause – pause duration persists after pause
    // =========================================================================

    function test_Pause_DurationPersistsAfterPause() public {
        _assignPauser(address(mockPausable), pauser);
        address[] memory list = _list(address(mockPausable));

        vm.prank(pauser);
        cb.pause(list);

        // Pauser is consumed but duration remains
        assertEq(cb.pausers(address(mockPausable)), address(0));
        assertEq(cb.pauseDurations(address(mockPausable)), PAUSE_DURATION);
    }

    // =========================================================================
    // pause – per-pausable duration
    // =========================================================================

    function test_Pause_UsesPausableSpecificDuration() public {
        uint256 customDuration = 7 days;
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, customDuration);

        address[] memory list = _list(address(mockPausable));
        vm.prank(pauser);
        cb.pause(list);

        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + customDuration);
    }

    // =========================================================================
    // pause – AlreadyPaused branch
    // =========================================================================

    function test_Pause_EmitsAlreadyPaused_WhenPausedSufficiently() public {
        // resumeSince == block.timestamp + pauseDuration → exact threshold → AlreadyPaused
        mockPausable.setState(true, block.timestamp + PAUSE_DURATION);
        _assignPauser(address(mockPausable), pauser);
        address[] memory list = _list(address(mockPausable));

        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.AlreadyPaused(address(mockPausable));
        vm.prank(pauser);
        cb.pause(list);
    }

    function test_Pause_AlreadyPaused_DoesNotDeletePauser() public {
        mockPausable.setState(true, block.timestamp + PAUSE_DURATION);
        _assignPauser(address(mockPausable), pauser);
        address[] memory list = _list(address(mockPausable));

        vm.prank(pauser);
        cb.pause(list);

        // Pauser must survive because the AlreadyPaused branch skips the delete
        assertEq(cb.pausers(address(mockPausable)), pauser);
    }

    function test_Pause_AlreadyPaused_StillCallsHeartbeat() public {
        mockPausable.setState(true, block.timestamp + PAUSE_DURATION);
        _assignPauser(address(mockPausable), pauser);
        address[] memory list = _list(address(mockPausable));

        uint256 ts = block.timestamp;
        vm.prank(pauser);
        cb.pause(list);

        assertEq(cb.latestHeartbeats(pauser), ts);
    }

    function test_Pause_AlreadyPaused_ExactBoundary() public {
        // resumeSince = block.timestamp + pauseDuration satisfies >= → AlreadyPaused
        mockPausable.setState(true, block.timestamp + PAUSE_DURATION);
        _assignPauser(address(mockPausable), pauser);

        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.AlreadyPaused(address(mockPausable));
        vm.prank(pauser);
        cb.pause(_list(address(mockPausable)));
    }

    // =========================================================================
    // pause – else branch: paused but duration not sufficient
    // =========================================================================

    function test_Pause_RepausesWhenResumeSinceJustBelowThreshold() public {
        // resumeSince = block.timestamp + pauseDuration - 1 → condition false → re-pause
        mockPausable.setState(true, block.timestamp + PAUSE_DURATION - 1);
        _assignPauser(address(mockPausable), pauser);
        address[] memory list = _list(address(mockPausable));

        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.Paused(address(mockPausable));
        vm.prank(pauser);
        cb.pause(list);
    }

    function test_Pause_RepausesWhenResumeSinceInPast() public {
        mockPausable.setState(true, block.timestamp - 1);
        _assignPauser(address(mockPausable), pauser);
        address[] memory list = _list(address(mockPausable));

        vm.prank(pauser);
        cb.pause(list);

        assertTrue(mockPausable.isPaused());
        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + PAUSE_DURATION);
    }

    // =========================================================================
    // pause – PauseFailed
    // =========================================================================

    function test_Pause_RevertIf_PauseFailed() public {
        _assignPauser(address(mockPauseFails), pauser);
        address[] memory list = _list(address(mockPauseFails));

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.PauseFailed.selector, address(mockPauseFails))
        );
        vm.prank(pauser);
        cb.pause(list);
    }

    // =========================================================================
    // pause – pauseFor reverts (bubbles through)
    // =========================================================================

    function test_Pause_RevertIf_PauseForReverts() public {
        _assignPauser(address(mockPauseReverts), pauser);
        address[] memory list = _list(address(mockPauseReverts));

        vm.expectRevert("pauseFor: forced revert");
        vm.prank(pauser);
        cb.pause(list);
    }

    // =========================================================================
    // pause – batch with multiple pausables
    // =========================================================================

    function test_Pause_MultiPausable_AllPaused() public {
        MockPausable mp2 = new MockPausable();
        vm.startPrank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
        cb.setPauser(address(mp2), pauser, PAUSE_DURATION);
        vm.stopPrank();

        address[] memory list = new address[](2);
        list[0] = address(mockPausable);
        list[1] = address(mp2);

        vm.prank(pauser);
        cb.pause(list);

        assertTrue(mockPausable.isPaused());
        assertTrue(mp2.isPaused());
        assertEq(cb.pausers(address(mockPausable)), address(0));
        assertEq(cb.pausers(address(mp2)), address(0));
    }

    function test_Pause_MixedBatch_PausedAndAlreadyPaused() public {
        MockPausable mp2 = new MockPausable();
        mp2.setState(true, block.timestamp + PAUSE_DURATION); // already sufficiently paused

        vm.startPrank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
        cb.setPauser(address(mp2), pauser, PAUSE_DURATION);
        vm.stopPrank();

        address[] memory list = new address[](2);
        list[0] = address(mockPausable); // will be paused
        list[1] = address(mp2);          // will emit AlreadyPaused

        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.Paused(address(mockPausable));
        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.AlreadyPaused(address(mp2));
        vm.prank(pauser);
        cb.pause(list);

        assertTrue(mockPausable.isPaused());
        assertEq(cb.pausers(address(mockPausable)), address(0)); // consumed
        assertEq(cb.pausers(address(mp2)), pauser);              // not consumed
    }

    // =========================================================================
    // pause – atomicity: if any item fails the whole tx reverts
    // =========================================================================

    function test_Pause_Batch_Atomic_RevertsOnSecondItem() public {
        vm.startPrank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
        cb.setPauser(address(mockPauseFails), pauser, PAUSE_DURATION);
        vm.stopPrank();

        address[] memory list = new address[](2);
        list[0] = address(mockPausable);   // would succeed
        list[1] = address(mockPauseFails); // triggers PauseFailed

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.PauseFailed.selector, address(mockPauseFails))
        );
        vm.prank(pauser);
        cb.pause(list);

        // Tx reverted → first item's effects are rolled back
        assertFalse(mockPausable.isPaused());
        assertEq(cb.pausers(address(mockPausable)), pauser);
    }

    function test_Pause_Batch_Atomic_RevertsOnFirstItem_SenderNotPauser() public {
        // No pauser assigned for mockPausable; second item has pauser set
        MockPausable mp2 = new MockPausable();
        vm.prank(admin);
        cb.setPauser(address(mp2), pauser, PAUSE_DURATION);

        address[] memory list = new address[](2);
        list[0] = address(mockPausable); // fails immediately
        list[1] = address(mp2);

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauser);
        cb.pause(list);

        // mp2 must remain untouched
        assertFalse(mp2.isPaused());
        assertEq(cb.pausers(address(mp2)), pauser);
    }

    // =========================================================================
    // pause – duplicate entries in the list
    // =========================================================================

    function test_Pause_DuplicatePausable_SecondOccurrenceReverts() public {
        // First iteration pauses and deletes pauser.
        // Second iteration finds pauser == address(0) → SenderNotPauser → whole tx reverts.
        _assignPauser(address(mockPausable), pauser);

        address[] memory list = new address[](2);
        list[0] = address(mockPausable);
        list[1] = address(mockPausable);

        // After first iteration the pauser slot is deleted → address(0) on second iteration
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauser);
        cb.pause(list);

        // Tx reverted → pauser still assigned, pausable still unpaused
        assertFalse(mockPausable.isPaused());
        assertEq(cb.pausers(address(mockPausable)), pauser);
    }

    function test_Pause_DuplicatePausable_AlreadyPaused_BothEmitAlreadyPaused() public {
        // When already paused the pauser is NOT consumed; both iterations emit AlreadyPaused.
        mockPausable.setState(true, block.timestamp + PAUSE_DURATION);
        _assignPauser(address(mockPausable), pauser);

        address[] memory list = new address[](2);
        list[0] = address(mockPausable);
        list[1] = address(mockPausable);

        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.AlreadyPaused(address(mockPausable));
        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.AlreadyPaused(address(mockPausable));
        vm.prank(pauser);
        cb.pause(list);
    }

    // =========================================================================
    // pause – SenderNotPauser at non-first index (loop iteration coverage)
    // =========================================================================

    function test_Pause_RevertIf_SenderNotPauser_AtSecondIndex() public {
        MockPausable mp2 = new MockPausable();
        _assignPauser(address(mockPausable), pauser);
        // No pauser for mp2

        address[] memory list = new address[](2);
        list[0] = address(mockPausable);
        list[1] = address(mp2);

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mp2), address(0))
        );
        vm.prank(pauser);
        cb.pause(list);

        // Atomicity: first item rolled back
        assertFalse(mockPausable.isPaused());
        assertEq(cb.pausers(address(mockPausable)), pauser);
    }

    // =========================================================================
    // heartbeat – standalone
    // =========================================================================

    function test_Heartbeat_SetsLatestHeartbeat() public {
        uint256 ts = block.timestamp;
        vm.prank(pauser);
        cb.heartbeat();
        assertEq(cb.latestHeartbeats(pauser), ts);
    }

    function test_Heartbeat_EmitsHeartbeat() public {
        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.Heartbeat(pauser);
        vm.prank(pauser);
        cb.heartbeat();
    }

    function test_Heartbeat_UpdatesTimestamp_OnSubsequentCall() public {
        vm.prank(pauser);
        cb.heartbeat();

        vm.warp(block.timestamp + 1 hours);
        uint256 laterTs = block.timestamp;
        vm.prank(pauser);
        cb.heartbeat();

        assertEq(cb.latestHeartbeats(pauser), laterTs);
    }

    function test_Heartbeat_CallableByAnyAddress() public {
        uint256 ts = block.timestamp;
        vm.prank(stranger);
        cb.heartbeat();
        assertEq(cb.latestHeartbeats(stranger), ts);
    }

    function test_Heartbeat_TracksEachCallerIndependently() public {
        address pauser2 = makeAddr("pauser2");

        vm.prank(pauser);
        cb.heartbeat();
        uint256 ts1 = block.timestamp;

        vm.warp(block.timestamp + 500);
        vm.prank(pauser2);
        cb.heartbeat();
        uint256 ts2 = block.timestamp;

        assertEq(cb.latestHeartbeats(pauser), ts1);
        assertEq(cb.latestHeartbeats(pauser2), ts2);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _assignPauser(address pausable, address _pauser) internal {
        vm.prank(admin);
        cb.setPauser(pausable, _pauser, PAUSE_DURATION);
    }

    function _list(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }
}
