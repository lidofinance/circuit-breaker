// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

import {Vm} from "forge-std/Test.sol";
import {CircuitBreaker} from "../src/CircuitBreaker.sol";
import {Registry} from "../src/Registry.sol";
import {TestBase, MockPausable} from "./helpers/TestBase.sol";

contract RegistryTest is TestBase {
    // =========================================================================
    // register
    // =========================================================================

    function test_RegistersAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mockPausable), address(0), pauser);
        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.HeartbeatUpdated(pauser, block.timestamp + HEARTBEAT_INTERVAL);

        vm.prank(admin);
        cb.registerPauser(address(mockPausable), pauser);

        assertEq(cb.getPauser(address(mockPausable)), pauser);
        assertEq(cb.heartbeatExpiry(pauser), block.timestamp + HEARTBEAT_INTERVAL);
        assertEq(cb.getPausableCount(pauser), 1);

        address[] memory pausables = cb.getPausables();
        assertEq(pausables.length, 1);
        assertEq(pausables[0], address(mockPausable));
    }

    // =========================================================================
    // replace
    // =========================================================================

    function test_ReplacesAndEmits() public {
        address pauser2 = makeAddr("pauser2");
        _registerPauser(address(mockPausable), pauser);

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mockPausable), pauser, pauser2);
        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.HeartbeatUpdated(pauser2, block.timestamp + HEARTBEAT_INTERVAL);

        vm.prank(admin);
        cb.registerPauser(address(mockPausable), pauser2);

        assertEq(cb.getPauser(address(mockPausable)), pauser2);
        assertEq(cb.getPausableCount(pauser), 0);
        assertEq(cb.getPausableCount(pauser2), 1);

        address[] memory pausables = cb.getPausables();
        assertEq(pausables.length, 1);
        assertEq(pausables[0], address(mockPausable));
    }

    function test_SamePauserReassignment() public {
        _registerPauser(address(mockPausable), pauser);

        vm.warp(block.timestamp + HEARTBEAT_INTERVAL / 2);

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mockPausable), pauser, pauser);
        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.HeartbeatUpdated(pauser, block.timestamp + HEARTBEAT_INTERVAL);

        vm.prank(admin);
        cb.registerPauser(address(mockPausable), pauser);

        assertEq(cb.heartbeatExpiry(pauser), block.timestamp + HEARTBEAT_INTERVAL);
        assertEq(cb.getPausableCount(pauser), 1);
        assertEq(cb.getPausables().length, 1);
    }

    // =========================================================================
    // unregister
    // =========================================================================

    function test_UnregistersAndEmits() public {
        _registerPauser(address(mockPausable), pauser);

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mockPausable), pauser, address(0));

        vm.recordLogs();
        vm.prank(admin);
        cb.registerPauser(address(mockPausable), address(0));

        assertEq(cb.getPauser(address(mockPausable)), address(0));
        assertEq(cb.getPausableCount(pauser), 0);
        assertEq(cb.getPausables().length, 0);

        // No HeartbeatUpdated event when unregistering
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != CircuitBreaker.HeartbeatUpdated.selector);
        }
    }

    // =========================================================================
    // multi-pausable pauser
    // =========================================================================

    function test_SamePauserMultiplePausables() public {
        MockPausable mp2 = new MockPausable();

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mockPausable), address(0), pauser);
        _registerPauser(address(mockPausable), pauser);

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mp2), address(0), pauser);
        _registerPauser(address(mp2), pauser);

        assertEq(cb.getPausableCount(pauser), 2);

        address[] memory pausables = cb.getPausables();
        assertEq(pausables.length, 2);
        assertEq(pausables[0], address(mockPausable));
        assertEq(pausables[1], address(mp2));
    }

    function test_RemoveFromOnePausable_StillRegisteredForAnother() public {
        MockPausable mp2 = new MockPausable();
        _registerPauser(address(mockPausable), pauser);
        _registerPauser(address(mp2), pauser);

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mockPausable), pauser, address(0));
        vm.prank(admin);
        cb.registerPauser(address(mockPausable), address(0));

        assertEq(cb.getPausableCount(pauser), 1);
        assertEq(cb.getPausables().length, 1);
        assertEq(cb.getPausables()[0], address(mp2));
    }

    // =========================================================================
    // swap-and-pop
    // =========================================================================

    function test_SwapAndPop_RemoveMiddle() public {
        address pauser2 = makeAddr("pauser2");
        address pauser3 = makeAddr("pauser3");
        MockPausable mp2 = new MockPausable();
        MockPausable mp3 = new MockPausable();

        _registerPauser(address(mockPausable), pauser);
        _registerPauser(address(mp2), pauser2);
        _registerPauser(address(mp3), pauser3);

        assertEq(cb.getPausables().length, 3);

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mp2), pauser2, address(0));
        vm.prank(admin);
        cb.registerPauser(address(mp2), address(0));

        address[] memory pausables = cb.getPausables();
        assertEq(pausables.length, 2);
        assertEq(pausables[0], address(mockPausable));
        assertEq(pausables[1], address(mp3));
        assertEq(cb.getPausableCount(pauser2), 0);
    }

    function test_SwapAndPop_RemoveFirst() public {
        address pauser2 = makeAddr("pauser2");
        address pauser3 = makeAddr("pauser3");
        MockPausable mp2 = new MockPausable();
        MockPausable mp3 = new MockPausable();

        _registerPauser(address(mockPausable), pauser);
        _registerPauser(address(mp2), pauser2);
        _registerPauser(address(mp3), pauser3);

        vm.prank(admin);
        cb.registerPauser(address(mockPausable), address(0));

        address[] memory pausables = cb.getPausables();
        assertEq(pausables.length, 2);
        assertEq(pausables[0], address(mp3));
        assertEq(pausables[1], address(mp2));
    }

    function test_SwapAndPop_RemoveLast() public {
        address pauser2 = makeAddr("pauser2");
        address pauser3 = makeAddr("pauser3");
        MockPausable mp2 = new MockPausable();
        MockPausable mp3 = new MockPausable();

        _registerPauser(address(mockPausable), pauser);
        _registerPauser(address(mp2), pauser2);
        _registerPauser(address(mp3), pauser3);

        vm.prank(admin);
        cb.registerPauser(address(mp3), address(0));

        address[] memory pausables = cb.getPausables();
        assertEq(pausables.length, 2);
        assertEq(pausables[0], address(mockPausable));
        assertEq(pausables[1], address(mp2));
    }

    function test_SwapAndPop_RemoveOnlyElement() public {
        _registerPauser(address(mockPausable), pauser);

        vm.prank(admin);
        cb.registerPauser(address(mockPausable), address(0));

        assertEq(cb.getPausables().length, 0);
    }

    // =========================================================================
    // re-register
    // =========================================================================

    function test_ReRegisterAfterFullRemoval() public {
        _registerPauser(address(mockPausable), pauser);

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mockPausable), pauser, address(0));
        vm.prank(admin);
        cb.registerPauser(address(mockPausable), address(0));

        assertEq(cb.getPausables().length, 0);

        address pauser2 = makeAddr("pauser2");

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mockPausable), address(0), pauser2);
        _registerPauser(address(mockPausable), pauser2);

        assertEq(cb.getPauser(address(mockPausable)), pauser2);
        assertEq(cb.getPausables().length, 1);
        assertEq(cb.getPausables()[0], address(mockPausable));

        vm.expectEmit(true, true, false, true);
        emit CircuitBreaker.PauseTriggered(address(mockPausable), pauser2, PAUSE_DURATION);
        vm.prank(pauser2);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
    }

    // =========================================================================
    // re-registration of expired pauser
    // =========================================================================

    function test_ReRegisterExpiredPauser_RefreshesHeartbeat() public {
        _registerPauser(address(mockPausable), pauser);

        vm.warp(block.timestamp + HEARTBEAT_INTERVAL + 1);
        assertFalse(cb.isPauserLive(pauser));

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mockPausable), pauser, pauser);
        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.HeartbeatUpdated(pauser, block.timestamp + HEARTBEAT_INTERVAL);
        vm.prank(admin);
        cb.registerPauser(address(mockPausable), pauser);

        assertTrue(cb.isPauserLive(pauser));
        assertEq(cb.heartbeatExpiry(pauser), block.timestamp + HEARTBEAT_INTERVAL);

        vm.prank(pauser);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
    }

    // =========================================================================
    // partial consumption + admin removal
    // =========================================================================

    function test_PartialConsumption_ThenAdminRemovesRemaining() public {
        MockPausable mp2 = new MockPausable();
        MockPausable mp3 = new MockPausable();
        _registerPauser(address(mockPausable), pauser);
        _registerPauser(address(mp2), pauser);
        _registerPauser(address(mp3), pauser);

        assertEq(cb.getPausableCount(pauser), 3);

        // Pauser pauses one
        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mockPausable), pauser, address(0));
        vm.expectEmit(true, true, false, true);
        emit CircuitBreaker.PauseTriggered(address(mockPausable), pauser, PAUSE_DURATION);
        vm.prank(pauser);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
        assertEq(cb.getPausableCount(pauser), 2);

        // Admin unregisters the remaining two
        vm.startPrank(admin);

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mp2), pauser, address(0));
        cb.registerPauser(address(mp2), address(0));

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mp3), pauser, address(0));
        cb.registerPauser(address(mp3), address(0));

        vm.stopPrank();

        assertEq(cb.getPausableCount(pauser), 0);
        assertEq(cb.getPausables().length, 0);

        // Pauser can no longer act
        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.heartbeat();
    }

    // =========================================================================
    // reverts
    // =========================================================================

    function test_RevertIf_ZeroPausable() public {
        vm.expectRevert(Registry.PausableZero.selector);
        vm.prank(admin);
        cb.registerPauser(address(0), pauser);
    }

    function test_RevertIf_PauserAlreadyZero() public {
        vm.expectRevert(Registry.PauserAlreadyZero.selector);
        vm.prank(admin);
        cb.registerPauser(address(mockPausable), address(0));
    }

    function test_RevertIf_SenderNotAdmin() public {
        vm.expectRevert(CircuitBreaker.SenderNotAdmin.selector);
        vm.prank(stranger);
        cb.registerPauser(address(mockPausable), pauser);
    }

    function test_RevertIf_SenderIsPauser() public {
        vm.expectRevert(CircuitBreaker.SenderNotAdmin.selector);
        vm.prank(pauser);
        cb.registerPauser(address(mockPausable), pauser);
    }

    function test_RevertIf_ZeroPausableAndZeroPauser() public {
        vm.expectRevert(Registry.PausableZero.selector);
        vm.prank(admin);
        cb.registerPauser(address(0), address(0));
    }

    // =========================================================================
    // view function defaults
    // =========================================================================

    function test_GetPauser_ReturnsZeroForUnregistered() public view {
        assertEq(cb.getPauser(address(mockPausable)), address(0));
    }

    function test_GetPausableCount_ReturnsZeroForUnknown() public view {
        assertEq(cb.getPausableCount(stranger), 0);
    }

    function test_GetPausables_EmptyByDefault() public view {
        assertEq(cb.getPausables().length, 0);
    }

    // =========================================================================
    // swap-and-pop event checks
    // =========================================================================

    function test_SwapAndPop_RemoveFirst_EmitsEvent() public {
        address pauser2 = makeAddr("pauser2");
        MockPausable mp2 = new MockPausable();
        _registerPauser(address(mockPausable), pauser);
        _registerPauser(address(mp2), pauser2);

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mockPausable), pauser, address(0));
        vm.prank(admin);
        cb.registerPauser(address(mockPausable), address(0));

        assertEq(cb.getPausables().length, 1);
        assertEq(cb.getPausables()[0], address(mp2));
        assertEq(cb.getPausableCount(pauser), 0);
    }

    function test_SwapAndPop_RemoveOnlyElement_EmitsEvent() public {
        _registerPauser(address(mockPausable), pauser);

        vm.expectEmit(true, true, true, true);
        emit Registry.PauserSet(address(mockPausable), pauser, address(0));
        vm.prank(admin);
        cb.registerPauser(address(mockPausable), address(0));

        assertEq(cb.getPausables().length, 0);
        assertEq(cb.getPausableCount(pauser), 0);
    }
}
