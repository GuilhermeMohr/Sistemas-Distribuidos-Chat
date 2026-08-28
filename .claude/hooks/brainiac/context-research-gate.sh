#!/bin/bash
# Brainiac Context — Context Research Gate (PreToolUse hook for Write|Edit)
#
# Blocks product-code edits unless the research report for the active intent
# is present, fresh, and complete:
#
#   - context/research/<intent-slug>.md exists
#   - mtime(report) >= mtime(intent)
#   - mtime(report) >= mtime(any graph_node declared in report)
#   - now - mtime(report) < 24h (TTL backstop)
#   - report declares ALL explicit refs from the intent (INVALID_REPORT check)
#
# Order of operation (mirrors context-load-gate.sh structure, 9 steps):
#   1. Parse input
#   2. Settings-guard: BLOCK if .claude/settings.json has BRAINIAC_RESEARCH_GATE_BYPASS=true
#   3. Allowlist check (path-based; reuses lib + adds context/research/**)
#   4. Bypass check (env var + reason >= 12 visible chars; NDJSON log)
#   5. Compute session_hash + active_intent_path
#      - If no active intent → exit 0 (defer to context-load-gate; research-gate
#        does not block orphan edits — load-gate covers that case)
#   6. Derive INTENT_SLUG = basename(intent) without .md
#   7. Validate report: 5 conds (MISSING / INTENT_MTIME / DEP_MTIME / TTL / INVALID_REPORT)
#   8. Cache check: /tmp/brainiac-research-gate-<session>-<slug>.json (TTL 1h)
#   9. Pass (write cache) or Block (exit 2 + stderr i18n with specific stale code)
#
# Bypass auditable via append-only NDJSON in
# context/evolution/context-research-gate-bypasses.log.
#
# NB: pipefail OFF intentional (same reason as context-load-gate.sh — Git Bash
# MSYS2 + jq + pipe + pipefail yield silent empty output). set -u retained.

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

# Resolve to main worktree root when invoked from a git worktree child.
# context/ is gitignored and only exists in the canonical root, so worktree
# children would always MISS the research report otherwise.
if command -v git >/dev/null 2>&1; then
    _git_dir=$(git -C "$project_dir" rev-parse --git-dir 2>/dev/null)
    _git_common=$(git -C "$project_dir" rev-parse --git-common-dir 2>/dev/null)
    if [[ -n "$_git_common" && "$_git_dir" != "$_git_common" ]]; then
        # In a linked worktree — git-common-dir points to main repo's .git;
        # its parent is the main worktree root.
        _main_root=$(cd "$project_dir" && cd "$(dirname "$_git_common")" && pwd 2>/dev/null)
        [[ -n "$_main_root" ]] && project_dir_norm=$(printf '%s\n' "$_main_root" | tr '\\' '/')
    fi
fi

# === Shared helpers (lib/hooks-common.sh) + i18n ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/lib/hooks-common.sh" ]]; then
    # shellcheck source=lib/hooks-common.sh
    source "$SCRIPT_DIR/lib/hooks-common.sh"
else
    echo "[Brainiac Context Research Gate] FATAL: lib/hooks-common.sh missing" >&2
    exit 2
fi

# Workflow-aware helpers. MUST be sourced AFTER hooks-common.sh.
if [[ -f "$SCRIPT_DIR/lib/workflow-binding.sh" ]]; then
    # shellcheck source=lib/workflow-binding.sh
    source "$SCRIPT_DIR/lib/workflow-binding.sh"
else
    echo "[Brainiac Context Research Gate] FATAL: lib/workflow-binding.sh missing" >&2
    exit 2
fi

# Agent-packet PLAN-derivation layer (split keeps agent-binding.sh under the
# 500-line gate). AFTER workflow-binding, BEFORE agent-binding (the verdict
# calls ab_validate_chain / ab_plan_packet_*).
if [[ -f "$SCRIPT_DIR/lib/agent-binding-plan.sh" ]]; then
    # shellcheck source=lib/agent-binding-plan.sh
    source "$SCRIPT_DIR/lib/agent-binding-plan.sh"
