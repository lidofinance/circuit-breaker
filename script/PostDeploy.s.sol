// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {CircuitBreaker, IPausable} from "../src/CircuitBreaker.sol";

contract MockPausable is IPausable {
    uint256 private _resumeSince;

    function isPaused() external view returns (bool) {
        return block.timestamp < _resumeSince;
    }

    function pauseFor(uint256 _duration) external {
        _resumeSince = block.timestamp + _duration;
    }
}

/// @title  PostDeploy
/// @notice Verifies a deployed CircuitBreaker against the set parameters
///         and runs a simple happy path on fork.
///
/// Usage (do NOT pass --broadcast; happy path relies on prank cheatcodes):
///
///   CB=<deployed-address> \
///   ADMIN=... MIN_PAUSE_DURATION=... MAX_PAUSE_DURATION=... \
///   MIN_HEARTBEAT_INTERVAL=... MAX_HEARTBEAT_INTERVAL=... \
///   INITIAL_PAUSE_DURATION=... INITIAL_HEARTBEAT_INTERVAL=... \
///   forge script script/PostDeploy.s.sol:PostDeploy \
///     --rpc-url $FORK_RPC_URL
contract PostDeploy is Script {
    function run() external {
        CircuitBreaker cb = CircuitBreaker(vm.envAddress("CB"));

        address expectedAdmin = vm.envAddress("ADMIN");
        uint256 expectedMinPause = vm.envUint("MIN_PAUSE_DURATION");
        uint256 expectedMaxPause = vm.envUint("MAX_PAUSE_DURATION");
        uint256 expectedMinHeartbeat = vm.envUint("MIN_HEARTBEAT_INTERVAL");
        uint256 expectedMaxHeartbeat = vm.envUint("MAX_HEARTBEAT_INTERVAL");
        uint256 expectedInitialPause = vm.envUint("INITIAL_PAUSE_DURATION");
        uint256 expectedInitialHeartbeat = vm.envUint("INITIAL_HEARTBEAT_INTERVAL");

        console.log("CircuitBreaker:", address(cb));
        console.log("chainid:       ", block.chainid);

        // ---------------------------------------------------------------
        // Parameter verification
        // ---------------------------------------------------------------
        require(cb.ADMIN() == expectedAdmin, "ADMIN mismatch");
        require(cb.MIN_PAUSE_DURATION() == expectedMinPause, "MIN_PAUSE_DURATION mismatch");
        require(cb.MAX_PAUSE_DURATION() == expectedMaxPause, "MAX_PAUSE_DURATION mismatch");
        require(cb.MIN_HEARTBEAT_INTERVAL() == expectedMinHeartbeat, "MIN_HEARTBEAT_INTERVAL mismatch");
        require(cb.MAX_HEARTBEAT_INTERVAL() == expectedMaxHeartbeat, "MAX_HEARTBEAT_INTERVAL mismatch");
        require(cb.pauseDuration() == expectedInitialPause, "pauseDuration mismatch");
        require(cb.heartbeatInterval() == expectedInitialHeartbeat, "heartbeatInterval mismatch");
        require(cb.getPausables().length == 0, "getPausables() should be empty at post-deploy");
        console.log("Parameter verification: OK");

        // ---------------------------------------------------------------
        // Happy path (fork simulation only)
        // ---------------------------------------------------------------
        MockPausable pausable = new MockPausable();
        address pauser = makeAddr("post-deploy-pauser");

        vm.prank(expectedAdmin);
        cb.registerPauser(address(pausable), pauser);
        require(cb.getPauser(address(pausable)) == pauser, "pauser not registered");
        require(cb.isPauserLive(pauser), "pauser not live after register");

        vm.prank(pauser);
        cb.pause(address(pausable));
        require(pausable.isPaused(), "pausable not paused");
        require(cb.getPauser(address(pausable)) == address(0), "pauser not cleared after pause");

        console.log("Happy path (register -> pause): OK");
        console.log("PostDeploy: all checks passed");
    }
}
