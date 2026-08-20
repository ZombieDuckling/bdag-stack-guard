#!/bin/bash
# bdag-stack-guard.sh — health + security watchdog for a BlockDAG ASIC mining stack.
#
# Detects (and optionally auto-heals) the failure modes that silently halt mining:
#   HEALTH   live chain-drift vs a canonical reference (NO hard-coded hash),
#            node-RPC-down, peer starvation, node fail-close recovery latch,
#            production stall (0 blocks), pool container down, automation-hold
#   CHANGE   node image swap, canonicalprotection config clobber
#   SECURITY SSH from a non-allowlisted source, brute-force spikes,
#            new authorized_keys, new externally-bound listeners
#
# Alerts to guard.log + guard.status. With AUTO_HEAL=1 it will clear a *stale*
# automation hold (only when the node is verified healthy) and restart a
# lease-gated pool — it will NEVER restart or revert the node (that can abort an
# in-flight self-heal). Detection is always safe; remediation is opt-in.
#
# Config: copy guard.env.example -> guard.env and edit, or export the vars below.
# Install: */5 * * * *  /path/to/bdag-stack-guard.sh >/dev/null 2>&1
#
# License: MIT.  No warranty. Read it before running it against production.

set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$DIR/guard.env" ] && . "$DIR/guard.env"

# ---- configuration (env-overridable; safe placeholder defaults) --------------
STACK_DIR="${STACK_DIR:-/opt/blockdag-stack}"          # dir containing node.conf + ops/runtime
NODE_CONF="${NODE_CONF:-$STACK_DIR/node.conf}"
RUNTIME_DIR="${RUNTIME_DIR:-$STACK_DIR/ops/runtime}"
AUTOMATION_JSON="${AUTOMATION_JSON:-$RUNTIME_DIR/automation-control.json}"
EVM_RPC="${EVM_RPC:-http://127.0.0.1:18545}"           # local node EVM JSON-RPC
CANONICAL_RPC="${CANONICAL_RPC:-}"                     # trusted external reference RPC (REQUIRED for drift check)
NODE_CONTAINER="${NODE_CONTAINER:-node}"
POOL_MATCH="${POOL_MATCH:-^pool}"                      # regex to find the running pool container
MIN_PEERS="${MIN_PEERS:-2}"
STALL_MIN="${STALL_MIN:-8}"                            # minutes of 0 submits = stall
MAX_LAG="${MAX_LAG:-5000}"                             # blocks behind canonical before alerting
SSH_ALLOWLIST="${SSH_ALLOWLIST:-}"                     # CSV of expected SSH source IPs (e.g. 10.0.0.5,10.0.0.6)
AUTH_LOG="${AUTH_LOG:-/var/log/auth.log}"
LEASE_REFRESH_CMD="${LEASE_REFRESH_CMD:-}"            # optional: command that mints/refreshes the pool start-lease
AUTO_HEAL="${AUTO_HEAL:-0}"                            # 1 = clear stale holds + restart pool (node is never touched)

LOG="$DIR/guard.log"; STATUS="$DIR/guard.status"; STATE="$DIR/.guard_state"
now(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }
ALERTS=(); HEALS=(); alert(){ ALERTS+=("$1"); }; healed(){ HEALS+=("$1"); }
rpc(){ curl -s --max-time 6 -X POST -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":${2:-[]},\"id\":1}" "$3" 2>/dev/null; }
hexdec(){ local h="${1#0x}"; [ -n "$h" ] && printf '%d' "$((16#$h))" 2>/dev/null || echo ""; }
acstate(){ grep -oE '"state"[[:space:]]*:[[:space:]]*"[a-z_]+"' "$AUTOMATION_JSON" 2>/dev/null | grep -oE '[a-z_]+"$' | tr -d '"' | head -1; }

mkdir -p "$DIR"; touch "$STATE"; . "$STATE" 2>/dev/null

# ---- HEALTH ------------------------------------------------------------------
# Retry the liveness probe: a real outage fails every attempt; a transient
# (a single slow/busy RPC response) clears on retry and must not page.
LHEAD=""
for _try in 1 2 3; do
  LHEAD=$(hexdec "$(rpc eth_blockNumber '[]' "$EVM_RPC" | grep -oE '0x[0-9a-f]+')")
  [ -n "$LHEAD" ] && break
  sleep 2
