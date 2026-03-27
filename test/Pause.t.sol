// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

import {CircuitBreaker, IPausable} from "../src/CircuitBreaker.sol";
import {PauserRegistryManager} from "../src/PauserRegistryManager.sol";
import {TestBase, MockPausable} from "./helpers/TestBase.sol";

contract MockPausablePauseFails is IPausable {
    function isPaused() external pure returns (bool) {
        return false;
    }

    function pauseFor(uint256) external {}
}

contract MockPausableReverting is IPausable {
    function isPaused() external pure returns (bool) {
        return false;
    }

    function pauseFor(uint256) external pure {
        revert("pauseFor: forced revert");
    }
}

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

contract PauseTest is TestBase {
    MockPausablePauseFails internal mockPauseFails;
    MockPausableReverting internal mockPauseReverts;

    function setUp() public override {
        super.setUp();
        mockPauseFails = new MockPausablePauseFails();
        mockPauseReverts = new MockPausableReverting();
    }
    // =========================================================================
    // happy path
    // =========================================================================

    function test_HappyPath() public {
        _registerPauser(address(mockPausable), pauser);

        vm.warp(block.timestamp + 1 hours);
        uint256 ts = block.timestamp;

        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.HeartbeatUpdated(pauser);
        vm.expectEmit(true, true, true, true);
        emit PauserRegistryManager.PauserChanged(address(mockPausable), pauser, address(0));
        vm.expectEmit(true, true, false, true);
        emit CircuitBreaker.PauseTriggered(address(mockPausable), pauser, PAUSE_DURATION);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        assertTrue(mockPausable.isPaused());
        assertEq(mockPausable.getResumeSinceTimestamp(), ts + PAUSE_DURATION);
        assertEq(cb.getPauser(address(mockPausable)), address(0));
        assertEq(cb.heartbeatExpiry(pauser), ts + HEARTBEAT_INTERVAL);
        assertEq(cb.getPauserCount(), 0);
        assertEq(cb.getPausableCount(pauser), 0);
        assertEq(cb.getPausers().length, 0);
    }

    function test_SingleUse() public {
        _registerPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.pause(address(mockPausable));

        mockPausable.setState(false);
        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    function test_UsesUpdatedPauseDuration() public {
        _registerPauser(address(mockPausable), pauser);

        uint256 newDuration = MAX_PAUSE_DURATION;
        vm.prank(admin);
        cb.setPauseDuration(newDuration);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + newDuration);
    }

    function test_MultiplePausables_Independent() public {
        MockPausable mp2 = new MockPausable();
        _registerPauser(address(mockPausable), pauser);
        _registerPauser(address(mp2), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));

        assertEq(cb.getPauser(address(mockPausable)), address(0));
        assertEq(cb.getPauser(address(mp2)), pauser);
        assertEq(cb.getPauserCount(), 1);
        assertEq(cb.getPausableCount(pauser), 1);

        vm.prank(pauser);
        cb.pause(address(mp2));

        assertTrue(mp2.isPaused());
        assertEq(cb.getPauserCount(), 0);
        assertEq(cb.getPausableCount(pauser), 0);
    }

    function test_CrossPausableHeartbeatThenPause() public {
        MockPausable mp2 = new MockPausable();
        _registerPauser(address(mockPausable), pauser);
        _registerPauser(address(mp2), pauser);

        vm.prank(pauser);
        cb.heartbeat();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(pauser);
        cb.pause(address(mp2));

        assertEq(cb.heartbeatExpiry(pauser), block.timestamp + HEARTBEAT_INTERVAL);
        assertTrue(mp2.isPaused());
        assertEq(cb.getPauser(address(mockPausable)), pauser);
    }

    function test_FullLifecycle_RegisterPauseRearmPause() public {
        _registerPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
        assertEq(cb.getPauser(address(mockPausable)), address(0));

        mockPausable.setState(false);
        _registerPauser(address(mockPausable), pauser);

        vm.prank(pauser);
        cb.pause(address(mockPausable));
        assertTrue(mockPausable.isPaused());
        assertEq(mockPausable.getResumeSinceTimestamp(), block.timestamp + PAUSE_DURATION);
    }

    // =========================================================================
    // reverts
    // =========================================================================

    function test_RevertIf_NoPauserRegistered() public {
        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    function test_RevertIf_WrongCaller() public {
        _registerPauser(address(mockPausable), pauser);

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(stranger);
        cb.pause(address(mockPausable));
    }

    function test_RevertIf_AdminNotPauser() public {
        _registerPauser(address(mockPausable), pauser);

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(admin);
        cb.pause(address(mockPausable));
    }

    function test_RevertIf_HeartbeatExpired() public {
        _registerPauser(address(mockPausable), pauser);
        vm.warp(block.timestamp + HEARTBEAT_INTERVAL + 1);

        vm.expectRevert(CircuitBreaker.HeartbeatExpired.selector);
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    function test_RevertIf_PauserUnregisteredByAdmin() public {
        _registerPauser(address(mockPausable), pauser);

        vm.prank(admin);
        cb.setPauser(address(mockPausable), address(0));

        vm.expectRevert(CircuitBreaker.SenderNotPauser.selector);
        vm.prank(pauser);
        cb.pause(address(mockPausable));
    }

    function test_RevertIf_PausableIsEOA() public {
        address eoa = makeAddr("eoa");
        _registerPauser(eoa, pauser);

        vm.prank(pauser);
        vm.expectRevert();
        cb.pause(eoa);
    }

    function test_RevertIf_PauseFailed() public {
        _registerPauser(address(mockPauseFails), pauser);

        vm.expectRevert(CircuitBreaker.PauseFailed.selector);
        vm.prank(pauser);
        cb.pause(address(mockPauseFails));
    }

    function test_RevertIf_PauseForReverts() public {
        _registerPauser(address(mockPauseReverts), pauser);

        vm.expectRevert("pauseFor: forced revert");
        vm.prank(pauser);
        cb.pause(address(mockPauseReverts));
    }

    function test_RevertIf_Reentrancy() public {
        MockPausableReentrant reentrant = new MockPausableReentrant(cb);
        _registerPauser(address(reentrant), pauser);

        vm.expectRevert(CircuitBreaker.ReentrantCall.selector);
        vm.prank(pauser);
        cb.pause(address(reentrant));
    }

    function test_RevertIf_CrossPausableReentrancy() public {
        MockPausable target = new MockPausable();
        MockPausableCrossReentrant reentrant = new MockPausableCrossReentrant(cb, address(target));

        _registerPauser(address(reentrant), pauser);
        _registerPauser(address(target), pauser);

        vm.expectRevert(CircuitBreaker.ReentrantCall.selector);
        vm.prank(pauser);
        cb.pause(address(reentrant));
    }
}
