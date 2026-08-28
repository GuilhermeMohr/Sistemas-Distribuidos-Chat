# Brainiac Context — Workflow-aware binding helpers (consumer side)
# Producer = /brainiac-context-orchestrate-workflow-export.
#
# Shell library — ONLY function definitions, ZERO top-level executable code.
# Source AFTER lib/hooks-common.sh (depends on _normalize_drive_letter from it).
# Sourced by context-load-gate.sh + context-research-gate.sh.
#
# Why this exists: a native Claude Code Dynamic Workflow runs subagents in the
# background, and a workflow subagent's PreToolUse stdin carries the MOTHER
# session's transcript_path. So active_intent_path() would resolve the mother's
# intent — a soundness hole (false-positive blocks AND false-negative passes that
# authorize a product write with an unrelated context). In a workflow subagent the
# active intent therefore comes ONLY from a validated binding declared in
# <root>/.brainiac/workflow-bindings/index.json (cwd-keyed), anchored to a SIGNED
# approval envelope. The descriptor is an ASSERTION, never trusted blindly: every
# path it names is validated against a strict allowlist + safe-path guard BEFORE
# the hook opens it (a forged marker must never make the hook read a secret), and
# the payload hash is re-derived from the plan and matched to the signed envelope.
# Any inconsistency => unbound (the caller blocks the write). The recipes mirror
# the orchestrate libs self-contained (hooks must not source skill libs);
# the validation suite cross-checks the payload hash against dispatch.sh so the
# two cannot drift.

# shellcheck disable=SC2148
# (no shebang on purpose; lib is sourced, not executed standalone)


# === is_workflow_subagent(agent_type, cwd, transcript_path) — multi-signal ===
# Fail-safe detection of a native Dynamic Workflow subagent. ANY strong signal
# => workflow. Detecting via agent_type alone is not enough: agent_type can be
# absent under some run modes. So also treat a cwd under a workflow worktree
# (.claude/worktrees/wf_*) or a transcript under subagents/workflows/wf_* as a
# workflow. With NO signal it is a normal session.
is_workflow_subagent() {
    local agent_type="${1:-}" cwd="${2:-}" transcript="${3:-}"
    [[ "$agent_type" == "workflow-subagent" ]] && return 0
    local cwd_n trans_n
    cwd_n=$(printf '%s' "$cwd" | tr '\\' '/')
    trans_n=$(printf '%s' "$transcript" | tr '\\' '/')
    case "$cwd_n" in */.claude/worktrees/wf_*) return 0 ;; esac
    case "$trans_n" in */subagents/workflows/wf_*) return 0 ;; esac
    return 1
}


# === resolve_project_root(project_dir) — robust root, no $CLAUDE_PROJECT_DIR ===
# $CLAUDE_PROJECT_DIR is empty in a workflow subagent shell, so it cannot be the
# source of truth. Cascade: git main-worktree-root (a linked worktree resolves to
# the MAIN repo root, where context/ + versions.json live) -> git toplevel -> walk
# up to a dir containing versions.json -> the given project_dir as last resort.
resolve_project_root() {
    local project_dir="${1:-}"
    [[ -z "$project_dir" ]] && project_dir="$(pwd)"
    if command -v git >/dev/null 2>&1; then
        local gd gcd
        gd=$(git -C "$project_dir" rev-parse --git-dir 2>/dev/null)
        gcd=$(git -C "$project_dir" rev-parse --git-common-dir 2>/dev/null)
        if [[ -n "$gcd" && "$gd" != "$gcd" ]]; then
            local mr
            mr=$(cd "$project_dir" && cd "$(dirname "$gcd")" && pwd 2>/dev/null)
            [[ -n "$mr" ]] && { printf '%s' "$mr"; return 0; }
        fi
        local tl
        tl=$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)
        [[ -n "$tl" ]] && { printf '%s' "$tl"; return 0; }
    fi
    local d="$project_dir"
    while [[ -n "$d" && "$d" != "/" ]]; do
        [[ -f "$d/versions.json" ]] && { printf '%s' "$d"; return 0; }
        d=$(dirname "$d")
    done
    printf '%s' "$project_dir"
}