fi

# Agent-packet binding (bound-Specialist verdict). Soft-source: absence => no early-exit.
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

# Fallback strings
: "${MSG_RESEARCH_GATE_BLOCK_HEADER:=[Brainiac Context Research Gate]}"
: "${MSG_RESEARCH_GATE_VERSIONED_FATAL:=Bypass via .claude/settings.json (versioned) is forbidden.}"
: "${MSG_RESEARCH_GATE_BYPASS_NO_REASON:=Bypass requires BRAINIAC_RESEARCH_GATE_BYPASS_REASON with at least 12 visible characters.}"
: "${MSG_RESEARCH_GATE_BYPASS_NOTICE:=Brainiac Context Research Gate bypass recorded.}"
: "${MSG_RESEARCH_GATE_MISSING:=Research report missing for active intent. Run /brainiac-context-research.}"
: "${MSG_RESEARCH_GATE_STALE:=Research report is stale. Run /brainiac-context-research to regenerate.}"
: "${MSG_RESEARCH_GATE_UNLOCK:=Run /brainiac-context-research to (re)generate context/research/<intent-slug>.md.}"

# === 2. Settings-guard: versionada com BYPASS=true == fatal ===
settings_path="$project_dir/.claude/settings.json"
if [[ -f "$settings_path" ]]; then
    versioned_bypass=$(jq -r '.env.BRAINIAC_RESEARCH_GATE_BYPASS // "false"' "$settings_path" 2>/dev/null)
    if [[ "$versioned_bypass" == "true" ]]; then
        cat >&2 <<EOF
$MSG_RESEARCH_GATE_BLOCK_HEADER

$MSG_RESEARCH_GATE_VERSIONED_FATAL

File: .claude/settings.json
Edit attempted on: $file_path
EOF
        exit 2
    fi
fi

# === 3. Allowlist (reuse is_allowlisted + add context/research/**) ===
# context/research/** já casa o pattern */context/* do is_allowlisted (lib).
# Sem extensão extra necessária — context/research/ vive dentro de context/.
is_allowlisted "$file_path_norm" && exit 0

# === 3.5. Scope guard: edits fora do project não disparam gate ===
# Plan files (~/.claude/plans/), auto-memory (~/.claude/projects/<>/memory/)
# e edits cross-project são layer pessoal/meta — gate só aplica em product code.
is_outside_project "$file_path_norm" "$project_dir_norm" && exit 0

# === 4. Bypass check (env var + reason) ===
if [[ "${BRAINIAC_RESEARCH_GATE_BYPASS:-false}" == "true" ]]; then
    reason_raw="${BRAINIAC_RESEARCH_GATE_BYPASS_REASON:-}"
    reason_visible=$(printf '%s\n' "$reason_raw" | tr -d '[:space:]')
    if [[ ${#reason_visible} -lt 12 ]]; then
        cat >&2 <<EOF
$MSG_RESEARCH_GATE_BLOCK_HEADER

$MSG_RESEARCH_GATE_BYPASS_NO_REASON

Edit attempted on: $file_path
EOF
        exit 2
    fi

    log_dir="$project_dir/context/evolution"
    log_file="$log_dir/context-research-gate-bypasses.log"
    if [[ ! -d "$log_dir" ]]; then
        if ! mkdir -p "$log_dir" 2>/dev/null; then
            log_file="/tmp/brainiac-research-bypass-fallback.log"
            echo "[Brainiac Research Gate] context/evolution/ missing — fallback log: $log_file" >&2
        fi
    fi

    ts=$(date +'%Y-%m-%dT%H:%M:%S%z')
    sess_hash=$(compute_sha256 "$transcript_path")
    [[ -z "$sess_hash" ]] && sess_hash="unknown"
    reason_json=$(printf '%s\n' "$reason_raw" | sed 's/"/\\"/g')
    printf '{"ts":"%s","tool":"%s","file":"%s","reason":"%s","session_hash":"%s","user":"%s"}\n' \
        "$ts" "$tool_name" "$file_path" "$reason_json" "$sess_hash" "${USER:-unknown}" >> "$log_file"
    echo "[Brainiac Research Gate] $MSG_RESEARCH_GATE_BYPASS_NOTICE ($log_file)" >&2
    exit 0
fi

# === 4.5. Workflow-aware ===
# Never inherit the mother session's active intent inside a native Dynamic
# Workflow subagent. Bound -> active intent comes from the validated binding (the
# report for THAT intent is then checked below). Unbound -> block the write.
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')
wf_root=$(resolve_project_root "$project_dir")
wf_verdict=$(workflow_binding_verdict "$agent_type" "$project_dir" "$transcript_path" "$wf_root")
wf_mode="${wf_verdict%%$'\t'*}"
case "$wf_mode" in
    bound)
        echo "[brainiac][context-source] workflow-bound (run=$(printf '%s' "$wf_verdict" | cut -f3))" >&2
        ;;
    unbound)
        emit_workflow_unbound "$MSG_RESEARCH_GATE_BLOCK_HEADER" "$file_path"
        ;;
    *)
        echo "[brainiac][context-source] main-transcript" >&2
        ;;
