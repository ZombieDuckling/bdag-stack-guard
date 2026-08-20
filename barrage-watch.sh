#!/bin/bash
# barrage-watch.sh — detects the block-barrage / DAG-overload attack that halts mining,
# and attributes it to source peers so a repeat offender surfaces over time.
#
# The attack: a peer floods a barrage of blocks -> the node's DAG RPC goes "503 Too busy"
# -> no templates -> mining stalls. Normal graph-state churn is ~50-100/min; a barrage is
# 1000+ block-imports in a single minute, alongside a burst of DAG "503 Too busy" errors.
#
# Run every ~2 min via cron. Findings go to barrage-events.log; a cumulative per-IP
# offender tally is kept in barrage-offenders.tsv (the peer to consider blocking if it
# repeats). This NEVER touches the node — detection + attribution only.
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_CONTAINER="${NODE_CONTAINER:-node}"
WINDOW_MIN="${WINDOW_MIN:-2}"           # minutes of log to scan each run
IMPORT_BARRAGE="${IMPORT_BARRAGE:-600}" # >this many block-imports in the window = barrage
DAG503_ALERT="${DAG503_ALERT:-15}"      # >this many "503 Too busy" in the window = crash active
EVLOG="$DIR/barrage-events.log"
OFFENDERS="$DIR/barrage-offenders.tsv"
STATUS="$DIR/barrage.status"
now(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }

LOGS=$(docker logs --since ${WINDOW_MIN}m "$NODE_CONTAINER" 2>&1)
IMPORTS=$(printf '%s\n' "$LOGS" | grep -c 'Imported new chain segment')
DAG503=$(printf '%s\n' "$LOGS" | grep -c '503 Too busy')

if [ "${IMPORTS:-0}" -gt "$IMPORT_BARRAGE" ] || [ "${DAG503:-0}" -gt "$DAG503_ALERT" ]; then
  # BARRAGE / CRASH event — attribute to source peers (IPs feeding blocks/reorgs)
  TOPIP=$(printf '%s\n' "$LOGS" | grep -oE 'sourceAddress=/ip4/[0-9.]+' | sed 's#.*/##' | sort | uniq -c | sort -rn | head -5)
  TOP1=$(printf '%s\n' "$TOPIP" | awk 'NR==1{print $2}')
  {
    echo "$(now) BARRAGE imports=${IMPORTS} dag503=${DAG503} (window=${WINDOW_MIN}m)"
    echo "  top block-source IPs this event:"
    printf '%s\n' "$TOPIP" | sed 's/^/    /'
  } | tee -a "$EVLOG"
  # cumulative offender tally (IP <tab> count) — a persistent repeat source is the attacker
  if [ -n "$TOP1" ]; then
    touch "$OFFENDERS"
    awk -v ip="$TOP1" 'BEGIN{f=0} $1==ip{$2++;f=1} {print} END{if(!f)print ip"\t1"}' "$OFFENDERS" 2>/dev/null | sort -k2 -rn > "$OFFENDERS.tmp" && mv "$OFFENDERS.tmp" "$OFFENDERS"
  fi
  echo "$(now) BARRAGE-DETECTED imports=${IMPORTS} dag503=${DAG503} top_source=${TOP1:-unknown}" > "$STATUS"
  # surface the current top cumulative offender
  LEAD=$(sort -k2 -rn "$OFFENDERS" 2>/dev/null | head -1)
  [ -n "$LEAD" ] && echo "  cumulative top offender: $LEAD" | tee -a "$EVLOG"
  exit 1
else
  echo "$(now) OK imports=${IMPORTS} dag503=${DAG503}" > "$STATUS"
fi