# _normalize_cwd_for_match <path> — canonical cwd form for the cwd-keyed match.
# Beyond _normalize_drive_letter (which only lowercases a leading X: drive), this
# unifies the THREE forms the same directory can take across Git Bash / Windows:
#   /c/Users/x  (MSYS)      ->  c:/users-preserved...  no: -> c:/Users/x
#   C:/Users/x  (Windows)   ->  c:/Users/x
#   c:/Users/x              ->  c:/Users/x
# Without this, a registrar that records `pwd` as C:/... never matches a stdin cwd
# delivered as /c/... (false unbound -> false block). POSIX paths (/home/...) are
# left unchanged.
_normalize_cwd_for_match() {
    local p; p=$(printf '%s' "${1:-}" | tr '\\' '/')
    case "$p" in
        /[A-Za-z]/*)            # MSYS /c/rest -> c:/rest
            local d rest
            d=$(printf '%s' "$p" | cut -c2 | tr '[:upper:]' '[:lower:]')
            rest=${p#/?}
            printf '%s:%s' "$d" "$rest" ;;
        [A-Za-z]:/*)            # Windows C:/rest -> c:/rest
            local d rest
            d=$(printf '%s' "$p" | cut -c1 | tr '[:upper:]' '[:lower:]')
            rest=${p#?}
            printf '%s%s' "$d" "$rest" ;;
        *) printf '%s' "$p" ;;  # POSIX / driveless — unchanged
    esac
}

# _wf_sha256_stdin — full lowercase hex digest from stdin. MUST match the _sha256
# recipe in orchestrate-dispatch lib so the payload hash agrees bit-for-bit.
_wf_sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 | sed 's/^.*= *//'
    else echo "NO_SHA256_TOOL"; return 1; fi
}