esac

# === 4.6. Agent-packet bound write ===
# A Specialist bound by the envelope-guard writing inside its plan-derived allowed_paths
# is authorized (its context is the approved plan). Early-exit; the research report for
# the run was validated at dispatch time. Invalid bindings were blocked upstream.
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

if [[ "$wf_mode" == "bound" ]]; then
    # Active intent from the validated binding — NEVER the mother's transcript.
    current_active=$(printf '%s' "$wf_verdict" | cut -f2)
else
    current_active=$(active_intent_path "$transcript_path")
fi

# Defer to context-load-gate if no active intent — research-gate is the 2nd
# gate in the PreToolUse chain; load-gate already blocks orphan edits.
if [[ -z "$current_active" ]]; then
    exit 0
fi

# === 6. Derive intent_slug ===
intent_basename=$(basename "$current_active")
intent_slug="${intent_basename%.md}"

# Resolve intent absolute path within project_dir
# current_active is relative-ish from transcript (e.g. "context/intent/foo.md");
# join with project_dir if not absolute
if [[ "$current_active" == /* ]] || [[ "$current_active" == ?:* ]]; then
    intent_abs="$current_active"
else
    intent_abs="$project_dir_norm/$current_active"
fi

# Derive context_root from the intent's location, NOT from project_dir_norm.
# project_dir_norm reflects the harness cwd, which may be a different project
# than the one containing the intent (intent loaded from another repo via
# Read tool). Otherwise: false positive MISSING when cwd is project A and
# intent comes from project B — report_path computed in A's tree fails.
intent_dir=$(dirname "$intent_abs")              # .../context/intent
context_root=$(dirname "$intent_dir")             # .../context

report_path="$context_root/research/$intent_basename"

# === 7. Validate report (5 conds OR) ===

# Cond 1: MISSING
if [[ ! -f "$report_path" ]]; then
    _file_exists_check=$([[ -f "$report_path" ]] && echo "TRUE (unexpected — reporte)" || echo "FALSE")
    _ls_output=$(ls -la "$report_path" 2>&1 | head -1)
    cat >&2 <<EOF
$MSG_RESEARCH_GATE_BLOCK_HEADER

$MSG_RESEARCH_GATE_MISSING

Active intent: $current_active
Expected report: $report_path
Edit attempted on: $file_path

[debug — paths computados]
  intent_path_full:  $intent_abs
  context_root:      $context_root
  project_dir_norm:  $project_dir_norm  (cwd do harness; pode diferir de context_root em cenário cross-project)
  file exists check: $_file_exists_check
  ls -la output:     $_ls_output

$MSG_RESEARCH_GATE_UNLOCK
EOF
    exit 2
fi

# Helper: get mtime cross-platform (Linux: stat -c %Y; macOS: stat -f %m)
_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

report_mtime=$(_mtime "$report_path")
intent_mtime=$(_mtime "$intent_abs")
now_ts=$(date +%s)

# Cond 2: INTENT_MTIME (intent modified after report)
if [[ "$intent_mtime" -gt "$report_mtime" ]]; then
    cat >&2 <<EOF
$MSG_RESEARCH_GATE_BLOCK_HEADER

$MSG_RESEARCH_GATE_STALE
Reason: intent file modified after report (INTENT_MTIME).

Active intent: $current_active (mtime=$intent_mtime)
Report: context/research/$intent_basename (mtime=$report_mtime)
Edit attempted on: $file_path

$MSG_RESEARCH_GATE_UNLOCK
EOF
    exit 2
fi

# Cond 4: TTL (24h backstop) — check before DEP_MTIME (cheaper)
ttl_seconds=86400  # 24h
if [[ $((now_ts - report_mtime)) -gt $ttl_seconds ]]; then
    cat >&2 <<EOF
$MSG_RESEARCH_GATE_BLOCK_HEADER

$MSG_RESEARCH_GATE_STALE
Reason: report older than 24h (TTL).

Report: context/research/$intent_basename (age=$((now_ts - report_mtime))s)
Edit attempted on: $file_path

$MSG_RESEARCH_GATE_UNLOCK
EOF
    exit 2
fi

# Cond 3: DEP_MTIME — any graph_node declared in report has mtime > report_mtime?
# Extract canonical paths from report sections "Explicit refs" + "Graph transitive"
# Pattern: lines like `- \`context/decisions/NNN-foo.md\`` or `- context/decisions/NNN-foo.md`
report_refs=$(grep -oE 'context/(decisions|knowledge/(patterns|anti-patterns))/[a-zA-Z0-9_/-]+\.md' "$report_path" 2>/dev/null | sort -u)

stale_dep=""
while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    # ref is like "context/decisions/foo.md"; strip leading "context/" and resolve
    # against context_root (derived from intent location, not project_dir_norm —
    # cross-project intents need their own context_root).
    ref_rel="${ref#context/}"
    ref_abs="$context_root/$ref_rel"
    [[ -f "$ref_abs" ]] || continue  # broken link — não considera stale (lint cobre)
    ref_mtime=$(_mtime "$ref_abs")
    if [[ "$ref_mtime" -gt "$report_mtime" ]]; then
        stale_dep="$ref"
        break
    fi
done <<< "$report_refs"

if [[ -n "$stale_dep" ]]; then
    cat >&2 <<EOF
$MSG_RESEARCH_GATE_BLOCK_HEADER

$MSG_RESEARCH_GATE_STALE
Reason: referenced artifact modified after report (DEP_MTIME).

Stale dependency: $stale_dep
Report: context/research/$intent_basename
Edit attempted on: $file_path

$MSG_RESEARCH_GATE_UNLOCK
EOF
    exit 2
fi

# Cond 5: INVALID_REPORT — intent refs not covered by report's Explicit refs section
# Extract refs from intent (4 forms, cheap version — no FS scan for C/D in hook)
# Hook uses globs O(1) instead of full scan to keep performance ~ms.
extract_intent_refs() {
    local intent_file="$1"
    local ctx_root="$2"   # resolve refs against the intent's own context_root
    [[ -f "$intent_file" ]] || return 0
    # Form A: context/(decisions|knowledge/...)/path.md
    grep -oE 'context/(decisions|knowledge/(patterns|anti-patterns))/[a-zA-Z0-9_/-]+\.md' "$intent_file" 2>/dev/null
    # Form B: ../decisions/... → resolve to context/decisions/...
    grep -oE '\.\./(decisions|knowledge/(patterns|anti-patterns))/[a-zA-Z0-9_/-]+\.md' "$intent_file" 2>/dev/null \
        | sed 's|^\.\./|context/|'
    # Form C: ADR-NNN → glob context/decisions/NNN-*.md OR context/decisions/ADR-NNN-*.md
    # (o framework suporta ambas as convenções de naming).
    while IFS= read -r adr_id; do
        [[ -z "$adr_id" ]] && continue
        local num="${adr_id#ADR-}"
        # 2 globs: NNN-*.md (canonical Brainiac) + ADR-NNN-*.md (convenção alternativa)
        for match in "$ctx_root/decisions/${num}-"*.md \
                     "$ctx_root/decisions/ADR-${num}-"*.md; do
            [[ -f "$match" ]] && echo "context/${match#$ctx_root/}"
        done
    done < <(grep -oE 'ADR-[0-9]{3,}' "$intent_file" 2>/dev/null | sort -u)
    # Form D: NNN-slug.md basename solto → glob in both decisions and knowledge
    # (suporta também ADR-NNN-slug.md).
    while IFS= read -r bname; do
        [[ -z "$bname" ]] && continue
        # Skip if it's already part of a longer path (Form A/B already caught)
        for match in "$ctx_root/decisions/$bname" \
                     "$ctx_root/knowledge/patterns/$bname" \
                     "$ctx_root/knowledge/anti-patterns/$bname"; do
            [[ -f "$match" ]] && echo "context/${match#$ctx_root/}"
        done
    done < <(grep -oE '\b(ADR-)?[0-9]{3}-[a-z0-9][a-z0-9-]*\.md\b' "$intent_file" 2>/dev/null \
             | grep -vE 'context/|\.\./' \
             | sort -u)
}

intent_refs=$(extract_intent_refs "$intent_abs" "$context_root" | tr '\\' '/' | sort -u)

# Extract refs declaradas APENAS dentro do bloco machine-readable do report
# (entre os markers BRAINIAC:EXPLICIT_REFS-START e BRAINIAC:EXPLICIT_REFS-END).
# Grep no arquivo inteiro faria uma ref citada em "Broken links" ou "Reading
# order" contar como declarada — falso positivo que enfraquece o enforcement.
# Por isso: awk delimitando o bloco + grep só nele.
report_explicit_refs=$(awk '
    /BRAINIAC:EXPLICIT_REFS-START/ { in_block=1; next }
    /BRAINIAC:EXPLICIT_REFS-END/   { in_block=0; next }
    in_block { print }
' "$report_path" 2>/dev/null \
    | grep -oE 'context/(decisions|knowledge/(patterns|anti-patterns))/[a-zA-Z0-9_/-]+\.md' \
    | sort -u)

missing_ref=""
while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    # Cobertura agora é set-membership entre refs do intent e refs declaradas
    # no bloco machine-readable do report.
    if ! grep -qxF "$ref" <<< "$report_explicit_refs"; then
        missing_ref="$ref"
        break
    fi
done <<< "$intent_refs"

if [[ -n "$missing_ref" ]]; then
    cat >&2 <<EOF
$MSG_RESEARCH_GATE_BLOCK_HEADER

$MSG_RESEARCH_GATE_STALE
Reason: intent references artifact not covered by report (INVALID_REPORT).

Intent: $current_active
Missing in report: $missing_ref
Report: context/research/$intent_basename
Edit attempted on: $file_path

$MSG_RESEARCH_GATE_UNLOCK
EOF
    exit 2
fi

# === 8. Cache (write on pass) ===
cache_file="/tmp/brainiac-research-gate-${session_hash}-${intent_slug}.json"
if [[ -f "$cache_file" ]]; then
    cache_mtime=$(_mtime "$cache_file")
    cache_age=$((now_ts - cache_mtime))
    cache_report_mtime=$(jq -r '.report_mtime // 0' "$cache_file" 2>/dev/null)
    # Cache hit if: same session, same intent, report mtime unchanged, age < 1h
    if [[ "$cache_age" -lt 3600 && "$cache_report_mtime" == "$report_mtime" ]]; then
        exit 0
    fi
fi

# === 9. Pass — write cache ===
cat > "$cache_file" <<EOF
{
  "transcript_path": "$transcript_path",
  "session_hash": "$session_hash",
  "intent_slug": "$intent_slug",
  "report_path": "$report_path",
  "report_mtime": $report_mtime,
  "validated_at": "$(date +'%Y-%m-%dT%H:%M:%S%z')"
}
EOF

exit 0
