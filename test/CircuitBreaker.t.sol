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

    // Non-interface helper: verify the duration passed to pauseFor
    function getResumeSinceTimestamp() external view returns (uint256) {
        return _resumeSince;
    }

    // Test helper: set paused state directly
    function setState(bool paused) external {
        _paused = paused;
    }
}

// ---------------------------------------------------------------------------
// Mock: triggers PauseFailed.
// isPaused() always returns false → else branch executes.
// pauseFor() does nothing so the post-call isPaused() check returns false → PauseFailed.
// ---------------------------------------------------------------------------
contract MockPausablePauseFails is IPausable {
    function isPaused() external pure returns (bool) {
        return false;
    }

    function pauseFor(uint256) external {
        // does nothing — isPaused stays false
    }
}

// ---------------------------------------------------------------------------
// Mock: pauseFor reverts → call site bubbles up the revert.
// isPaused() returns false → else branch executes → pauseFor reverts.
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
        assertEq(_pauserOf(address(mockPausable)), pauser);
    }

    function test_SetPauser_SetsPauseDuration() public {
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
        assertEq(_durationOf(address(mockPausable)), PAUSE_DURATION);
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
        assertEq(_pauserOf(address(mockPausable)), pauser2);
        assertEq(_durationOf(address(mockPausable)), newDuration);
    }

    function test_SetPauser_RevertIf_ZeroPauser() public {
        vm.expectRevert(CircuitBreaker.ZeroPauser.selector);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), address(0), PAUSE_DURATION);
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

    function test_SetPauser_RevertIf_DurationTooLarge() public {
        vm.expectRevert(CircuitBreaker.DurationTooLarge.selector);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, uint256(type(uint64).max) + 1);
    }

    // =========================================================================
    // removePauser
    // =========================================================================

    function test_RemovePauser_ClearsPauser() public {
        vm.startPrank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
        cb.removePauser(address(mockPausable));
        vm.stopPrank();
        assertEq(_pauserOf(address(mockPausable)), address(0));
    }

    function test_RemovePauser_ClearsPauseDuration() public {
        vm.startPrank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
        cb.removePauser(address(mockPausable));
        vm.stopPrank();
        assertEq(_durationOf(address(mockPausable)), 0);
    }

    function test_RemovePauser_EmitsPauserRemoved() public {
        vm.startPrank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);
        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.PauserRemoved(address(mockPausable));
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

    // =========================================================================
    // pause – input validation
    // =========================================================================

    function test_Pause_RevertIf_SenderNotPauser_NoPauserAssigned() public {
        // pausers[pausable] == address(0), which never equals a real caller
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    function test_Pause_RevertIf_SenderNotPauser_WrongCaller() public {
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, PAUSE_DURATION);

        // pauser is the assigned address; stranger is the wrong caller
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), pauser)
        );
        vm.prank(stranger);
        cb.pause(address(mockPausable));
    }

    // =========================================================================
    // pause – happy path (not already paused)
    // =========================================================================

    function test_Pause_EmitsPaused() public {
        _assignPauser(address(mockPausable), pauser);

        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.Paused(address(mockPausable));
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    function test_Pause_CallsPauseFor_WithConfiguredDuration() public {
        _assignPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        assertTrue(mockPausable.isPaused());
        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + PAUSE_DURATION);
    }

    function test_Pause_DeletesPauser_AfterSuccess() public {
        _assignPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        assertEq(_pauserOf(address(mockPausable)), address(0));
    }

    function test_Pause_UpdatesHeartbeat_AfterSuccess() public {
        _assignPauser(address(mockPausable), pauser);

        uint256 ts = block.timestamp;
        vm.prank(pauser);
        cb.pause(address(mockPausable));

        assertEq(cb.latestHeartbeats(pauser), ts);
    }

    function test_Pause_EmitsHeartbeat_AfterSuccess() public {
        _assignPauser(address(mockPausable), pauser);

        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.Heartbeat(pauser);
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    // =========================================================================
    // pause – single-use pauser (pauser slot consumed on success)
    // =========================================================================

    function test_Pause_CannotPauseAgain_AfterPauserConsumed() public {
        _assignPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        // Pauser config was deleted; auth check fires before isPaused, so calling pause
        // reverts whether the contract is still paused or not.
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauser);
        cb.pause(address(mockPausable));

        // Same after pause expiry.
        mockPausable.setState(false);
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    // =========================================================================
    // pause – pause duration persists after pause
    // =========================================================================

    function test_Pause_DeletesBothFieldsAfterSuccess() public {
        _assignPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        assertEq(_pauserOf(address(mockPausable)), address(0));
        assertEq(_durationOf(address(mockPausable)), 0);
    }

    // =========================================================================
    // pause – per-pausable duration
    // =========================================================================

    function test_Pause_UsesPausableSpecificDuration() public {
        uint256 customDuration = 7 days;
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, customDuration);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + customDuration);
    }

    // =========================================================================
    // pause – AlreadyPaused branch
    // =========================================================================

    function test_Pause_EmitsAlreadyPaused_WhenPaused() public {
        mockPausable.setState(true);
        _assignPauser(address(mockPausable), pauser);

        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.AlreadyPaused(address(mockPausable));
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    function test_Pause_AlreadyPaused_DoesNotDeletePauser() public {
        mockPausable.setState(true);
        _assignPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        // Pauser must survive because the AlreadyPaused branch skips the delete
        assertEq(_pauserOf(address(mockPausable)), pauser);
    }

    function test_Pause_AlreadyPaused_StillCallsHeartbeat() public {
        mockPausable.setState(true);
        _assignPauser(address(mockPausable), pauser);

        uint256 ts = block.timestamp;
        vm.prank(pauser);
        cb.pause(address(mockPausable));

        assertEq(cb.latestHeartbeats(pauser), ts);
    }

    // =========================================================================
    // pause – PauseFailed
    // =========================================================================

    function test_Pause_RevertIf_PauseFailed() public {
        _assignPauser(address(mockPauseFails), pauser);

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.PauseFailed.selector, address(mockPauseFails))
        );
        vm.prank(pauser);
        cb.pause(address(mockPauseFails));
    }

    // =========================================================================
    // pause – pauseFor reverts (bubbles through)
    // =========================================================================

    function test_Pause_RevertIf_PauseForReverts() public {
        _assignPauser(address(mockPauseReverts), pauser);

        vm.expectRevert("pauseFor: forced revert");
        vm.prank(pauser);
        cb.pause(address(mockPauseReverts));
    }

    // =========================================================================
    // heartbeat – standalone
    // =========================================================================

    function test_Heartbeat_SetsLatestHeartbeat() public {
        _assignPauser(address(mockPausable), pauser);
        uint256 ts = block.timestamp;
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));
        assertEq(cb.latestHeartbeats(pauser), ts);
    }

    function test_Heartbeat_EmitsHeartbeat() public {
        _assignPauser(address(mockPausable), pauser);
        vm.expectEmit(true, false, false, false);
        emit CircuitBreaker.Heartbeat(pauser);
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));
    }

    function test_Heartbeat_UpdatesTimestamp_OnSubsequentCall() public {
        _assignPauser(address(mockPausable), pauser);
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));

        vm.warp(block.timestamp + 1 hours);
        uint256 laterTs = block.timestamp;
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));

        assertEq(cb.latestHeartbeats(pauser), laterTs);
    }

    function test_Heartbeat_RevertIf_SenderNotPauser() public {
        _assignPauser(address(mockPausable), pauser);
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), pauser)
        );
        vm.prank(stranger);
        cb.heartbeat(address(mockPausable));
    }

    function test_Heartbeat_RevertIf_NoPauserAssigned() public {
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));
    }

    function test_Heartbeat_TracksEachCallerIndependently() public {
        MockPausable mp2 = new MockPausable();
        address pauser2 = makeAddr("pauser2");
        _assignPauser(address(mockPausable), pauser);
        vm.prank(admin);
        cb.setPauser(address(mp2), pauser2, PAUSE_DURATION);

        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));
        uint256 ts1 = block.timestamp;

        vm.warp(block.timestamp + 500);
        vm.prank(pauser2);
        cb.heartbeat(address(mp2));
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

    function _pauserOf(address pausable) internal view returns (address p) {
        (p,) = cb.pauserConfigs(pausable);
    }

    function _durationOf(address pausable) internal view returns (uint64 d) {
        (, d) = cb.pauserConfigs(pausable);
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
            // Attempt reentrant pause — config is already deleted so auth will fail
            _cb.pause(address(this));
        }
    }
}

