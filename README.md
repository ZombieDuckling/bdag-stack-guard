# bdag-stack-guard

Dependency-free **health, security, and attack-defense tooling** for a BlockDAG ASIC
mining stack (node + pool + rigs under Docker). It catches the failure modes that
silently halt mining, detects the **block-barrage overload attack**, and includes a
**node-recovery runbook** for bringing a crashed/corrupted node back — while never
restarting the node process itself.

Two small scripts + a runbook. Bash + `curl` + `docker`. Cron-driven. Runs on **any**
node in your fleet (point each at its local node/pool).

## Why this exists

A production mining stack went dark repeatedly, and the existing monitor reported
"all clear" the whole time. The post-incident review turned up a cluster of failure
modes that share one nasty property: **the node looks up, but nothing is mining** —
plus an active attack pattern that periodically overloads nodes across the network.

### Failure modes it was built from

- **Block-barrage / DAG-overload attack.** A peer floods a *barrage of blocks* (1000+
  imports in a single minute vs a normal ~50–100). The node's DAG RPC goes
  `503 "Too busy"`, template production stops, and mining stalls for minutes. It
  recurs. `barrage-watch.sh` detects it and attributes it to source peers over time.
- **Chain-drift blind spot.** The old monitor compared the local chain to a
  *hard-coded* block hash. When the chain moved, the node fell onto a stale fork while
  every check still said "canonical: OK." → compare against a **live** reference RPC.
- **Node fail-close recovery latch.** A recovery/fork-guard binary trips its own
  durable "clean-resync latch" and comes up status-only — a restart just re-selects it.
- **Production stall / pool-down / stale automation hold.** Node healthy, pool up, zero
  blocks; or the pool stopped by a control-plane hold long after the node recovered.
- **Corrupted execution DB.** After a powercut or a barrage-induced crash, the node
  crash-loops on `EVM database has genesis full-block head during startup repair
  rewind while advanced chain data exists`. → see the **Node recovery** runbook below.

Plus security tripwires: SSH from an unexpected source, brute-force spikes, new
`authorized_keys`, new externally-bound listeners.

## Components

| File | Cron | Role |
|------|------|------|
| `bdag-stack-guard.sh` | `*/5` | Health + security guard. Live chain-drift, node-RPC-down, peer starvation, fail-close latch, production stall, pool-down, automation-hold, image swap, config clobber, SSH/listener tripwires. Opt-in **pool-only auto-heal**. |
| `barrage-watch.sh` | `*/2` | Block-barrage / DAG-overload **attack detector + peer attribution**. Flags import bursts and `503 Too busy` spikes; logs each event and tallies source IPs so a repeat flooder surfaces over time. |

## The block-barrage detector

The attack: a peer sends a flood of blocks → the DAG engine saturates → `503 Too busy`
→ no templates → mining stalls, network-wide. `barrage-watch.sh` runs every 2 minutes:

- Flags a **barrage** when block-imports exceed a threshold (default 600 / 2 min) or
  `503 Too busy` errors exceed a threshold (default 15 / 2 min) in the window.
- On detection, records the event and the **top block-source IPs** to
  `barrage-events.log`, and increments a cumulative per-IP tally in
  `barrage-offenders.tsv`.

**Attribution is over time, not from one event.** During a barrage the top "sources"
are just the node's normal sync peers (the node pulls catch-up blocks *from* its best
peers). The signal you want is a peer that shows up **only during crashes** and not in
normal operation — *that* is the flooder to block (e.g. `iptables -A INPUT -s <ip> -j
DROP`). Do **not** block your normal sync peers. Every barrage observed so far
self-resolved once the node caught up — **do not restart the node for this.**

## Node recovery runbook (crashed / corrupted DB)

When a node crash-loops on `EVM database has genesis full-block head during startup
repair rewind while advanced chain data exists ... restore a canonical snapshot`, its
execution DB is corrupt (common after a powercut or a barrage-induced hard crash). The
node **correctly refuses** a destructive rewind. Recover it from a canonical snapshot:

1. Stop the stack boot service and confirm containers are down.
2. Back up the corrupt chain-data dir: `mv <datadir>/mainnet <datadir>/mainnet.corrupt-<date>`.
3. Restore a **verified** canonical dataset snapshot (archive top-level = `mainnet/`):
   `zstd -dc --long=27 <snapshot>.tar.zst | tar -xf - -C <datadir>/`.
4. Fix ownership to the node's runtime uid/gid: `chown -R <uid>:<gid> <datadir>/mainnet`.
5. Clear any automation-control hold back to `normal`.
6. Start `postgres`, then `node`, then `pool`.
7. **Peer gotcha:** if the node comes up with **0 peers** (its configured seeds are
   dead/on another chain), reseed live peers — e.g. copy the pre-crash
   `recent-peers.json` from the backup into the fresh dataset dir and restart the node.
   Verify it's tracking canonical by comparing its head hash to a live reference RPC.

The node then boots on the snapshot and syncs forward on the canonical chain. **Verify
same-chain** by comparing block hashes at a common height against your reference RPC —
identical hash = same chain.

## Install (each node)

```sh
git clone https://github.com/<you>/bdag-stack-guard.git
cd bdag-stack-guard
cp guard.env.example guard.env      # edit STACK_DIR, CANONICAL_RPC, SSH_ALLOWLIST, ...
./bdag-stack-guard.sh               # dry run
( crontab -l 2>/dev/null; \
  echo '*/5 * * * * /full/path/bdag-stack-guard.sh  >/dev/null 2>&1'; \
  echo '*/2 * * * * /full/path/barrage-watch.sh     >/dev/null 2>&1' ) | crontab -
```

`bdag-stack-guard.sh` writes `guard.log` / `guard.status`; `barrage-watch.sh` writes
`barrage-events.log` / `barrage-offenders.tsv` / `barrage.status`. Both exit `1` on a
detection so you can wire them to a pager.

## Design rules

- **The node is never restarted or reverted.** DAG overload / sync lag / fail-close are
  wait-or-recover conditions; a restart just adds downtime and can abort a self-heal.
- **Auto-heal is opt-in and pool-only** (`AUTO_HEAL=1`), and only when the node is
  verified healthy. Anything touching the node is manual.
- **Detection is always safe** — it only reads. Blocking a peer is a deliberate human
  call backed by the offender tally, never automatic.

MIT, no warranty. Read the scripts before pointing them at production.
