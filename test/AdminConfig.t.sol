// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

import {CircuitBreaker} from "../src/CircuitBreaker.sol";
import {TestBase} from "./helpers/TestBase.sol";

contract AdminConfigTest is TestBase {
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

    function testFuzz_SetPauseDuration(uint256 duration) public {
        duration = bound(duration, MIN_PAUSE_DURATION, MAX_PAUSE_DURATION);
        vm.assume(duration != PAUSE_DURATION);
        vm.prank(admin);
        cb.setPauseDuration(duration);
        assertEq(cb.pauseDuration(), duration);
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
        _registerPauser(address(mockPausable), pauser);

        vm.warp(block.timestamp + HEARTBEAT_INTERVAL - 1);
        vm.prank(pauser);
        cb.heartbeat();

        vm.prank(admin);
        cb.setHeartbeatInterval(MIN_HEARTBEAT_INTERVAL);

        vm.warp(block.timestamp + MIN_HEARTBEAT_INTERVAL + 1);
        vm.prank(pauser);
        cb.heartbeat();

        assertTrue(cb.isPauserLive(pauser));
    }

    function test_SetHeartbeatInterval_ReductionWorstCaseWindow() public {
        _registerPauser(address(mockPausable), pauser);

        // Pauser heartbeats right before the interval reduction
        vm.prank(pauser);
        cb.heartbeat();
        uint256 expiryBeforeReduction = cb.heartbeatExpiry(pauser);

        // Admin drastically reduces interval: 365d -> 30d
        vm.prank(admin);
        cb.setHeartbeatInterval(MIN_HEARTBEAT_INTERVAL);

        // Existing expiry is unchanged -- pauser stays live for the full original window
        assertEq(cb.heartbeatExpiry(pauser), expiryBeforeReduction);
        assertTrue(cb.isPauserLive(pauser));

        // At the old expiry minus 1, pauser is still live (worst case)
        vm.warp(expiryBeforeReduction - 1);
        assertTrue(cb.isPauserLive(pauser));

        // Pauser can still heartbeat, but now gets the new shorter interval
        vm.prank(pauser);
        cb.heartbeat();
        assertEq(cb.heartbeatExpiry(pauser), block.timestamp + MIN_HEARTBEAT_INTERVAL);
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

    function testFuzz_SetHeartbeatInterval(uint256 interval) public {
        interval = bound(interval, MIN_HEARTBEAT_INTERVAL, MAX_HEARTBEAT_INTERVAL);
        vm.assume(interval != HEARTBEAT_INTERVAL);
        vm.prank(admin);
        cb.setHeartbeatInterval(interval);
        assertEq(cb.heartbeatInterval(), interval);
    }
}