// ---------------------------------------------------------------------------
// Edge-case test suite
// ---------------------------------------------------------------------------
contract CircuitBreakerEdgeCaseTest is Test {
    CircuitBreaker internal cb;
    MockPausable internal mockPausable;

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant PAUSE_DURATION = 1 days;

    function setUp() public {
        cb = new CircuitBreaker(admin);
        mockPausable = new MockPausable();
    }

    function _assignPauser(address pausable, address _pauser) internal {
        vm.prank(admin);
        cb.setPauser(pausable, _pauser, PAUSE_DURATION);
    }

    function _assignPauser(address pausable, address _pauser, uint256 duration) internal {
        vm.prank(admin);
        cb.setPauser(pausable, _pauser, duration);
    }

    function _pauserOf(address pausable) internal view returns (address p) {
        (p,) = cb.pauserConfigs(pausable);
    }

    function _durationOf(address pausable) internal view returns (uint64 d) {
        (, d) = cb.pauserConfigs(pausable);
    }

    // =========================================================================
    // Re-arm after consumption
    // =========================================================================

    function test_Pause_RearmAfterConsumption() public {
        _assignPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));
        // Config consumed
        assertEq(_pauserOf(address(mockPausable)), address(0));

        // Admin re-arms
        mockPausable.setState(false);
        uint256 newDuration = 7 days;
        _assignPauser(address(mockPausable), pauser, newDuration);

        // Pauser can pause again with new duration
        vm.prank(pauser);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + newDuration);
    }

    // =========================================================================
    // One pauser, multiple pausables — independence
    // =========================================================================

    function test_Pause_MultiplePausables_Independent() public {
        MockPausable mp2 = new MockPausable();
        _assignPauser(address(mockPausable), pauser);
        _assignPauser(address(mp2), pauser);

        // Pause first
        vm.prank(pauser);
        cb.pause(address(mockPausable));

        // First consumed, second still armed
        assertEq(_pauserOf(address(mockPausable)), address(0));
        assertEq(_pauserOf(address(mp2)), pauser);

        // Can still pause second
        vm.prank(pauser);
        cb.pause(address(mp2));
        assertTrue(mp2.isPaused());
    }

    // =========================================================================
    // Heartbeat fails after pause consumes config
    // =========================================================================

    function test_Heartbeat_RevertIf_ConfigConsumedByPause() public {
        _assignPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        // Config deleted — heartbeat via this pausable should revert
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));
    }

    // =========================================================================
    // AlreadyPaused preserves duration
    // =========================================================================

    function test_Pause_AlreadyPaused_PreservesDuration() public {
        mockPausable.setState(true);
        uint256 customDuration = 3 days;
        _assignPauser(address(mockPausable), pauser, customDuration);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        // Duration must survive the no-op branch
        assertEq(_durationOf(address(mockPausable)), uint64(customDuration));
    }

    // =========================================================================
    // removePauser blocks subsequent pause
    // =========================================================================

    function test_Pause_RevertIf_PauserRemoved() public {
        _assignPauser(address(mockPausable), pauser);

        vm.prank(admin);
        cb.removePauser(address(mockPausable));

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), address(0))
        );
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    // =========================================================================
    // removePauser on never-assigned pausable (no-op)
    // =========================================================================

    function test_RemovePauser_RevertIf_NoPauserAssigned() public {
        vm.expectRevert(CircuitBreaker.ZeroPauser.selector);
        vm.prank(admin);
        cb.removePauser(address(mockPausable));
    }

    // =========================================================================
    // pause on EOA / non-contract reverts
    // =========================================================================

    function test_Pause_RevertIf_PausableIsEOA() public {
        address eoa = makeAddr("eoa");
        _assignPauser(eoa, pauser);

        // Calling isPaused() on an EOA will revert (no code)
        vm.prank(pauser);
        vm.expectRevert();
        cb.pause(eoa);
    }

    // =========================================================================
    // Max uint64 duration boundary
    // =========================================================================

    function test_SetPauser_MaxUint64Duration() public {
        uint256 maxDuration = uint256(type(uint64).max);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, maxDuration);
        assertEq(_durationOf(address(mockPausable)), uint64(maxDuration));
    }

    // =========================================================================
    // Admin is not implicitly a pauser
    // =========================================================================

    function test_Pause_RevertIf_AdminIsNotPauser() public {
        _assignPauser(address(mockPausable), pauser);

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), pauser)
        );
        vm.prank(admin);
        cb.pause(address(mockPausable));
    }

    function test_Heartbeat_RevertIf_AdminIsNotPauser() public {
        _assignPauser(address(mockPausable), pauser);

        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(mockPausable), pauser)
        );
        vm.prank(admin);
        cb.heartbeat(address(mockPausable));
    }

    // =========================================================================
    // Re-assign same pauser with different duration
    // =========================================================================

    function test_SetPauser_SamePauserNewDuration() public {
        _assignPauser(address(mockPausable), pauser, 1 days);

        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, 14 days);

        assertEq(_pauserOf(address(mockPausable)), pauser);
        assertEq(_durationOf(address(mockPausable)), uint64(14 days));
    }

    // =========================================================================
    // Cross-pausable heartbeat then pause
    // =========================================================================

    function test_Heartbeat_ViaPausableA_ThenPausePausableB() public {
        MockPausable mp2 = new MockPausable();
        _assignPauser(address(mockPausable), pauser);
        _assignPauser(address(mp2), pauser);

        // Heartbeat via pausable A
        vm.prank(pauser);
        cb.heartbeat(address(mockPausable));
        uint256 ts1 = block.timestamp;
        assertEq(cb.latestHeartbeats(pauser), ts1);

        // Advance time, pause via pausable B
        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauser);
        cb.pause(address(mp2));

        // Heartbeat updated to later timestamp
        assertEq(cb.latestHeartbeats(pauser), block.timestamp);
        assertTrue(mp2.isPaused());

        // Pausable A config still intact
        assertEq(_pauserOf(address(mockPausable)), pauser);
    }

    // =========================================================================
    // setPauser after removePauser
    // =========================================================================

    function test_SetPauser_AfterRemovePauser() public {
        _assignPauser(address(mockPausable), pauser);
        vm.prank(admin);
        cb.removePauser(address(mockPausable));

        // Re-assign
        address pauser2 = makeAddr("pauser2");
        _assignPauser(address(mockPausable), pauser2, 3 days);

        assertEq(_pauserOf(address(mockPausable)), pauser2);
        assertEq(_durationOf(address(mockPausable)), uint64(3 days));

        // New pauser can pause
        vm.prank(pauser2);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
    }

    // =========================================================================
    // Full lifecycle: assign → already-paused no-op → unpause → re-assign → pause
    // =========================================================================

    function test_FullLifecycle_AlreadyPaused_Unpause_Reassign_Pause() public {
        // Already paused externally
        mockPausable.setState(true);
        _assignPauser(address(mockPausable), pauser);

        // Pause is a no-op
        vm.prank(pauser);
        cb.pause(address(mockPausable));
        assertEq(_pauserOf(address(mockPausable)), pauser); // not consumed

        // Contract unpauses itself
        mockPausable.setState(false);

        // Pauser can now actually pause (config survived the no-op)
        vm.prank(pauser);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());

        // Config is now consumed
        assertEq(_pauserOf(address(mockPausable)), address(0));
        assertEq(_durationOf(address(mockPausable)), 0);

        // Re-arm by admin
        mockPausable.setState(false);
        _assignPauser(address(mockPausable), pauser, 2 days);

        vm.prank(pauser);
        cb.pause(address(mockPausable));
        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + 2 days);
    }

    // =========================================================================
    // Reentrancy: pauseFor tries to call pause() again
    // =========================================================================

    function test_Pause_Reentrancy_FromPauseFor() public {
        MockPausableReentrant reentrant = new MockPausableReentrant(cb);
        _assignPauser(address(reentrant), pauser);

        // The reentrant pauseFor will try to call pause() again.
        // Since config is deleted before the external call, the reentrant
        // call will revert with SenderNotPauser. That revert bubbles up.
        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(CircuitBreaker.SenderNotPauser.selector, address(reentrant), address(0))
        );
        cb.pause(address(reentrant));
    }

    // =========================================================================
    // Heartbeat via one of multiple pausables after another is consumed
    // =========================================================================

    function test_Heartbeat_StillWorksViaOtherPausable_AfterOneConsumed() public {
        MockPausable mp2 = new MockPausable();
        _assignPauser(address(mockPausable), pauser);
        _assignPauser(address(mp2), pauser);

        // Consume config for mockPausable
        vm.prank(pauser);
        cb.pause(address(mockPausable));

        // Heartbeat via mp2 still works
        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauser);
        cb.heartbeat(address(mp2));
        assertEq(cb.latestHeartbeats(pauser), block.timestamp);
    }

    // =========================================================================
    // Fuzz: setPauser duration within valid range
    // =========================================================================

    function testFuzz_SetPauser_ValidDuration(uint256 duration) public {
        duration = bound(duration, 1, uint256(type(uint64).max));
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, duration);
        assertEq(_durationOf(address(mockPausable)), uint64(duration));
    }

    // =========================================================================
    // Fuzz: setPauser rejects duration above uint64 max
    // =========================================================================

    function testFuzz_SetPauser_RevertIf_DurationAboveMax(uint256 duration) public {
        duration = bound(duration, uint256(type(uint64).max) + 1, type(uint256).max);
        vm.expectRevert(CircuitBreaker.DurationTooLarge.selector);
        vm.prank(admin);
        cb.setPauser(address(mockPausable), pauser, duration);
    }
}