done
if [ -z "$LHEAD" ]; then
  alert "NODE-RPC-DOWN: no eth_blockNumber from $EVM_RPC after 3 tries (node EVM engine not serving)"
else
  PEERS=$(hexdec "$(rpc net_peerCount '[]' "$EVM_RPC" | grep -oE '0x[0-9a-f]+')")
  [ -n "$PEERS" ] && [ "$PEERS" -lt "$MIN_PEERS" ] && alert "PEER-STARVATION: $PEERS peers (< $MIN_PEERS)"
  if [ -n "$CANONICAL_RPC" ]; then
    EHEAD=$(hexdec "$(rpc eth_blockNumber '[]' "$CANONICAL_RPC" | grep -oE '0x[0-9a-f]+')")
    if [ -n "$EHEAD" ]; then
      CMP=$(( (LHEAD<EHEAD?LHEAD:EHEAD) - 64 ))
      if [ "$CMP" -gt 0 ]; then
        CH=$(printf '0x%x' "$CMP")
        LHH=$(rpc eth_getBlockByNumber "[\"$CH\",false]" "$EVM_RPC" | grep -oE '"hash":"0x[0-9a-f]+"' | head -1)
        EHH=$(rpc eth_getBlockByNumber "[\"$CH\",false]" "$CANONICAL_RPC" | grep -oE '"hash":"0x[0-9a-f]+"' | head -1)
        [ -n "$LHH" ] && [ -n "$EHH" ] && [ "$LHH" != "$EHH" ] && \
          alert "CHAIN-DRIFT: local != canonical @${CMP} (local=$LHH ref=$EHH) — node OFF canonical / fork"
      fi
      [ $((EHEAD - LHEAD)) -gt "$MAX_LAG" ] && alert "NODE-LAGGING: $((EHEAD-LHEAD)) blocks behind canonical"
    fi
  fi
fi

# node fail-close recovery latch
if docker logs --since 5m "$NODE_CONTAINER" 2>&1 | grep -qiE 'clean-resync latch|Recovery-required owner status'; then
  alert "FAIL-CLOSE-LATCH: node in recovery/clean-resync latch (status-only, not mining)"
fi

# pool container + production stall + automation hold
POOL_CT=$(docker ps --format '{{.Names}}' | grep -iE "$POOL_MATCH" | head -1)
if [ -z "$POOL_CT" ]; then
  alert "POOL-DOWN: no running pool container (matched '$POOL_MATCH')"
else
  SUBMITS=$(docker logs --since ${STALL_MIN}m "$POOL_CT" 2>&1 | grep -icE 'block submitted successfully|block accepted')
  [ "${SUBMITS:-0}" -eq 0 ] && alert "PRODUCTION-STALL: 0 blocks submitted in ${STALL_MIN}m"
fi
ACSTATE=$(acstate)
[ -n "$ACSTATE" ] && [ "$ACSTATE" != "normal" ] && \
  alert "AUTOMATION-HOLD: control state='$ACSTATE' (blocks pool start)"

# ---- OPT-IN AUTO-HEAL (pool only; node is never touched) ---------------------
# Only heals when the node is provably healthy: RPC up AND peers>=MIN_PEERS AND
# no fail-close latch. A stale hold + healthy node is the exact 'pool stuck down'
# signature this project was built for.
if [ "$AUTO_HEAL" = "1" ] && [ -n "$LHEAD" ] && [ "${PEERS:-0}" -ge "$MIN_PEERS" ] \
   && ! docker logs --since 5m "$NODE_CONTAINER" 2>&1 | grep -qiE 'clean-resync latch|Recovery-required owner status'; then
  if [ -n "$ACSTATE" ] && [ "$ACSTATE" != "normal" ] && [ -x "$STACK_DIR/ops/automation_control.py" ]; then
    python3 "$STACK_DIR/ops/automation_control.py" set-state --state normal \
      --owner bdag-stack-guard --owner-unit auto-heal --reason "stale $ACSTATE cleared: node healthy" \
      --state-path "$AUTOMATION_JSON" --lock-path "$RUNTIME_DIR/automation-control.lock" \
      --event-path "$RUNTIME_DIR/automation-control-events.jsonl" >/dev/null 2>&1 && healed "cleared stale hold '$ACSTATE'"
  fi
  if [ -z "$POOL_CT" ]; then
    [ -n "$LEASE_REFRESH_CMD" ] && eval "$LEASE_REFRESH_CMD" >/dev/null 2>&1
    STOPPED=$(docker ps -a --format '{{.Names}}' | grep -iE "$POOL_MATCH" | head -1)
    [ -n "$STOPPED" ] && docker start "$STOPPED" >/dev/null 2>&1 && healed "restarted pool '$STOPPED'"
  fi
