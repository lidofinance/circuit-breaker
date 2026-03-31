// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {CircuitBreaker, IPausable} from "../../src/CircuitBreaker.sol";
import {PauserRegistry} from "../../src/PauserRegistry.sol";

// ---------------------------------------------------------------------------
// Mocks
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
// Base
// ---------------------------------------------------------------------------

abstract contract TestBase is Test {
    CircuitBreaker internal cb;
    MockPausable internal mockPausable;

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MIN_PAUSE_DURATION = 3 days;
    uint256 internal constant MAX_PAUSE_DURATION = 30 days;
    uint256 internal constant PAUSE_DURATION = 14 days;

    uint256 internal constant MIN_HEARTBEAT_INTERVAL = 30 days;
    uint256 internal constant MAX_HEARTBEAT_INTERVAL = 1095 days;
    uint256 internal constant HEARTBEAT_INTERVAL = 365 days;

    function setUp() public virtual {
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
    }

    function _registerPauser(address _pausable, address _pauser) internal {
        vm.prank(admin);
        cb.registerPauser(_pausable, _pauser);
    }
}
