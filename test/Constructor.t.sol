// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

import {CircuitBreaker} from "../src/CircuitBreaker.sol";
import {TestBase} from "./helpers/TestBase.sol";

contract ConstructorTest is TestBase {
    function test_SetsStateAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.CircuitBreakerInitialized(
            admin, MIN_PAUSE_DURATION, MAX_PAUSE_DURATION, MIN_HEARTBEAT_INTERVAL, MAX_HEARTBEAT_INTERVAL
        );
        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.PauseDurationUpdated(0, PAUSE_DURATION);
        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.HeartbeatIntervalUpdated(0, HEARTBEAT_INTERVAL);

        CircuitBreaker fresh = new CircuitBreaker(
            admin,
            MIN_PAUSE_DURATION,
            MAX_PAUSE_DURATION,
            MIN_HEARTBEAT_INTERVAL,
            MAX_HEARTBEAT_INTERVAL,
            PAUSE_DURATION,
            HEARTBEAT_INTERVAL
        );

        assertEq(fresh.ADMIN(), admin);
        assertEq(fresh.MIN_PAUSE_DURATION(), MIN_PAUSE_DURATION);
        assertEq(fresh.MAX_PAUSE_DURATION(), MAX_PAUSE_DURATION);
        assertEq(fresh.MIN_HEARTBEAT_INTERVAL(), MIN_HEARTBEAT_INTERVAL);
        assertEq(fresh.MAX_HEARTBEAT_INTERVAL(), MAX_HEARTBEAT_INTERVAL);
        assertEq(fresh.pauseDuration(), PAUSE_DURATION);
        assertEq(fresh.heartbeatInterval(), HEARTBEAT_INTERVAL);
        assertEq(fresh.getPausables().length, 0);
    }

    function test_MinEqualsMaxPauseDuration() public {
        uint256 fixedDuration = 7 days;
        CircuitBreaker fresh = new CircuitBreaker(
            admin,
            fixedDuration,
            fixedDuration,
            MIN_HEARTBEAT_INTERVAL,
            MAX_HEARTBEAT_INTERVAL,
            fixedDuration,
            HEARTBEAT_INTERVAL
        );

        assertEq(fresh.MIN_PAUSE_DURATION(), fixedDuration);
        assertEq(fresh.MAX_PAUSE_DURATION(), fixedDuration);
        assertEq(fresh.pauseDuration(), fixedDuration);

        // Cannot change pause duration since min == max == current
        vm.expectRevert(CircuitBreaker.PauseDurationUnchanged.selector);
        vm.prank(admin);
        fresh.setPauseDuration(fixedDuration);
    }

    function test_MinEqualsMaxHeartbeatInterval() public {
        uint256 fixedInterval = 60 days;
        CircuitBreaker fresh = new CircuitBreaker(
            admin, MIN_PAUSE_DURATION, MAX_PAUSE_DURATION, fixedInterval, fixedInterval, PAUSE_DURATION, fixedInterval
        );

        assertEq(fresh.MIN_HEARTBEAT_INTERVAL(), fixedInterval);
        assertEq(fresh.MAX_HEARTBEAT_INTERVAL(), fixedInterval);
        assertEq(fresh.heartbeatInterval(), fixedInterval);

        vm.expectRevert(CircuitBreaker.HeartbeatIntervalUnchanged.selector);
        vm.prank(admin);
        fresh.setHeartbeatInterval(fixedInterval);
    }

    function test_RevertIf_ZeroAdmin() public {
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

    function test_RevertIf_ZeroMinPauseDuration() public {
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

    function test_RevertIf_ZeroMaxPauseDuration() public {
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

    function test_RevertIf_MinPauseDurationExceedsMax() public {
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

    function test_RevertIf_ZeroMinHeartbeatInterval() public {
        vm.expectRevert(CircuitBreaker.MinHeartbeatIntervalIsZero.selector);
        new CircuitBreaker(
            admin, MIN_PAUSE_DURATION, MAX_PAUSE_DURATION, 0, MAX_HEARTBEAT_INTERVAL, PAUSE_DURATION, HEARTBEAT_INTERVAL
        );
    }

    function test_RevertIf_ZeroMaxHeartbeatInterval() public {
        vm.expectRevert(CircuitBreaker.MaxHeartbeatIntervalIsZero.selector);
        new CircuitBreaker(
            admin, MIN_PAUSE_DURATION, MAX_PAUSE_DURATION, MIN_HEARTBEAT_INTERVAL, 0, PAUSE_DURATION, HEARTBEAT_INTERVAL
        );
    }

    function test_RevertIf_MinHeartbeatIntervalExceedsMax() public {
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

    function test_RevertIf_PauseDurationOutOfBounds() public {
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

    function test_RevertIf_HeartbeatIntervalOutOfBounds() public {
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
}