fi

# ---- CHANGE DETECTION --------------------------------------------------------
CUR_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$NODE_CONTAINER" 2>/dev/null)
[ -n "$PREV_IMAGE" ] && [ "$CUR_IMAGE" != "$PREV_IMAGE" ] && \
  alert "NODE-IMAGE-SWAP: $PREV_IMAGE -> $CUR_IMAGE (verify chain+peers before trusting; do NOT reflex-revert)"
CANON=$(grep -c '^canonicalprotection' "$NODE_CONF" 2>/dev/null)
[ "${CANON:-0}" -gt 0 ] && alert "CANONICALPROTECTION-CLOBBER: $CANON line(s) in node.conf"

# ---- SECURITY TRIPWIRES ------------------------------------------------------
if [ -r "$AUTH_LOG" ] && [ -n "$SSH_ALLOWLIST" ]; then
  BAD=$(grep -aE 'sshd.*Accepted' "$AUTH_LOG" 2>/dev/null | grep "$(date -u +%Y-%m-%d)" \
        | grep -oE 'from [0-9.]+' | awk '{print $2}' | sort -u \
        | grep -vE "^(${SSH_ALLOWLIST//,/|})$" | grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)')
  [ -n "$BAD" ] && alert "UNAUTHORIZED-SSH: accepted login from $(echo "$BAD" | tr '\n' ' ')"
  FAILS=$(grep -aE 'sshd.*(Failed|Invalid user)' "$AUTH_LOG" 2>/dev/null | tail -200 | grep "$(date -u +%Y-%m-%d)" | wc -l)
  [ "${FAILS:-0}" -gt 20 ] && alert "SSH-BRUTEFORCE: ${FAILS} recent failed attempts"
fi
KEYS_HASH=$(sha256sum ~/.ssh/authorized_keys 2>/dev/null | awk '{print $1}')
[ -n "$PREV_KEYS_HASH" ] && [ "$KEYS_HASH" != "$PREV_KEYS_HASH" ] && \
  alert "AUTHORIZED-KEYS-CHANGED: ~/.ssh/authorized_keys modified"
LISTENERS=$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '127\.0\.0|::1' | sed 's/.*://' | sort -un | tr '\n' ',')
if [ -n "$PREV_LISTENERS" ] && [ "$LISTENERS" != "$PREV_LISTENERS" ]; then
  NEWP=$(comm -13 <(echo "$PREV_LISTENERS" | tr ',' '\n' | sort -u) <(echo "$LISTENERS" | tr ',' '\n' | sort -u) | grep -E '^[0-9]+$' | tr '\n' ' ')
  [ -n "$NEWP" ] && alert "NEW-LISTENER: new externally-bound port(s): $NEWP"
fi

cat > "$STATE" <<EOF
PREV_IMAGE='$CUR_IMAGE'
PREV_KEYS_HASH='$KEYS_HASH'
PREV_LISTENERS='$LISTENERS'
EOF

# ---- REPORT ------------------------------------------------------------------
for h in "${HEALS[@]}"; do echo "$(now) HEAL: $h" | tee -a "$LOG"; done
if [ ${#ALERTS[@]} -eq 0 ]; then
  echo "$(now) OK head=${LHEAD:-?} peers=${PEERS:-?} submits/${STALL_MIN}m=${SUBMITS:-?} state=${ACSTATE:-?}" >> "$LOG"
  echo "$(now) OK" > "$STATUS"
else
  { echo "$(now) ALERT (${#ALERTS[@]}):"; for a in "${ALERTS[@]}"; do echo "  !! $a"; done; } | tee -a "$LOG"
  { echo "$(now) ALERT"; for a in "${ALERTS[@]}"; do echo "  !! $a"; done; } > "$STATUS"
  exit 1
fi