# _wf_payload_sha256 <plan.md> — mirror of orchestrate-dispatch payload_sha256():
# sha256 of the JSON between the WORK_PACKETS_JSON markers, normalized via
# `jq -S -c .` (sorted keys, compact, no trailing newline).
_wf_payload_sha256() {
    local md="$1" payload
    [[ -f "$md" ]] || return 1
    payload=$(awk '
        /BRAINIAC:WORK_PACKETS_JSON-START/ { in_b=1; next }
        /BRAINIAC:WORK_PACKETS_JSON-END/   { in_b=0; next }
        in_b { print }
    ' "$md")
    [[ -z "${payload//[[:space:]]/}" ]] && return 1
    jq -S -c . <<< "$payload" 2>/dev/null | tr -d '\n' | _wf_sha256_stdin
}

# _wf_safe_id <value> — safe identifier for run/packet/scope (no traversal, no
# shell metacharacters). Same allow-list shape as the orchestrate safe-id guard.
_wf_safe_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# _wf_safe_repo_path <path> <allow_glob> — SEC-1 guard for paths that will be
# OPENED (intent/plan/envelope/refs). NOT for cwd (the matching key, legitimately
# absolute/drive). OK only if: repo-relative (no .., no /abs, no ~, no X: drive),
# NOT a secret (.env*/secrets/*.key/*.pem/credentials), AND matches allow_glob.
_wf_safe_repo_path() {
    local p="${1:-}" allow="${2:-}"
    [[ -z "$p" || -z "$allow" ]] && return 1
    local pn; pn=$(printf '%s' "$p" | tr '\\' '/')
    case "$pn" in
        /*|~*|[A-Za-z]:*) return 1 ;;          # absolute / home / windows drive
        *..*) return 1 ;;                       # parent traversal (conservative)
    esac
    case "$pn" in
        *.env|*.env.*|*/secrets/*|*.key|*.pem|*credentials*) return 1 ;;
    esac
    # shellcheck disable=SC2254 # $allow is an intentional glob pattern (not literal)
    case "$pn" in
        $allow) return 0 ;;
        *) return 1 ;;
    esac
}

# _wf_approval_field <env_md> <key> — value of `key=value` in the (first) ENVELOPE_APPROVAL
# marker (tokens space-separated; values carry no spaces — the ISO-8601 stamp uses none).
_wf_approval_field() {
    local env_md="$1" key="$2" line
    line=$(grep -E 'BRAINIAC:ENVELOPE_APPROVAL' "$env_md" 2>/dev/null | head -1)
    [[ -n "$line" ]] || return 1
    printf '%s\n' "$line" | grep -oE "${key}=[^[:space:]]+" | head -1 | sed "s/^${key}=//"
}

# _wf_approval_source_ok <source> — production enum human-chat-approval | human-file-edit;
# ci-dispatch ONLY under BRAINIAC_TEST_MODE=1 (never a production approval source). Mirror of
# orchestrate-dispatch _approval_source_ok.
_wf_approval_source_ok() {
    case "${1:-}" in
        human-chat-approval|human-file-edit) return 0 ;;
        ci-dispatch) [[ "${BRAINIAC_TEST_MODE:-}" == "1" ]] && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

# _wf_envelope_approved <envelope.md> — machine-readable approval present + well-formed:
# EXACTLY ONE BRAINIAC:ENVELOPE_APPROVAL marker, approved=true, valid source, ISO-8601
# approved_at. Mirror of orchestrate-dispatch _envelope_has_approval (approval-anchor
# by hash, no Signed-off-by). The consumer side checks source + approved_at
# too, in parity with the dispatch/export gate; the
# payload triple/quadruple-hash check stays in ab_validate_chain (Step 6 / agent-binding.sh).
_wf_envelope_approved() {
    local env_md="$1" n approved src ts
    [[ -f "$env_md" ]] || return 1
    n=$(grep -cE 'BRAINIAC:ENVELOPE_APPROVAL' "$env_md" 2>/dev/null || true); n=${n:-0}
    [[ "$n" -eq 1 ]] || return 1
    approved=$(_wf_approval_field "$env_md" approved)
    [[ "$approved" == "true" ]] || return 1
    src=$(_wf_approval_field "$env_md" source)
    _wf_approval_source_ok "$src" || return 1
    ts=$(_wf_approval_field "$env_md" approved_at)
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]] || return 1
    return 0
}

# _wf_refs_validate_and_digest <refs_json> <root> — single pass that BOTH validates
# and digests required_context_refs. SEC-1: allowlist + safe-path
# are checked BEFORE any filesystem read, so a forged ref path (e.g. .env.local,
# ../secret, /abs, a credentials file) is NEVER opened/hashed — even though the
# digest feeds the cache key. Requirements: the FULL mandatory minimum package
# (project-intent + code-standards + security-standards; sensors optional), ONLY
# allowlisted paths, and each declared sha256 matches the on-disk file.
# On success: prints the digest (sha of sorted "path<TAB><computed-sha>") + return 0.
# On ANY validation failure: prints NOTHING + return 1 — without reading a
# non-allowlisted path. The caller treats a non-zero return as unbound.
_wf_refs_validate_and_digest() {
    local refs_json="$1" root="$2" n path sha opt abs disk
    local seen_pi=0 seen_cs=0 seen_ss=0 lines="" _triplets
    n=$(jq 'length' <<< "$refs_json" 2>/dev/null) || return 1
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    # ONE jq extracts every (path, sha256, optional) triplet from the IN-MEMORY refs
    # JSON (was 3 spawns per ref). Extraction touches NO filesystem path — the
    # allowlist + safe-path guards below still run BEFORE any read (SEC-1 order intact).
    _triplets=$(jq -r '.[]? |
        [ ((.path // "") | tostring), ((.sha256 // "") | tostring),
          ((.optional // false) | tostring) ] | join("")' <<< "$refs_json" 2>/dev/null) || return 1
    while IFS=$'\037' read -r path sha opt; do
        path="${path//$'\r'/}"; sha="${sha//$'\r'/}"; opt="${opt//$'\r'/}"
        [[ -z "$path$sha$opt" ]] && continue
        # Allowlist (minimum-package only) — BEFORE any filesystem touch.
        case "$path" in
            context/intent/project-intent.md) seen_pi=1 ;;
            context/code-standards.md)        seen_cs=1 ;;
            context/security-standards.md)    seen_ss=1 ;;
            context/sensors/sensors.md) ;;
            *) return 1 ;;   # not in the minimum-package allowlist -> NO read
        esac
        # Safe-path guard (defense in depth) — BEFORE any filesystem touch.
        _wf_safe_repo_path "$path" "context/*" || return 1
        # Only now (allowlisted + safe) may we touch the filesystem.
        abs="$root/$path"
        if [[ ! -f "$abs" ]]; then
            [[ "$opt" == "true" ]] && { lines+="$path"$'\t'"-"$'\n'; continue; }
            return 1
        fi
        [[ -n "$sha" ]] || return 1
        disk=$(_wf_sha256_stdin < "$abs")
        [[ "$disk" == "$sha" ]] || return 1
        lines+="$path"$'\t'"$disk"$'\n'
    done <<< "$_triplets"
    # Mandatory minimum-package members must ALL be declared (no partial bypass).
    [[ "$seen_pi" -eq 1 && "$seen_cs" -eq 1 && "$seen_ss" -eq 1 ]] || return 1
    printf '%s' "$lines" | sort | _wf_sha256_stdin
    return 0
}

# workflow_binding <project_root> <cwd> — resolve + fully validate the binding for
# this subagent's cwd. On success prints "<run_id>\t<intent_path>\t<refs_digest>\t<payload_sha>"
# (intent_path validated + existing; minimum package confirmed). On ANY failure
# prints nothing (unbound). NEVER opens a path until it is allowlist-validated.
workflow_binding() {
    local root="$1" cwd="$2"
    local index="$root/.brainiac/workflow-bindings/index.json"
    [[ -f "$index" ]] || return 1
    local cwd_n; cwd_n=$(_normalize_cwd_for_match "$cwd")

    # Step 1: resolve entry by normalized cwd (zero or >1 match => unbound).
    # ONE jq lists every binding's index + cwd (was 1 spawn PER binding); the
    # normalized compare stays in bash — same match rule, same ambiguity handling.
    local j ecwd matched=-1 n_match=0
    while IFS=$'\037' read -r j ecwd; do
        j="${j//$'\r'/}"; ecwd="${ecwd//$'\r'/}"
        [[ "$j" =~ ^[0-9]+$ ]] || continue
        ecwd=$(_normalize_cwd_for_match "$ecwd")
        if [[ "$ecwd" == "$cwd_n" ]]; then n_match=$((n_match+1)); matched=$j; fi
    done < <(jq -r '(.bindings // []) | to_entries[] |
        [ (.key | tostring), ((.value.cwd // "") | tostring) ] | join("")' \
        "$index" 2>/dev/null)
    [[ "$n_match" -eq 1 ]] || return 1   # zero or ambiguous => unbound

    # Extract entry fields — ONE jq for the six scalars + the refs array (was 8 spawns).
    local b run_id="" scope="" packet_id="" intent_path="" plan_path="" payload_sha="" refs_json
    b=$(jq -c ".bindings[$matched]" "$index" 2>/dev/null) || return 1
    IFS=$'\037' read -r run_id scope packet_id intent_path plan_path payload_sha < <(jq -r '
        [ ((.run_id // "") | tostring), ((.scope // "") | tostring),
          ((.packet_id // "") | tostring), ((.intent_path // "") | tostring),
          ((.plan_path // "") | tostring), ((.payload_sha256 // "") | tostring)
        ] | join("")' <<< "$b" 2>/dev/null) || true
    run_id="${run_id//$'\r'/}"; scope="${scope//$'\r'/}"; packet_id="${packet_id//$'\r'/}"
    intent_path="${intent_path//$'\r'/}"; plan_path="${plan_path//$'\r'/}"; payload_sha="${payload_sha//$'\r'/}"
    refs_json=$(jq -c '.required_context_refs // []' <<< "$b")
    refs_json="${refs_json//$'\r'/}"

    # Step 2: safe-ids.
    _wf_safe_id "$run_id" || return 1
    _wf_safe_id "$packet_id" || return 1
    _wf_safe_id "$scope" || return 1

    # Step 3: validate EVERY openable path BEFORE opening (allowlist + safe-path).
    _wf_safe_repo_path "$intent_path" "context/intent/*.md" || return 1
    case "$(basename "$intent_path")" in feature-*|bug-*|refactor-*) ;; *) return 1 ;; esac
    _wf_safe_repo_path "$plan_path" "context/orchestration/*.md" || return 1
    case "$plan_path" in *-envelope.md) return 1 ;; esac   # plan is NOT an envelope

    # Step 4: run.json under .brainiac/runs/<run_id>/ (RO; run_id is a safe-id).
    local runs_dir run_json
    runs_dir="${BRAINIAC_RUNS_DIR:-$root/.brainiac/runs}"
    run_json="$runs_dir/$run_id/run.json"
    [[ -f "$run_json" ]] || return 1

    local env_path="" run_payload="" run_plan=""
    # ONE jq for the three run.json fields (was 3 spawns).
    IFS=$'\037' read -r env_path run_payload run_plan < <(jq -r '
        [ ((.envelope_path // "") | tostring), ((.payload_sha256 // "") | tostring),
          ((.plan_path // "") | tostring) ] | join("")' "$run_json" 2>/dev/null) || true
    env_path="${env_path//$'\r'/}"; run_payload="${run_payload//$'\r'/}"; run_plan="${run_plan//$'\r'/}"
    _wf_safe_repo_path "$env_path" "context/orchestration/*-envelope.md" || return 1
    [[ "$run_plan" == "$plan_path" ]] || return 1   # run + marker agree on the plan

    # Cheap always-checks (cwd-keyed; never skipped by cache).
    [[ -f "$root/$intent_path" ]] || return 1   # intent must exist on disk

    # SEC-1: validate + digest required_context_refs BEFORE building the
    # cache key. _wf_refs_validate_and_digest checks allowlist + safe-path BEFORE
    # reading any ref, so a forged ref path is never opened/hashed — and it yields
    # the digest used in the cache key. Runs on EVERY invocation (even cache hits):
    # cheap (<=4 small files) and means a non-allowlisted ref is rejected before any
    # read regardless of the cache. Failure => unbound.
    local digest
    digest=$(_wf_refs_validate_and_digest "$refs_json" "$root") || return 1

    # Cache key: run_id + payload + plan_mtime + envelope_mtime + cwd +
    # refs_digest. plan/envelope use mtime (a content edit bumps it -> re-validate);
    # the STANDARDS refs use the COMPUTED-sha digest above (mtime is manipulable). A
    # hit means every input is byte-identical to the last full validation -> same verdict.
    local plan_mtime env_mtime key keyhash cache_file
    plan_mtime=$(stat -c %Y "$root/$plan_path" 2>/dev/null || stat -f %m "$root/$plan_path" 2>/dev/null || echo 0)
    env_mtime=$(stat -c %Y "$root/$env_path" 2>/dev/null || stat -f %m "$root/$env_path" 2>/dev/null || echo 0)
    key="$run_id|$packet_id|$payload_sha|$plan_mtime|$env_mtime|$cwd_n|$digest"
    keyhash=$(printf '%s' "$cwd_n|$run_id" | _wf_sha256_stdin | cut -c1-32)
    cache_file="${TMPDIR:-/tmp}/brainiac-wf-binding-${keyhash}.json"
    if [[ -f "$cache_file" ]]; then
        local c_mtime c_age c_key
        c_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        c_age=$(( $(date +%s) - c_mtime ))
        c_key=$(jq -r '.key // ""' "$cache_file" 2>/dev/null)
        if [[ "$c_age" -lt 3600 && "$c_key" == "$key" ]]; then
            printf '%s\t%s\t%s\t%s' "$run_id" "$intent_path" "$digest" "$payload_sha"
            return 0
        fi
    fi

    # --- Full validation (cache miss) ---
    # Step 5: envelope approved (approval-anchor approved=true; no Signed-off-by).
    _wf_envelope_approved "$root/$env_path" || return 1

    # Step 6: envelope hash == run.payload == recompute(plan) == marker.payload.
    local env_hash plan_hash
    env_hash=$(grep -oE 'BRAINIAC:ENVELOPE_BINDING payload_sha256=[a-f0-9]+' "$root/$env_path" 2>/dev/null | head -1 | sed 's/.*=//')
    plan_hash=$(_wf_payload_sha256 "$root/$plan_path") || return 1
    [[ -n "$plan_hash" ]] || return 1
    [[ "$env_hash"   == "$plan_hash" ]] || return 1
    [[ "$run_payload" == "$plan_hash" ]] || return 1
    [[ "$payload_sha" == "$plan_hash" ]] || return 1

    # (required_context_refs already validated + digested above, before the cache
    # key — SEC-1: no ref path is read until it passes the allowlist + safe-path guard.)

    # Write cache (validated). Best-effort; failure to cache is non-fatal.
    printf '{"key":"%s","validated_at":%s}\n' "$key" "$(date +%s)" > "$cache_file" 2>/dev/null || true

    printf '%s\t%s\t%s\t%s' "$run_id" "$intent_path" "$digest" "$payload_sha"
    return 0
}


# workflow_binding_verdict <agent_type> <cwd> <transcript> <root> — pure verdict
# for the workflow-aware gates. Echoes exactly one of:
#   normal
#   unbound
#   bound<TAB>intent_path<TAB>run_id
# No exit (safe to call inside $()).
workflow_binding_verdict() {
    local agent_type="$1" cwd="$2" transcript="$3" root="$4"
    is_workflow_subagent "$agent_type" "$cwd" "$transcript" || { echo "normal"; return 0; }
    local out; out=$(workflow_binding "$root" "$cwd")
    if [[ -n "$out" ]]; then
        local _b_run _b_intent _rest
        IFS=$'\t' read -r _b_run _b_intent _rest <<< "$out"
        printf 'bound\t%s\t%s\n' "$_b_intent" "$_b_run"
    else
        echo "unbound"
    fi
}

# emit_workflow_unbound <gate_header> [file_path] — a workflow subagent with no
# valid binding tried a product-code write. Block (exit 2) with
# BRAINIAC_WORKFLOW_CONTEXT_REQUIRED, UNLESS BRAINIAC_WORKFLOW_UNBOUND=advisory
# (warn + exit 0). Call DIRECTLY (not in a subshell) so the exit ends the gate.
emit_workflow_unbound() {
    local header="$1" file_path="${2:-}"
    if [[ "${BRAINIAC_WORKFLOW_UNBOUND:-block}" == "advisory" ]]; then
        echo "[brainiac][context-source] workflow-unbound (advisory)" >&2
        echo "${MSG_WORKFLOW_UNBOUND_ADVISORY:-Brainiac workflow gate: unbound write allowed (advisory mode).}" >&2
        exit 0
    fi
    echo "[brainiac][context-source] workflow-unbound" >&2
    {
        echo "$header"
        echo ""
        echo "${MSG_WORKFLOW_CONTEXT_REQUIRED:-BRAINIAC_WORKFLOW_CONTEXT_REQUIRED — unbound workflow subagent; product-code write blocked.}"
        [[ -n "$file_path" ]] && { echo ""; echo "Edit attempted on: $file_path"; }
    } >&2
    exit 2
}


# End of library — no top-level code follows. Caller resumes.
