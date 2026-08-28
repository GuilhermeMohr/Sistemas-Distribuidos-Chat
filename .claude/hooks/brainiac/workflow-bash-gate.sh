#!/bin/bash
# Brainiac Context — Workflow Bash Gate (PreToolUse hook for Bash|Read|Grep|Glob)
#
# Closes the Bash write-vector for unbound workflow subagents. The context
# gates (context-load-gate.sh, context-research-gate.sh) only cover Write|Edit, so
# an unbound workflow subagent could write product code via Bash (e.g.
# `cat > skills/x.md <<EOF`) and escape the binding requirement entirely — breaking
# The framework's inviolable rule. This gate completes that guarantee: in an UNBOUND
# workflow subagent, only the exact registrar Step-0 invocation is allowed; any other
# Bash is blocked. A BOUND subagent runs Bash freely; a normal session is a no-op.
#
# Reuses workflow_binding_verdict() + emit_workflow_unbound() from the workflow-binding lib.
#
# NB: pipefail INTENTIONALLY OFF (same MSYS2 jq+pipe rationale as the sibling gates;
# set -u retained). brainiac:any-ok N/A (bash).

set -u

# === 1. Parse input — act only on Bash (Read/Grep/Glob are read-only) ===
input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
[[ "$tool_name" == "Bash" ]] || exit 0

bash_command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')
project_dir=$(printf '%s' "$input" | jq -r '.cwd // empty')
[[ -z "$project_dir" ]] && project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# === 2. Source shared libs (binding verdict + unbound emitter) ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/hooks-common.sh" ]]; then
    # shellcheck source=lib/hooks-common.sh
    source "$SCRIPT_DIR/lib/hooks-common.sh"
else
    echo "[Brainiac Workflow Bash Gate] FATAL: lib/hooks-common.sh missing — install via _install_hooks_only" >&2
    exit 2
fi
if [[ -f "$SCRIPT_DIR/lib/workflow-binding.sh" ]]; then
    # shellcheck source=lib/workflow-binding.sh
    source "$SCRIPT_DIR/lib/workflow-binding.sh"
else
    echo "[Brainiac Workflow Bash Gate] FATAL: lib/workflow-binding.sh missing — install via _install_hooks_only" >&2
    exit 2
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
: "${MSG_WORKFLOW_BASH_HEADER:=[Brainiac Workflow Bash Gate]}"

# === 3. Binding verdict ===
# Cheap workflow detection FIRST: a normal session is a no-op. This avoids paying
# git root resolution on every Bash call (perf) and avoids resolve_project_root on
# a non-repo / nonexistent cwd (which would walk the filesystem needlessly).
is_workflow_subagent "$agent_type" "$project_dir" "$transcript_path" || exit 0

wf_root=$(resolve_project_root "$project_dir")
wf_verdict=$(workflow_binding_verdict "$agent_type" "$project_dir" "$transcript_path" "$wf_root")
case "${wf_verdict%%$'\t'*}" in
    normal)  exit 0 ;;   # defensive (verdict re-checks is_workflow_subagent)
    bound)   exit 0 ;;   # binding present — Bash is free (path-ownership attested later by integrate)
    unbound) : ;;        # fall through: allow ONLY the registrar Step-0
    *)       exit 0 ;;
esac

# === 4. Unbound workflow subagent: allow ONLY the exact registrar invocation ===
# Normalize Windows backslashes so the path matches regardless of separator.
cmd_norm=$(printf '%s' "$bash_command" | tr '\\' '/')

# 4a. Reject multiline (a heredoc/2nd line could smuggle a product write past a
# line-oriented match — the anchored allow-pattern below is whole-string, but be
# explicit and fail safe).
if [[ "$(printf '%s' "$bash_command" | wc -l | tr -d '[:space:]')" != "0" ]]; then
    emit_workflow_unbound "$MSG_WORKFLOW_BASH_HEADER" "$bash_command"
fi

# 4b. Denylist of shell control/redirection metacharacters (defense-in-depth on top
# of the anchored allow-pattern). Rejects ; & | < > ` $ — none appear in the baked
# registrar command (its path is single-quoted and literal).
if printf '%s' "$cmd_norm" | grep -qE '[;&|<>`$]'; then
    emit_workflow_unbound "$MSG_WORKFLOW_BASH_HEADER" "$bash_command"
fi

# 4c. Allow ONLY the CANONICAL registrar, with exactly 3 safe args. Suffix matching
# is NOT enough: a forged `bash '/tmp/evil/wf-register.sh' ...` would run arbitrary
# code. Capture the single-quoted path (tolerates spaces / Windows drive), then
# compare it — normalized — to the canonical registrar path under the resolved root.
allow_re="^[[:space:]]*bash[[:space:]]+'([^']*)'[[:space:]]+[A-Za-z0-9][A-Za-z0-9._-]*[[:space:]]+[A-Za-z0-9][A-Za-z0-9._-]*[[:space:]]+[A-Za-z0-9_-]+[[:space:]]*\$"
if [[ "$cmd_norm" =~ $allow_re ]]; then
    script_norm=$(_normalize_cwd_for_match "${BASH_REMATCH[1]}")
    expected_norm=$(_normalize_cwd_for_match "$wf_root/.claude/hooks/brainiac/wf-register.sh")
    if [[ "$script_norm" == "$expected_norm" ]]; then
        echo "[brainiac][context-source] workflow-unbound: registrar Step-0 allowed" >&2
        exit 0
    fi
fi

# 4d. Anything else from an unbound workflow subagent is a product-write vector.
emit_workflow_unbound "$MSG_WORKFLOW_BASH_HEADER" "$bash_command"
