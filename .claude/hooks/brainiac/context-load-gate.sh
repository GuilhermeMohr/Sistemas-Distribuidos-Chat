#!/bin/bash
# Brainiac Context — Minimum Context Gate (PreToolUse hook for Write|Edit)
#
# Blocks product-code edits unless the minimum Brainiac context package has
# been loaded in the current session:
#
#   - context/intent/project-intent.md
#   - context/intent/(feature|bug|refactor)-<slug>.md  (active task intent)
#   - context/code-standards.md
#   - context/security-standards.md
#   - context/sensors/sensors.md  (when file exists)
#
# Order of operation:
#   1. Parse input
#   2. Settings-guard: BLOCK if .claude/settings.json (versioned) has
#      BRAINIAC_CONTEXT_GATE_BYPASS=true  (anti-pattern enforcement)
#   3. Allowlist check (path-based, no generic *.md)
#   4. Bypass check (env var + reason >= 12 visible chars)
#   5. Compute session_hash + active_intent_path
#   6. Cache check (transcript + active intent identity)
#   7. Extract loaded paths from transcript
#   8. Validate minimum package
#   9/10. Pass (cache success) or block (exit 2 + stderr i18n)
#
# Bypass is auditable via append-only NDJSON log in
# context/evolution/context-load-gate-bypasses.log (auto-created).
#
# NB: pipefail INTENTIONALLY OFF. With pipefail enabled in
# Git Bash MSYS2 (Windows), the active_intent_path() jq Source B silently
# produced empty output when invoked via function command-substitution
# `current_active=$(active_intent_path)`. Standalone subshell with same code
# worked. Root cause unclear (likely jq + pipe + pipefail interaction), but
# disabling pipefail fixes it. set -u retained for unset-variable catch.

set -u

# === 1. Parse input ===
input=$(cat)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // ""')
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
project_dir=$(printf '%s' "$input" | jq -r '.cwd // empty')

[[ -z "$project_dir" ]] && project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"

file_path_norm=$(printf '%s\n' "$file_path" | tr '\\' '/')
project_dir_norm=$(printf '%s\n' "$project_dir" | tr '\\' '/')

# === Helper: i18n loading + shared helpers lib ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared helpers: compute_sha256, is_allowlisted,
# active_intent_path, loaded_paths, user_text, is_loaded.
# Lib has no top-level code — safe to source without side effects.
#
# Fatal if lib is missing: um source silencioso quebraria em runtime na primeira
# chamada de helper; alinhado com context-research-gate.sh (também fatal).
if [[ -f "$SCRIPT_DIR/lib/hooks-common.sh" ]]; then
    # shellcheck source=lib/hooks-common.sh
    source "$SCRIPT_DIR/lib/hooks-common.sh"
else
    echo "[Brainiac Minimum Context Gate] FATAL: lib/hooks-common.sh missing — install via _install_hooks_only" >&2
    exit 2
fi

# Workflow-aware helpers. MUST be sourced AFTER hooks-common.sh
# (depends on _normalize_drive_letter). Provides the never-inherit binding logic.
if [[ -f "$SCRIPT_DIR/lib/workflow-binding.sh" ]]; then
    # shellcheck source=lib/workflow-binding.sh
    source "$SCRIPT_DIR/lib/workflow-binding.sh"
else
    echo "[Brainiac Minimum Context Gate] FATAL: lib/workflow-binding.sh missing — install via _install_hooks_only" >&2
    exit 2
fi

# Agent-packet PLAN-derivation layer (split keeps agent-binding.sh under the
# 500-line gate). AFTER workflow-binding, BEFORE agent-binding (the verdict +
# bound helpers call ab_validate_chain / ab_plan_packet_*).
if [[ -f "$SCRIPT_DIR/lib/agent-binding-plan.sh" ]]; then
    # shellcheck source=lib/agent-binding-plan.sh
    source "$SCRIPT_DIR/lib/agent-binding-plan.sh"
fi

# Agent-packet binding helpers. An orchestration Specialist bound by the
# envelope-guard (which runs FIRST in the chain) writes within allowed_paths re-derived
# from the approved plan — its own transcript has no minimum package, so this gate must
# early-exit for a valid bound write. Soft-source: absence => no early-exit (gate applies).
if [[ -f "$SCRIPT_DIR/lib/agent-binding.sh" ]]; then
    # shellcheck source=lib/agent-binding.sh
    source "$SCRIPT_DIR/lib/agent-binding.sh"
fi

