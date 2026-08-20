#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB_DIR="$ROOT/tests/stubs"
SCRIPT="$ROOT/bdag-stack-guard.sh"
PASS=0

chmod +x "$STUB_DIR"/*

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq "$expected" "$file" || {
    printf '--- %s ---\n' "$file" >&2
    cat "$file" >&2 || true
    fail "expected to find: $expected"
  }
}

run_case() {
  local name="$1" expected_exit="$2"
  shift 2
  local tmp stack runtime home authlog startlog curlcount exit_code
  tmp="$(mktemp -d)"
  stack="$tmp/stack"
  runtime="$stack/ops/runtime"
  home="$tmp/home"
  authlog="$tmp/auth.log"
  startlog="$tmp/docker-start.log"
  curlcount="$tmp/curl-count"
  mkdir -p "$runtime" "$home/.ssh"
  : > "$authlog"
  : > "$home/.ssh/authorized_keys"
  printf '{"state":"normal"}\n' > "$runtime/automation-control.json"
  cp "$SCRIPT" "$tmp/bdag-stack-guard.sh"
  chmod +x "$tmp/bdag-stack-guard.sh"

  set +e
  (
    cd "$tmp" || exit 99
    env \
      PATH="$STUB_DIR:$PATH" \
      HOME="$home" \
      STACK_DIR="$stack" \
      RUNTIME_DIR="$runtime" \
      AUTOMATION_JSON="$runtime/automation-control.json" \
      AUTH_LOG="$authlog" \
      CANONICAL_RPC="http://canonical.example/rpc" \
      EVM_RPC="http://local.example/rpc" \
      STUB_CURL_COUNT_FILE="$curlcount" \
      STUB_DOCKER_START_LOG="$startlog" \
      "$@" \
      ./bdag-stack-guard.sh >/tmp/bdag-stack-guard-case.out 2>&1
  )
  exit_code=$?
  set -e

  [[ "$exit_code" == "$expected_exit" ]] || {
    cat /tmp/bdag-stack-guard-case.out >&2 || true
    cat "$tmp/guard.status" >&2 || true
    fail "$name: expected exit $expected_exit, got $exit_code"
  }

  CASE_DIR="$tmp"
  CASE_START_LOG="$startlog"
  CASE_CURL_COUNT="$curlcount"
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "$PASS" "$name"
}

run_case healthy 0
assert_contains "$CASE_DIR/guard.status" "OK"

run_case rpc-down-retries 1 STUB_RPC_DOWN=1
assert_contains "$CASE_DIR/guard.status" "NODE-RPC-DOWN"
[[ "$(cat "$CASE_CURL_COUNT")" -ge 3 ]] || fail "expected at least 3 curl attempts for RPC down"

run_case pool-down 1 STUB_POOL_DOWN=1
assert_contains "$CASE_DIR/guard.status" "POOL-DOWN"

run_case production-stall 1 STUB_POOL_SUBMITS=0
assert_contains "$CASE_DIR/guard.status" "PRODUCTION-STALL"

# Explicit setup for this fixture because the scenario requires a non-normal
# automation-control.json before the guard starts.
tmp="$(mktemp -d)"
stack="$tmp/stack"; runtime="$stack/ops/runtime"; home="$tmp/home"; authlog="$tmp/auth.log"
mkdir -p "$runtime" "$home/.ssh"
: > "$authlog"; : > "$home/.ssh/authorized_keys"
printf '{"state":"repair_hold"}\n' > "$runtime/automation-control.json"
cp "$SCRIPT" "$tmp/bdag-stack-guard.sh"; chmod +x "$tmp/bdag-stack-guard.sh"
set +e
(cd "$tmp" && env PATH="$STUB_DIR:$PATH" HOME="$home" STACK_DIR="$stack" RUNTIME_DIR="$runtime" AUTOMATION_JSON="$runtime/automation-control.json" AUTH_LOG="$authlog" CANONICAL_RPC="http://canonical.example/rpc" EVM_RPC="http://local.example/rpc" ./bdag-stack-guard.sh >/tmp/bdag-stack-guard-case.out 2>&1)
exit_code=$?
set -e
[[ "$exit_code" == 1 ]] || fail "automation-hold: expected exit 1, got $exit_code"
assert_contains "$tmp/guard.status" "AUTOMATION-HOLD"
PASS=$((PASS + 1)); printf 'ok %d - automation-hold\n' "$PASS"

run_case chain-drift 1 STUB_LOCAL_HASH=0x111111 STUB_CANONICAL_HASH=0x222222
assert_contains "$CASE_DIR/guard.status" "CHAIN-DRIFT"

run_case auto-heal-does-not-run-when-node-unhealthy 1 AUTO_HEAL=1 STUB_RPC_DOWN=1 STUB_POOL_DOWN=1 STUB_STOPPED_POOL=pool-main
assert_contains "$CASE_DIR/guard.status" "NODE-RPC-DOWN"
[[ ! -s "$CASE_START_LOG" ]] || fail "docker start was called even though node was unhealthy"

printf 'smoke: %d scenarios passed\n' "$PASS"
