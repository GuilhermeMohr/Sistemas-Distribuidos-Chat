#!/usr/bin/env bash
# Brainiac Context — Workflow binding registrar (producer-side runtime writer)
#
# NOT a hook event. Called as the MANDATORY Step-0 by each workflow subagent,
# from inside its worktree, BEFORE any product write:
#
#   bash '<MAIN_ROOT>/.claude/hooks/brainiac/wf-register.sh' <run_id> <packet_id> <token>
#
# It writes the cwd-keyed binding that the consumer
# (lib/workflow-binding.sh -> workflow_binding) reads and validates. The subagent's
# own cwd (= the worktree) is the index key, so this script MUST run in that cwd.
#
# Why a registrar (not a SubagentStart hook): the worktree cwd is only known at
# runtime; SubagentStart's stdin cwd is unconfirmed (likely the mother's) and
# WorktreeCreate is an interception hook. The subagent's PreToolUse cwd IS the
# worktree -> self-registration is the reliable, fail-safe writer.
#
# Security: validates run_id+packet_id (safe-id) and proves authorization via a
# per-packet nonce (sha256(token) must match the seed). Only writes runtime state
# under .brainiac/; never reads a secret; the raw token is NEVER persisted.
#
# Exit codes: 0 ok (bound) / 2 any failure (caller stays unbound -> the workflow bash-gate blocks).

set -euo pipefail

# --- args ---------------------------------------------------------------------
run_id="${1:-}"
packet_id="${2:-}"
token="${3:-}"

_safe_id()    { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
_safe_token() { [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]]; }

if [[ -z "$run_id" || -z "$packet_id" || -z "$token" ]]; then
    echo "wf-register: usage: wf-register.sh <run_id> <packet_id> <token>" >&2
    exit 2
fi
_safe_id "$run_id"       || { echo "wf-register: invalid run_id" >&2; exit 2; }
_safe_id "$packet_id"    || { echo "wf-register: invalid packet_id" >&2; exit 2; }
_safe_token "$token"     || { echo "wf-register: invalid token" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "wf-register: jq required" >&2; exit 2; }

# --- paths (root via BASH_SOURCE — deterministic, no git) ----------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../.claude/hooks/brainiac
MAIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"              # brainiac -> hooks -> .claude -> root
WORKTREE_CWD="$(pwd)"                                        # the subagent worktree (index key)

bindings_dir="$MAIN_ROOT/.brainiac/workflow-bindings"
seed="$bindings_dir/seed-$run_id.json"
index="$bindings_dir/index.json"

[[ -f "$seed" ]] || { echo "wf-register: seed not found for run '$run_id'" >&2; exit 2; }

# --- sha256 (mirror dispatch.sh _sha256 / workflow-binding _wf_sha256_stdin) ---
_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 | sed 's/^.*= *//'
    else echo "NO_SHA256_TOOL"; return 1; fi
}

# --- authorization: packet must exist in seed AND token sha must match ---------
pkt="$(jq -c --arg p "$packet_id" '.packets[]? | select(.packet_id==$p)' "$seed" 2>/dev/null || true)"
[[ -n "$pkt" ]] || { echo "wf-register: packet '$packet_id' not in seed" >&2; exit 2; }
expected_sha="$(jq -r '.registration_token_sha256 // ""' <<<"$pkt")"
actual_sha="$(printf '%s' "$token" | _sha256)"
if [[ -z "$expected_sha" || "$expected_sha" != "$actual_sha" ]]; then
    echo "wf-register: registration token mismatch for packet '$packet_id'" >&2
    exit 2
fi

# --- run-level fields (from the trusted seed; token is NOT among them) ---------
scope="$(jq -r '.scope // ""' "$seed")"
intent_path="$(jq -r '.intent_path // ""' "$seed")"
plan_path="$(jq -r '.plan_path // ""' "$seed")"
payload_sha="$(jq -r '.payload_sha256 // ""' "$seed")"
refs_json="$(jq -c '.required_context_refs // []' "$seed")"

# --- lock (mkdir is atomic across processes; spin with bounded timeout) --------
lock="$bindings_dir/.lock"
mkdir -p "$bindings_dir" 2>/dev/null || true
acquired=0
for ((i = 0; i < 50; i++)); do
    if mkdir "$lock" 2>/dev/null; then acquired=1; break; fi
    sleep 0.1
done
[[ "$acquired" -eq 1 ]] || { echo "wf-register: could not acquire bindings lock" >&2; exit 2; }
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

[[ -f "$index" ]] || echo '{"bindings":[]}' > "$index"

# --- re-registration guard: same cwd may only re-register the SAME (run,packet) ---
existing="$(jq -c --arg c "$WORKTREE_CWD" '.bindings[]? | select(.cwd==$c)' "$index" 2>/dev/null || true)"
if [[ -n "$existing" ]]; then
    e_run="$(jq -r '.run_id // ""' <<<"$existing")"
    e_pkt="$(jq -r '.packet_id // ""' <<<"$existing")"
    if [[ "$e_run" != "$run_id" || "$e_pkt" != "$packet_id" ]]; then
        echo "wf-register: cwd already bound to '$e_run/$e_pkt'; refusing rebind to '$run_id/$packet_id'" >&2
        exit 2
    fi
fi

# --- atomic upsert (drop any entry for this cwd, append the validated one) -----
tmp="$index.tmp.$$"
jq \
    --arg cwd "$WORKTREE_CWD" --arg run "$run_id" --arg scope "$scope" --arg pkt "$packet_id" \
    --arg intent "$intent_path" --arg plan "$plan_path" --arg sha "$payload_sha" \
    --argjson refs "$refs_json" \
    '.bindings = ([.bindings[]? | select(.cwd != $cwd)] + [{
        cwd: $cwd, run_id: $run, scope: $scope, packet_id: $pkt,
        intent_path: $intent, plan_path: $plan, payload_sha256: $sha,
        binding_source: "workflow-export", required_context_refs: $refs
     }])' \
    "$index" > "$tmp" && mv "$tmp" "$index"

echo "wf-register: bound cwd='$WORKTREE_CWD' run='$run_id' packet='$packet_id'" >&2
exit 0
