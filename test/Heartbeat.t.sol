// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

import {CircuitBreaker} from "../src/CircuitBreaker.sol";
import {TestBase, MockPausable} from "./helpers/TestBase.sol";

contract HeartbeatTest is TestBase {
    // =========================================================================
    // heartbeat
    // =========================================================================

    function test_UpdatesAndEmits() public {
        _registerPauser(address(mockPausable), pauser);

        vm.warp(block.timestamp + 1 hours);
        uint256 ts = block.timestamp;

        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.HeartbeatUpdated(pauser);
        vm.prank(pauser);
        cb.heartbeat();

        assertEq(cb.heartbeatExpiry(pauser), ts + HEARTBEAT_INTERVAL);
    }

    function test_SucceedsAtExactExpiryBoundary() public {
        _registerPauser(address(mockPausable), pauser);
        vm.warp(block.timestamp + HEARTBEAT_INTERVAL);

        vm.prank(pauser);
        cb.heartbeat();

        assertEq(cb.heartbeatExpiry(pauser), block.timestamp + HEARTBEAT_INTERVAL);
    }

    function test_UpdatesTimestampOnSubsequentCall() public {
        _registerPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.heartbeat();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauser);
        cb.heartbeat();

        assertEq(cb.heartbeatExpiry(pauser), block.timestamp + HEARTBEAT_INTERVAL);
    }

    function test_TracksEachPauserIndependently() public {
        MockPausable mp2 = new MockPausable();
        address pauser2 = makeAddr("pauser2");
        _registerPauser(address(mockPausable), pauser);
        _registerPauser(address(mp2), pauser2);

        vm.prank(pauser);
        cb.heartbeat();
        uint256 ts1 = block.timestamp;

        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauser2);
        cb.heartbeat();
        uint256 ts2 = block.timestamp;

        assertEq(cb.heartbeatExpiry(pauser), ts1 + HEARTBEAT_INTERVAL);
        assertEq(cb.heartbeatExpiry(pauser2), ts2 + HEARTBEAT_INTERVAL);
    }

    function test_WorksAfterOneOfMultiplePausablesConsumed() public {
        MockPausable mp2 = new MockPausable();
        _registerPauser(address(mockPausable), pauser);
        _registerPauser(address(mp2), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauser);
        cb.heartbeat();

        assertEq(cb.heartbeatExpiry(pauser), block.timestamp + HEARTBEAT_INTERVAL);
    }

    function test_RevertIf_NotRegistered() public {
        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.heartbeat();
    }

    function test_RevertIf_Expired() public {
        _registerPauser(address(mockPausable), pauser);
        vm.warp(block.timestamp + HEARTBEAT_INTERVAL + 1);

        vm.expectRevert(CircuitBreaker.HeartbeatExpired.selector);
        vm.prank(pauser);
        cb.heartbeat();
    }

    function test_RevertIf_ConsumedByPause_SinglePausable() public {
        _registerPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.heartbeat();
    }

    function test_RevertIf_AdminNotRegistered() public {
        _registerPauser(address(mockPausable), pauser);

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(admin);
        cb.heartbeat();
    }

    // =========================================================================
    // isPauserActive
    // =========================================================================

    function test_IsPauserActive() public {
        _registerPauser(address(mockPausable), pauser);
        assertTrue(cb.isPauserActive(pauser));

        vm.warp(block.timestamp + HEARTBEAT_INTERVAL);
        assertTrue(cb.isPauserActive(pauser));

        vm.warp(block.timestamp + 1);
        assertFalse(cb.isPauserActive(pauser));
    }

    function test_IsPauserActive_UnknownAddressReturnsFalse() public view {
        assertFalse(cb.isPauserActive(stranger));
    }
}
