#!/bin/bash
# Brainiac Context — Agent Envelope Guard (PreToolUse hook for Write|Edit)
# Runs SECOND in the Write|Edit chain, right after
# canonical-gate.sh and BEFORE knowledge/context-load/context-research/clean-code —
# because it is this gate that creates the lazy agent-packet binding on the FIRST
# write, which the later context/knowledge gates consult to early-exit.
#
# Governs ONLY an orchestration Specialist (a leaf spawned via the Agent tool by its Axis
# Lead, no Bash/MultiEdit/Agent, bound lazily by a bearer marker in its prompt):
#   - marker present + nonce proven vs pending-spawn + approval hash chain intact +
#     write target INSIDE the plan's allowed_paths  -> allow (exit 0)
#   - write target OUTSIDE allowed_paths / invalid nonce / payload drift / unapproved
#     envelope -> BLOCK (exit 2, fail-safe)
#   - no marker AND no existing binding -> not a governed leaf -> pass through (exit 0)
#     (normal sessions, orchestrator/axis-lead writes, etc. are handled by the rest
#     of the chain — this gate never blocks them)
#
# SEC-1: allowed_paths used for the decision are re-derived from the APPROVED PLAN
# every call (the pending-spawn / binding allowed_paths are caches). A path is never
# opened until it passes the workflow-binding safe-path guard.
#
# pipefail intentionally OFF (same rationale as context-load-gate.sh: jq + pipe +
# pipefail interaction under Git Bash MSYS2). set -u retained.

set -u

# === 1. Parse input ===
input=$(cat)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // ""')
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')
project_dir=$(printf '%s' "$input" | jq -r '.cwd // empty')
[[ -z "$project_dir" ]] && project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"

file_path_norm=$(printf '%s\n' "$file_path" | tr '\\' '/')

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === 2. Libs (fatal if missing — same discipline as the other gates) ===
for _lib in hooks-common workflow-binding agent-binding-plan agent-binding; do
    if [[ -f "$SCRIPT_DIR/lib/$_lib.sh" ]]; then
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/lib/$_lib.sh"
    else
        echo "[Brainiac Agent Envelope Guard] FATAL: lib/$_lib.sh missing — install via _install_hooks_only" >&2
        exit 2
    fi
done

LANG_VAL="${BRAINIAC_LANG:-en}"
[[ "$LANG_VAL" != "en" && "$LANG_VAL" != "pt-BR" ]] && LANG_VAL="en"
if [[ -f "$SCRIPT_DIR/messages/${LANG_VAL}.sh" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/messages/${LANG_VAL}.sh"
elif [[ -f "$SCRIPT_DIR/messages/en.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/messages/en.sh"
fi
: "${MSG_ENVELOPE_GUARD_HEADER:=[Brainiac Agent Envelope Guard]}"
: "${MSG_ENVELOPE_GUARD_BLOCK:=Bound specialist write rejected — outside allowed_paths, not write_capable in the approved plan, or invalid binding.}"

# === 3. Verdict (authoritative for GOVERNED writes) ===
# SEC-1 (adversarial review): do NOT is_allowlisted/is_outside_project early-exit here.
# Those shortcuts (used by the context gates to skip non-product files) would let a BOUND
# specialist ESCAPE its allowed_paths by writing to an allowlisted target (.env*, .github/,
# *.config.*, lockfiles, context/, CLAUDE.md) or to a path the lexical is_outside_project
# misjudges — a write outside allowed_paths must still block. For a
# governed write the binding verdict re-derives allowed_paths from the approved plan and is the
# only authority. For a NON-governed write the verdict returns "normal" → exit 0 anyway, so the
# removed shortcuts changed nothing for normal sessions (same pass-through), only closed the hole.
root=$(resolve_project_root "$project_dir")
verdict=$(agent_binding_verdict "$agent_id" "$transcript_path" "$project_dir" "$root" "$file_path_norm" "$agent_type")

case "${verdict%%$'\t'*}" in
    allow)
        echo "[brainiac][agent-envelope] bound-write-ok (run=$(printf '%s' "$verdict" | cut -f2))" >&2
        exit 0
        ;;
    block)
        reason=$(printf '%s' "$verdict" | cut -f2-)
        # Toggle: BRAINIAC_AGENT_UNBOUND=advisory downgrades ONLY the fail-close
        # reasons (materialization-race / invalid-id family) to a warning + exit 0. It NEVER
        # applies to a real enforcement block (write outside allowed_paths, NOT_WRITE_CAPABLE,
        # hash-chain drift, ambiguous / forged marker) — those stay exit 2 unconditionally.
        case "$reason" in
            SUBAGENT_TRANSCRIPT_MISSING*|SUBAGENT_MARKER_NOT_MATERIALIZED*|SUBAGENT_TRANSCRIPT_UNRESOLVED*|INVALID_AGENT_ID*)
                if [[ "${BRAINIAC_AGENT_UNBOUND:-block}" == "advisory" ]]; then
                    echo "$MSG_ENVELOPE_GUARD_HEADER advisory (BRAINIAC_AGENT_UNBOUND=advisory): $reason" >&2
                    exit 0
                fi
                ;;
        esac
        {
            echo "$MSG_ENVELOPE_GUARD_HEADER"
            echo ""
            echo "Blocking $tool_name on: $file_path"
            echo ""
            echo "$MSG_ENVELOPE_GUARD_BLOCK"
            echo "Reason: $reason"
            echo ""
            echo "A bound Specialist may only Write/Edit inside its work-packet allowed_paths"
            echo "(re-derived from the approved plan). Fix the path, the plan, or the binding."
        } >&2
        # Runtime enforcement channel: this guard is declared as a PreToolUse hook in the
        # Specialist agent def's frontmatter — the channel the runtime honors for a subagent's
        # tool calls. A `block` verdict ONLY ever arises for a governed leaf (a subagent whose
        # binding key resolved); the main session returns "normal" above and never reaches here.
        # Emit deny on stdout (permissionDecision:deny, exit 0) for every block — this covers both
        # agent_id-present and the agent_id-absent + isolated-transcript path. This is a REAL
        # enforcement block, never downgraded by the advisory toggle above. exit 2 remains a
        # fail-safe ONLY if jq cannot build the payload (never fail-open on stdout).
        deny_reason="$MSG_ENVELOPE_GUARD_HEADER $MSG_ENVELOPE_GUARD_BLOCK Reason: $reason"
        deny_json=$(jq -cn --arg r "$deny_reason" \
            '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null)
        if [[ -n "$deny_json" ]]; then
            printf '%s\n' "$deny_json"
            exit 0
        fi
        exit 2
        ;;
    *)
        # normal — not a governed leaf. Pass through to the rest of the chain.
        exit 0
        ;;
esac
