## GateSeals V1

GateSeals were designed as a temporary, disposable emergency brake. A one-time panic button that a committee could smash to immediately pause critical contracts for a limited duration. Each GateSeal was configured at deployment with a fixed set of parameters: the committee, the pause duration, the list of pausable contracts, and an expiry date of up to one year. Once triggered, the GateSeal expired immediately. If never triggered, it expired naturally at the end of its lifetime. Either way, a new GateSeal had to be deployed from scratch.

## The Inconvenience Bomb

The redeployment cycle includes:

- deploying a new GateSeal,
- verifying parameters,
- preparing a snapshot vote (if necessary),
- preparing an on-chain vote revoking the role on the old GateSeal and granting the role to the new one.

This recurring operational burden was intentional and acted as "an inconvenience bomb" designed to push the Lido DAO to come up with a proper long-term solution to emergency pausing.

The bomb went off. The DAO did get tired of the redeployment process. And after three years without a single trigger, the tradeoffs that GateSeal introduces (a committee that can pause specific contracts once, for a bounded duration) proved acceptable given the alternative of having no fast-response capability at all.

## GateSeals V2

[GateSeals V2](https://www.notion.so/ADR-X-GateSeal-v2-216bf633d0c9809994ebd484c6334e42?pvs=21) were designed around committee-driven prolongation, removing the need for repeated DAO votes when nothing has gone wrong. The committee periodically extends the GateSeal's lifetime within designated windows, proving they're alive and responsive without burdening the DAO. It is a reasonable step forward. However, the implementation carries risks:

- **Misconfiguration-prone.** V2 introduces four new deployment parameters with interlocking constraints that must all be configured correctly. The prolongation windows are fixed and inflexible. If operational needs change, the contract must be redeployed.
- **Redundant liveness proofs.** V2 requires prolongation on every GateSeal individually. A committee managing three GateSeals must send three separate prolongation transactions within their respective windows, even though a single transaction already proves the committee is operational. One proof of liveness is enough; V2 demands one per GateSeal.
- **Fixed prolongation windows.** The prolongation windows are baked into the contract at deployment. If operational needs change, say the committee's signing schedule shifts or the DAO wants to align multiple GateSeals to the same window, the only option is to redeploy.

After exploring the V2 direction thoroughly, the conclusion is that the approach needs to change fundamentally. Instead of patching the GateSeal model with more parameters, the contributors propose a more streamlined unified solution.

## CircuitBreaker

CircuitBreaker is a single, permanent contract that manages all emergency pausing for the protocol. Like an electrical circuit breaker, it trips under fault conditions, protects the system, and is reset by an authorized party. It doesn't self-destruct after tripping.

> A **circuit breaker** is an electrical safety device designed to protect an electrical circuit from damage caused by current in excess of that which the equipment can safely carry (overcurrent). Its basic function is to interrupt current flow to protect equipment and to prevent fire. Unlike a fuse, which interrupts once and then must be replaced, a circuit breaker can be reset (either manually or automatically) to resume normal operation.

In this analogy, a GateSeal works much like a fuse and CircuitBreaker is, well, a circuit breaker for multiple circuits.

![image.png](attachment:af06302b-5052-4818-b1ca-c69f59b79bb0:image.png)

### How It Works

A single CircuitBreaker is deployed with minimal critical configuration: a global minimum and maximum pause duration, and the DAO Agent address, and is never redeployed (unless a vulnerability found or when moving to a new system). The DAO configures committees and pausable contracts.

**Pausables and committees.** The DAO registers pausable contracts by pairing each one with a committee. That's the entire configuration per contract: one mapping from a pausable contract to the committee responsible for it. The DAO grants pause permission on each protected contract to the CircuitBreaker's address once. Since the address never changes, this permission does not need to be revoked and regranted.

**Pause duration bounds.** The global minimum and maximum pause duration apply to all committees equally. These bounds can be updated at any time to reflect changes in governance timing (e.g. after Dual Governance introduction).

**Tripping.** In an emergency, the committee triggers the CircuitBreaker with the list of contracts to pause and the desired duration (within the global bounds). For each contract, the CircuitBreaker verifies the caller is the assigned committee and that the pair hasn't already been tripped, then pauses the contract. If any pause call fails, the entire transaction reverts. Tripping is atomic. Each successful trip burns the committee's right on that specific contract. The committee can still trip other contracts assigned to them.

**Resetting.** After a trip, the DAO resets specific contracts, re-enabling the committee's right to trip them again. The circuit breaker analogy: the breaker tripped, the fault was addressed, the operator flips it back on.

**Heartbeat.** The heartbeat is tied to the committee, not to individual contracts. A single heartbeat transaction proves the committee is alive for everything it's responsible for, regardless of how many contracts it covers. This directly addresses V2's redundant prolongation problem: instead of one prolongation per GateSeal, there is one heartbeat per committee.

The heartbeat doesn't gate any functionality. A committee with a stale heartbeat can still trip. It exists solely for observability: monitoring systems watch for stale heartbeats and alert the DAO that a committee may be unresponsive. The reasoning is simple: throwing out the fire extinguisher because you're not sure if it still works is worse than having one that might not work. If the DAO determines a committee is truly dead, it reassigns the committee's contracts to a new committee.

**Kill switch.** The DAO can permanently disable the CircuitBreaker, stopping all interactions. Whether it's a discovered vulnerability, a governance decision, or a migration to a new system, the DAO flips one switch and the contract becomes dead.

## Comparison

| Problem                            | GateSeal V1                                                                                            | GateSeal V2                                                                                                                                               | CircuitBreaker                                                                                                                                                                                         |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Rotation burden**                | DAO performs a full redeploy every year                                                                | Committee prolongs within set windows, but each GateSeal requires its own prolongation; windows are inflexible, and parameters are misconfiguration-prone | One heartbeat per committee confirms liveness (one tx a year total). If committee is not responsive, DAO replaces it with a vote (single vote item). No expiry, no windows, no prolongation parameters |
| **Pause duration limits**          | Hardcoded 4 to 14 day range at a deploy time. Change in vote timeline requires blueprint redeployment. | Set at deploy time without limits                                                                                                                         | Specified at pause time, capped by global min/max limits (updatable by DAO at any time)                                                                                                                |
| **Permission re-grants after use** | New address every cycle (every year)                                                                   | New address every cycle but the cycle is significantly extended (up to 5 years)                                                                           | Permanent address. Permission granted once per contract, survives all trip/reset cycles. Doesn't need to be regranted                                                                                  |
| **Adding new pausable contracts**  | Deploy new GateSeal and hold a role grant vote                                                         | Deploy new GateSeal and hold a role grant vote                                                                                                            | Hold a vote to add a committee-contract pair on the existing CircuitBreake                                                                                                                             |
| **Scaling**                        | One GateSeal per scope, each with its own lifecycle                                                    | Same, plus each GateSeal needs its own prolongation (multiple txs for the same committee on different GateSeals)                                          | All committees and contracts in one contract. One heartbeat tx per committee                                                                                                                           |
| **Coverage gaps**                  | Gap between expiry and redeployment                                                                    | Reduced but possible if prolongation window is missed                                                                                                     | No gap between expiration and replacement                                                                                                                                                              |
| **Swapping a dead committee**      | Deploy new GateSeal, re-grant all permissions                                                          | Same problem                                                                                                                                              | Reassign contracts to new committee address                                                                                                                                                            |
| **Granular use**                   | Subset selection possible but entire GateSeal is expired                                               | Entire GateSeal is expired                                                                                                                                | Per-contract triggered state. Tripping one preserves the right to trip others                                                                                                                          |
| **Misconfiguration risk**          | Low, 4 simple parameters                                                                               | High, 8 parameters with interlocking constraints                                                                                                          | Low, global min/max duration plus contract-committee pairs                                                                                                                                             |

### Risks and Mitigations

**Single point of failure.** A bug in CircuitBreaker affects all committees and protected contracts, unlike isolated GateSeals where each has a limited blast radius. Mitigation: the contract is simpler than GateSeal V2 despite doing more, reducing audit surface. The kill switch provides an immediate shutdown if a vulnerability is discovered

**Broad pause authority.** The CircuitBreaker address holds pause permissions on multiple pausable contracts. Mitigation: the CircuitBreaker can only be tripped by the committee assigned to each contract. The DAO can revoke permission on any contract independently, and the kill switch disables everything at once.

**No forced expiry.** A committee with lost keys retains authority until the DAO explicitly reassigns their contracts. Mitigation: the heartbeat feature surfaces unresponsive committees. The DAO can reassign contracts or remove committees at any time.

### Architecture

![image.png](attachment:fff07717-fd8d-4366-a9ca-c5a4ab8e4ea2:image.png)

### Lifecycle

A walkthrough using two committees (**Committee_A** and **Committee_B**) managing four pausable contracts (**WithdrawalQueue**, **ValidatorExitBus**, **VaultHub**, **PredepositGuarantee**).

```
DEPLOYMENT - dev team
│
│  CircuitBreaker is deployed with:
│    admin = DAO Agent
│    minPauseDuration = 9 days
|    maxPauseDuration = 21 days
│
CONFIGURATION - DAO
│
│  DAO configures the CircuitBreaker in a single vote:
│    setTripper(WithdrawalQueue, Committee_A)
│    setTripper(ValidatorExitBus, Committee_A)
│    setTripper(VaultHub, Committee_B)
│    setTripper(PredepositGuarantee, Committee_B)
|    grantRole(WithdrawalQueue.PAUSE_ROLE, CircuitBreaker)
|    grantRole(ValidatorExitBus.PAUSE_ROLE, CircuitBreaker)
|    grantRole(VaultHub.PAUSE_ROLE, CircuitBreaker)
|    grantRole(PredepositGuarantee.PAUSE_ROLE, CircuitBreaker)
│
│  State:
│    WithdrawalQueue      → Committee_A   ✓ ready
│    ValidatorExitBus     → Committee_A   ✓ ready
│    VaultHub             → Committee_B   ✓ ready
│    PredepositGuarantee  → Committee_B   ✓ ready
│
HEARTBEAT - committees
│
│  Committee_A calls heartbeat()
│  Committee_B calls heartbeat()
│
│  Latest heartbeat timestamps are recorded in the contract
│
TRIP - committee
│
│  Vulnerability discovered affecting ValidatorExitBus.
│  Committee_A calls trip([ValidatorExitBus], 14 days).
│  ValidatorExitBus is paused.
│
│  State:
│    WithdrawalQueue      → Committee_A   ✓ ready (unaffected)
│    ValidatorExitBus     → 0x0           ✗ spent
│    VaultHub             → Committee_B   ✓ ready (unaffected)
│    PredepositGuarantee  → Committee_B   ✓ ready (unaffected)
|
|    Committee_A heartbeat updated to trip timesteamp.
│
RESET - DAO vote
│
│  Vulnerability patched. DAO resets the tripped contract:
│    setTripper(ValidatorExitBus,  Committee_A)
│
│  State:
│    WithdrawalQueue      → Committee_A   ✓ ready
│    ValidatorExitBus     → Committee_A   ✓ ready
│    VaultHub             → Committee_B   ✓ ready
│    PredepositGuarantee  → Committee_B   ✓ ready
│
RECONFIGURATION (if needed) - DAO vote
│
│  Any of these, no redeployment required:
│    updatePauseDurationBounds(7 days, 28 days)     — change pause bounds
│    setTripper(ValidatorExitBus, address(0))       — remove tripper
│    setTripper(PredepositGuarantee, Committee_New) — replace dead committee
│
│  CircuitBreaker address and all existing permissions remain unchanged.
│
KILL SWITCH - DAO vote
│
│  Vulnerability in CircuitBreaker itself, or migration to new system.
│  DAO calls kill(). Contract is permanently disabled:
│    ✗ no committee can trip
│    ✗ no configuration can change
│    ✗ no heartbeat can be sent
│
│  DAO revokes PAUSE_ROLE from CircuitBreaker on each pausable at its own pace.
▼
```

### Example simplified implementation

```solidity
contract CircuitBreaker {
    address public immutable admin;
    bool public dead;

    uint256 public minPauseDurationSeconds; // eg 9 days
    uint256 public maxPauseDurationSeconds; // eg 21 days

    // might need a reverse mapping for monitoring/view access
    mapping(address pausable => address committee) public tripper;
    mapping(address committee => uint256 timestamp) public lastHeartbeat;

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    modifier notDead() {
        require(!dead, "dead");
        _;
    }

    constructor(
        address _admin,
        uint256 _minPauseDurationSeconds,
        uint256 _maxPauseDurationSeconds
    ) {
        admin = _admin;
        minPauseDurationSeconds = _minPauseDurationSeconds;
        maxPauseDurationSeconds = _maxPauseDurationSeconds;
    }

    // DAO Agent
    // setTripper(pausable, ZeroAddress) to remove the tripper
    function setTripper(
        address _pausable,
        address _committee
    ) external onlyAdmin notDead {
        tripper[_pausable] = _committee;
    }

    function updatePauseDurationBounds(
        uint256 _min,
        uint256 _max
    ) external onlyAdmin notDead {
        minPauseDurationSeconds = _min;
        maxPauseDurationSeconds = _max;
    }

    function kill() external onlyAdmin notDead {
        killed = true;
    }

    // Committee

    function trip(
        address[] calldata _pausables,
        uint256 _duration
    ) external notDead {
        require(_pausables.length > 0, "empty list");
        require(_duration >= minPauseDurationSeconds, "duration too short");
        require(_duration <= maxPauseDurationSeconds, "duration too long");

        for (uint256 i = 0; i < _pausables.length; i++) {
            address pausable = _pausables[i];
            IPausable ipausable = IPausable(pausable);

            if (ipausable.paused()) continue;
            require(tripper[pausable] == msg.sender, "not a tripper");

            ipausable.pauseFor(_duration);
            require(ipausable.paused(), "pause failed");

            tripper[pausable] = address(0);
            lastHeartbeat[msg.sender] = block.timestamp;
        }
    }

    function heartbeat() external notDead {
        lastHeartbeat[msg.sender] = block.timestamp;
    }
}
```
