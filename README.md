# bdag-stack-guard

A small, dependency-free **health & security watchdog** for a BlockDAG ASIC mining
stack (node + pool + rigs running under Docker). It catches the failure modes that
silently halt mining — and, optionally, auto-heals the safe ones — while never
touching the node process itself.

One script. Bash + `curl` + `docker`. Run it from cron every 5 minutes.

## Why this exists

A production mining stack went dark for hours, and the existing monitor reported
"all clear" the entire time. The post-incident review turned up a cluster of
failure modes that share one nasty property: **the node looks up, but nothing is
mining.** This guard is the generalized fix.

The failure modes it was built from:

- **Chain-drift blind spot.** The old monitor compared the local chain against a
  *hard-coded* block hash captured weeks earlier. When the network migrated to a
  successor chain, the node quietly fell onto the abandoned fork while every check
  still read "canonical: OK." → This guard compares against a **live** canonical
  reference RPC at a common depth. Never hard-code a hash.
- **Node fail-close recovery latch.** A recovery/fork-guard binary tripped its own
  durable "clean-resync latch" and came up status-only: no RPC, no templates, no
  mining — and a restart just re-selected the latch. → Detected from node logs.
- **Production stall.** Node healthy, pool up, but zero blocks landing. → Detected
  by counting accepted submissions over a window.
- **Pool stopped by a stale automation hold.** A control-plane state
  (`repair_hold` / `controlled_stop`) left the lease-gated pool refusing to start
  long after the node was healthy again. → Detected, and optionally auto-cleared.
- **Silent config clobber & image swaps.** Automation re-adding config options the
  running binary rejects, or swapping the node image out from under you. → Change
  detection with alerts (never an auto-revert).

Plus security tripwires, because "why is it down" and "did someone get in" are the
same 3 a.m. question: SSH from an unexpected source, brute-force spikes, new
`authorized_keys`, new externally-bound listeners.

## What it checks

| Class | Check | Alert |
|------|-------|-------|
| Health | Local EVM RPC reachable | `NODE-RPC-DOWN` |
| Health | Local vs **live** canonical hash at a common depth | `CHAIN-DRIFT` |
| Health | Blocks behind canonical | `NODE-LAGGING` |
| Health | Peer count below floor | `PEER-STARVATION` |
| Health | Node recovery/clean-resync latch in logs | `FAIL-CLOSE-LATCH` |
| Health | Zero submissions over N minutes | `PRODUCTION-STALL` |
| Health | No running pool container | `POOL-DOWN` |
| Health | Control-plane state ≠ `normal` | `AUTOMATION-HOLD` |
| Change | Node image changed | `NODE-IMAGE-SWAP` |
| Change | `canonicalprotection` lines present | `CANONICALPROTECTION-CLOBBER` |
| Security | Accepted SSH from non-allowlisted IP | `UNAUTHORIZED-SSH` |
| Security | Failed-auth spike | `SSH-BRUTEFORCE` |
| Security | `authorized_keys` changed | `AUTHORIZED-KEYS-CHANGED` |
| Security | New externally-bound port | `NEW-LISTENER` |

## Design rules

- **The node is never restarted or reverted.** A node mid-resync often *looks*
  stuck while legitimately catching up; a restart there just adds downtime. The
  guard alerts and lets a human (or the node's own supervisor) decide.
- **Auto-heal is opt-in and pool-only.** With `AUTO_HEAL=1`, a *stale* control-plane
  hold is cleared **only when the node is verified healthy** (RPC up, peers ≥ floor,
  no fail-close latch), and a lease-gated pool is restarted. That's the exact
  "pool stuck down while node is fine" signature — safe to automate. Anything
  touching the node is not.
- **Detection is always safe** to run; it only reads.

## Install

```sh
git clone https://github.com/<you>/bdag-stack-guard.git
cd bdag-stack-guard
cp guard.env.example guard.env      # edit STACK_DIR, CANONICAL_RPC, SSH_ALLOWLIST, ...
./bdag-stack-guard.sh               # dry run; prints OK / ALERT

# then cron it (every 5 minutes)
( crontab -l 2>/dev/null; echo '*/5 * * * * /full/path/bdag-stack-guard.sh >/dev/null 2>&1' ) | crontab -
```

Output goes to `guard.log` (history) and `guard.status` (latest OK/ALERT).
Exit code is `0` on OK, `1` on any alert — wire that into your pager if you like.

## Verification

This repo includes stubbed smoke tests so changes can be checked without a live
mining stack or Docker daemon:

```sh
bash -n bdag-stack-guard.sh tests/smoke.sh tests/stubs/*
tests/smoke.sh
```

The smoke suite puts fake `curl`, `docker`, `ss`, and `sha256sum` binaries first
on `PATH`, then exercises healthy, RPC-down/retry, pool-down, production-stall,
automation-hold, chain-drift, and auto-heal guard-rail scenarios.

## Configuration

All settings are environment variables (see `guard.env.example`). The two that
matter most: `CANONICAL_RPC` (a trusted external reference RPC — without it the
chain-drift check is skipped) and `SSH_ALLOWLIST` (CSV of expected SSH sources —
without it the SSH tripwire is skipped). RFC1918 / loopback sources are always
treated as local.

## Caveats

- Tuned for a Dockerized BlockDAG node+pool. Container names, RPC ports, and the
  control-plane file layout are configurable but assume that shape.
- `NEW-LISTENER` re-baselines each run, so a legitimately-restarted service will
  alert once, then settle. That's intended — a one-line heads-up, not a page.
- Read the script before pointing it at production. MIT, no warranty.
