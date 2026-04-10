// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {CircuitBreaker} from "../src/CircuitBreaker.sol";

/// @title  Deploy
/// @notice Deploys CircuitBreaker with all parameters passed via --sig.
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy \
///     --sig "run(address,uint256,uint256,uint256,uint256,uint256,uint256)" \
///     <admin> <minPauseDuration> <maxPauseDuration> \
///     <minHeartbeatInterval> <maxHeartbeatInterval> \
///     <initialPauseDuration> <initialHeartbeatInterval> \
///     --rpc-url hoodi \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast \
///     --verify
///
/// Output:
///   Writes deploy artifact to out/deploy.json with the deployed address.
contract Deploy is Script {
    function run(
        address _admin,
        uint256 _minPauseDuration,
        uint256 _maxPauseDuration,
        uint256 _minHeartbeatInterval,
        uint256 _maxHeartbeatInterval,
        uint256 _initialPauseDuration,
        uint256 _initialHeartbeatInterval
    ) external {
        console.log("Deploying CircuitBreaker");
        console.log("  chainid:                  ", block.chainid);
        console.log("  admin:                    ", _admin);
        console.log("  minPauseDuration:         ", _minPauseDuration);
        console.log("  maxPauseDuration:         ", _maxPauseDuration);
        console.log("  minHeartbeatInterval:     ", _minHeartbeatInterval);
        console.log("  maxHeartbeatInterval:     ", _maxHeartbeatInterval);
        console.log("  initialPauseDuration:     ", _initialPauseDuration);
        console.log("  initialHeartbeatInterval: ", _initialHeartbeatInterval);

        vm.startBroadcast();
        CircuitBreaker circuitBreaker = new CircuitBreaker(
            _admin,
            _minPauseDuration,
            _maxPauseDuration,
            _minHeartbeatInterval,
            _maxHeartbeatInterval,
            _initialPauseDuration,
            _initialHeartbeatInterval
        );
        vm.stopBroadcast();

        string memory args = "args";
        vm.serializeAddress(args, "admin", _admin);
        vm.serializeUint(args, "minPauseDuration", _minPauseDuration);
        vm.serializeUint(args, "maxPauseDuration", _maxPauseDuration);
        vm.serializeUint(args, "minHeartbeatInterval", _minHeartbeatInterval);
        vm.serializeUint(args, "maxHeartbeatInterval", _maxHeartbeatInterval);
        vm.serializeUint(args, "initialPauseDuration", _initialPauseDuration);
        string memory argsJson = vm.serializeUint(args, "initialHeartbeatInterval", _initialHeartbeatInterval);

        string memory meta = "meta";
        vm.serializeAddress(meta, "deployer", msg.sender);
        vm.serializeUint(meta, "chainId", block.chainid);
        vm.serializeUint(meta, "blockNumber", block.number);
        string memory metaJson = vm.serializeUint(meta, "timestamp", block.timestamp);

        string memory root = "root";
        vm.serializeAddress(root, "circuitBreaker", address(circuitBreaker));
        vm.serializeString(root, "constructorArgs", argsJson);
        string memory output = vm.serializeString(root, "meta", metaJson);

        string memory path = string.concat(vm.envOr("DEPLOY_NAME", vm.toString(block.chainid)), ".json");
        vm.writeJson(output, path);

        console.log("CircuitBreaker deployed at:", address(circuitBreaker));
        console.log("Artifact written to", path);
    }
}