LANG_VAL="${BRAINIAC_LANG:-en}"
[[ "$LANG_VAL" != "en" && "$LANG_VAL" != "pt-BR" ]] && LANG_VAL="en"
if [[ -f "$SCRIPT_DIR/messages/${LANG_VAL}.sh" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/messages/${LANG_VAL}.sh"
elif [[ -f "$SCRIPT_DIR/messages/en.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/messages/en.sh"
fi

# Fallback strings if messages/ absent
: "${MSG_GATE_BLOCK_HEADER:=[Brainiac Minimum Context Gate]}"
: "${MSG_GATE_VERSIONED_FATAL:=Bypass via .claude/settings.json (versioned) is forbidden. Use shell env or .claude/settings.local.json.}"
: "${MSG_GATE_BYPASS_NO_REASON:=Bypass requires a reason of at least 12 visible characters in BRAINIAC_CONTEXT_GATE_BYPASS_REASON.}"
: "${MSG_GATE_BYPASS_NOTICE:=Brainiac Minimum Context Gate bypass recorded.}"
: "${MSG_GATE_MISSING_INTENT:=Active task intent missing (context/intent/feature|bug|refactor-*.md).}"
: "${MSG_GATE_MISSING_STANDARDS:=Code/security standards not loaded.}"
: "${MSG_GATE_MISSING_SENSORS:=Sensors not loaded but context/sensors/sensors.md exists.}"
: "${MSG_GATE_UNLOCK:=Load required artifacts: project-intent + active intent + code-standards + security-standards + sensors (if present).}"

# NB: compute_sha256 vem do lib/hooks-common.sh. Sem fallback inline —
# caso lib esteja ausente, hook depende dela. install.sh garante.

# === 2. Settings-guard: versionada com BYPASS=true == fatal ===
settings_path="$project_dir/.claude/settings.json"
if [[ -f "$settings_path" ]]; then
    versioned_bypass=$(jq -r '.env.BRAINIAC_CONTEXT_GATE_BYPASS // "false"' "$settings_path" 2>/dev/null)
    if [[ "$versioned_bypass" == "true" ]]; then
        cat >&2 <<EOF
$MSG_GATE_BLOCK_HEADER

$MSG_GATE_VERSIONED_FATAL

File: .claude/settings.json
Edit attempted on: $file_path

Accepted bypass sources:
  - Shell env: export BRAINIAC_CONTEXT_GATE_BYPASS=true
  - .claude/settings.local.json (not versioned by Claude Code default)
EOF
        exit 2
    fi
fi

# === 3. Allowlist (is_allowlisted vem do lib/hooks-common.sh) ===
is_allowlisted "$file_path_norm" && exit 0

# === 3.5. Scope guard: edits fora do project não disparam gate ===
# Plan files (~/.claude/plans/), auto-memory (~/.claude/projects/<>/memory/)
# e edits cross-project são layer pessoal/meta — gate só aplica em product code.
is_outside_project "$file_path_norm" "$project_dir_norm" && exit 0

# === 4. Bypass check (APÓS allowlist) ===
if [[ "${BRAINIAC_CONTEXT_GATE_BYPASS:-false}" == "true" ]]; then
    reason_raw="${BRAINIAC_CONTEXT_GATE_BYPASS_REASON:-}"
    reason_visible=$(printf '%s\n' "$reason_raw" | tr -d '[:space:]')
    if [[ ${#reason_visible} -lt 12 ]]; then
        cat >&2 <<EOF
$MSG_GATE_BLOCK_HEADER

$MSG_GATE_BYPASS_NO_REASON

Edit attempted on: $file_path
EOF
        exit 2
    fi

    log_dir="$project_dir/context/evolution"
    log_file="$log_dir/context-load-gate-bypasses.log"
    if [[ ! -d "$log_dir" ]]; then
        if ! mkdir -p "$log_dir" 2>/dev/null; then
            log_file="/tmp/brainiac-bypass-fallback.log"
            echo "[Brainiac Gate] context/evolution/ missing — fallback log: $log_file" >&2
        fi
    fi

    ts=$(date +'%Y-%m-%dT%H:%M:%S%z')
    sess_hash=$(compute_sha256 "$transcript_path")
    [[ -z "$sess_hash" ]] && sess_hash="unknown"
    # Escape double quotes in reason for JSON safety
    reason_json=$(printf '%s\n' "$reason_raw" | sed 's/"/\\"/g')
    printf '{"ts":"%s","tool":"%s","file":"%s","reason":"%s","session_hash":"%s","user":"%s"}\n' \
        "$ts" "$tool_name" "$file_path" "$reason_json" "$sess_hash" "${USER:-unknown}" >> "$log_file"
    echo "[Brainiac Gate] $MSG_GATE_BYPASS_NOTICE ($log_file)" >&2
    exit 0
fi

# === 4.5. Workflow-aware ===
# A native Dynamic Workflow subagent inherits the MOTHER session's transcript, so
# active_intent_path() below would leak the mother's intent. Never inherit: in a
# workflow subagent the active intent comes ONLY from a validated binding; with no
# valid binding a product-code write is blocked (BRAINIAC_WORKFLOW_CONTEXT_REQUIRED).
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')
wf_root=$(resolve_project_root "$project_dir")
wf_verdict=$(workflow_binding_verdict "$agent_type" "$project_dir" "$transcript_path" "$wf_root")
case "${wf_verdict%%$'\t'*}" in
    bound)
        # Validated binding confirms the active intent + the full minimum package
        # (project-intent + standards via required_context_refs). Pass.
        echo "[brainiac][context-source] workflow-bound (run=$(printf '%s' "$wf_verdict" | cut -f3))" >&2
        exit 0
        ;;
    unbound)
        emit_workflow_unbound "$MSG_GATE_BLOCK_HEADER" "$file_path"
        ;;
    *)
        echo "[brainiac][context-source] main-transcript" >&2
        ;;
esac

# === 4.6. Agent-packet bound write ===
# A Specialist bound by the envelope-guard (chain runs it first) writing inside its
# plan-derived allowed_paths is authorized — its minimum context is the approved plan,
# not this transcript. Early-exit. Any invalid binding was already blocked upstream by
# the envelope-guard; here a non-bound write simply falls through to the normal check.
if declare -f agent_bound_in_allowed >/dev/null 2>&1; then
    ab_agent_id=$(printf '%s' "$input" | jq -r '.agent_id // ""')
    if ab_run=$(agent_bound_in_allowed "$ab_agent_id" "$transcript_path" "$project_dir" "${wf_root:-$project_dir}" "$file_path_norm"); then
        echo "[brainiac][context-source] agent-bound (run=$ab_run)" >&2
        exit 0
    fi
fi

# === 5. Compute session_hash + active_intent_path ===
session_hash=$(compute_sha256 "$transcript_path")
[[ -z "$session_hash" ]] && session_hash="unknown"

# active_intent_path vem do lib/hooks-common.sh.
# Recebe transcript_path como argumento (nunca variável global implícita).
current_active=$(active_intent_path "$transcript_path")

# === 6. Cache check ===
cache_file="/tmp/brainiac-load-gate-${session_hash}.json"
if [[ -f "$cache_file" ]]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
    cache_age=$(( $(date +%s) - cache_mtime ))
    cache_session=$(jq -r '.session_hash // ""' "$cache_file" 2>/dev/null)
    cache_intent=$(jq -r '.active_intent_path // ""' "$cache_file" 2>/dev/null)
    if [[ "$cache_session" == "$session_hash" && "$cache_intent" == "$current_active" && "$cache_age" -lt 3600 ]]; then
        exit 0
    fi
fi

# === 7. Extract loaded evidence (loaded_paths/user_text/is_loaded vêm do lib/hooks-common.sh) ===
# is_loaded recebe transcript_path como 2º argumento (nunca variável global implícita).

# === 8. Validate minimum package ===
missing=()

is_loaded 'context/intent/project-intent\.md$' "$transcript_path" \
    || missing+=("context/intent/project-intent.md")
is_loaded 'context/intent/(feature|bug|refactor)-[a-zA-Z0-9_-]+\.md$' "$transcript_path" \
    || missing+=("$MSG_GATE_MISSING_INTENT")
is_loaded 'context/code-standards\.md$' "$transcript_path" \
    || missing+=("context/code-standards.md")
is_loaded 'context/security-standards\.md$' "$transcript_path" \
    || missing+=("context/security-standards.md")

# Resolve the sensors existence check against the main
# worktree root (context/ lives there, not in a linked worktree checkout).
if [[ -f "${wf_root:-$project_dir}/context/sensors/sensors.md" ]]; then
    is_loaded 'context/sensors/sensors\.md$' "$transcript_path" \
        || missing+=("$MSG_GATE_MISSING_SENSORS")
fi

# === 9/10. Result ===
if [[ ${#missing[@]} -eq 0 ]]; then
    # Pass — write cache
    cat > "$cache_file" <<EOF
{
  "transcript_path": "$transcript_path",
  "session_hash": "$session_hash",
  "active_intent_path": "$current_active",
  "validated_at": "$(date +'%Y-%m-%dT%H:%M:%S%z')"
}
EOF
    exit 0
fi

# Block
{
    echo "$MSG_GATE_BLOCK_HEADER"
    echo ""
    echo "Blocking $tool_name on: $file_path"
    echo ""
    echo "Missing required context:"
    for m in "${missing[@]}"; do
        echo "  - $m"
    done
    echo ""
    echo "$MSG_GATE_UNLOCK"
    echo ""
    echo "Framework spec: context/.brainiac-context-framework.md → Minimum Context Gate (Step 2 Build)"
} >&2

exit 2
