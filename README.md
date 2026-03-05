# CircuitBreaker

![splash](/img/splash.jpg)

CircuitBreaker is an emergency pause mechanism for the Lido protocol: a single, permanent contract that lets trusted committees pause critical contracts without waiting for a DAO vote.

It's the successor to [GateSeals](https://github.com/lidofinance/gate-seals). Unlike GateSeals, it never needs to be redeployed or have permissions re-granted. The name comes from the analogy: a fuse is one-time use, a circuit breaker resets.

## Design

There are two roles: the **admin** (the DAO Agent) and **pausers** (multisig committees). The admin assigns a pauser to each pausable contract via `setPauser()`. One pauser can cover multiple contracts, but each contract has exactly one pauser.

In an emergency, the pauser calls `pause()` with the list of contracts they want to pause. Every contract in the list must have the caller assigned as its pauser. The call is atomic, so either all of them pause or none do. Each pausable contract gets paused for its individually configured duration, set by the admin when assigning a pauser via `setPauser()`.

After a successful pause, the pauser mapping for those contracts is deleted. The DAO has to explicitly re-assign before the contracts can be paused again.

If a contract is already paused, `pause()` skips it and preserves the existing pause.

Pause durations are per-pausable and updatable by the admin.

Pausers can call `heartbeat(pausable)` with any pausable they're registered for to record a liveness timestamp (it's also called automatically on `pause()`). The call verifies the caller is the registered pauser, so only known pausers can emit the signal. This is purely for off-chain monitoring.

## vs. GateSeal

GateSeal V1 expired after ~1 year and had to be redeployed. The proposed GateSeal V2 extended the lifetime but added significant configuration complexity and still required re-granting permissions after each use. 

See [circuit-breaker.md](circuit-breaker.md) for the full design.

For Foundry docs: https://book.getfoundry.sh/