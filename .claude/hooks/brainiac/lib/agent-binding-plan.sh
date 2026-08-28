# Brainiac Context — Agent-packet PLAN-derivation helpers
#
# Shell library — ONLY function definitions, ZERO top-level executable code.
# Source AFTER lib/hooks-common.sh AND lib/workflow-binding.sh (reuses their
# _wf_safe_id / _wf_safe_repo_path / _wf_envelope_approved / _wf_payload_sha256),
# and BEFORE lib/agent-binding.sh (whose verdict + bound-helpers CALL
# ab_validate_chain / ab_plan_packet_allowed / ab_plan_packet_write_capable /
# ab_plan_packet_knowledge_refs at runtime).
#
# Why this is split out of agent-binding.sh: keeping agent-binding.sh under the 500-line gate; the live-binding logic (Bug A
# materialization race + Bug B drive-case) grows agent_binding_verdict past the
# clean-code 500-line hard gate. These four functions are the "read the APPROVED
# PLAN" layer — the single source of truth for the path / capability / knowledge
# decisions (the pending-spawn and the binding store carry only CACHES, never the
# authority). Cohesive and independently testable, they live here; the verdict +
# binding store + run lifecycle stay in agent-binding.sh.
#
# shellcheck disable=SC2148
# (no shebang on purpose; lib is sourced, not executed standalone)


# === ab_plan_packet_allowed(plan_md, packet_id) — allowed_paths FROM THE PLAN ===
# Source of truth for the path decision. Extracts the embedded work-packets JSON
# from the approved plan .md and returns the packet's allowed_paths as a JSON array.
# The pending-spawn / binding allowed_paths are caches; this is re-derived every call.
ab_plan_packet_allowed() {
    local plan_md="$1" packet_id="$2" payload
    [[ -f "$plan_md" ]] || return 1
    payload=$(awk '
        /BRAINIAC:WORK_PACKETS_JSON-START/ { in_b=1; next }
        /BRAINIAC:WORK_PACKETS_JSON-END/   { in_b=0; next }
        in_b { print }
    ' "$plan_md")
    [[ -z "${payload//[[:space:]]/}" ]] && return 1
    jq -e . <<< "$payload" >/dev/null 2>&1 || return 1
    local out
    out=$(jq -c --arg id "$packet_id" 'map(select(.id == $id)) | .[0].allowed_paths // empty' <<< "$payload" 2>/dev/null)
    [[ -z "$out" || "$out" == "null" ]] && return 1
    printf '%s' "$out"
}


# === ab_plan_packet_write_capable(plan_md, packet_id) — write_capable FROM THE PLAN ===
# Source of truth for the capability decision (mirror of ab_plan_packet_allowed). Echoes
# "true" or "false" — re-derived from the approved plan every call; the pending-spawn /
# binding write_capable is a CACHE, never the authority. A bindable
# packet without an explicit write_capable is a malformed plan (the Contract Matrix check
# WRITE_CAPABLE_REQUIRED_ON_BINDABLE blocks it up front); here, absence echoes "false" so the
# verdict fail-safe blocks (defense-in-depth — unreachable for a schema-valid plan v2).
ab_plan_packet_write_capable() {
    local plan_md="$1" packet_id="$2" payload out
    [[ -f "$plan_md" ]] || return 1
    payload=$(awk '
        /BRAINIAC:WORK_PACKETS_JSON-START/ { in_b=1; next }
        /BRAINIAC:WORK_PACKETS_JSON-END/   { in_b=0; next }
        in_b { print }
    ' "$plan_md")
    [[ -z "${payload//[[:space:]]/}" ]] && return 1
    jq -e . <<< "$payload" >/dev/null 2>&1 || return 1
    out=$(jq -r --arg id "$packet_id" 'map(select(.id == $id)) | .[0].write_capable // false' <<< "$payload" 2>/dev/null)
    case "$out" in true|false) printf '%s' "$out" ;; *) printf 'false' ;; esac
}


# === ab_validate_chain(root, runs_dir, run_id, packet_id, pending_payload_sha) ===
# Confirm the approval hash chain for a run: envelope approved=true (source + approved_at
# checked by _wf_envelope_approved) AND a QUADRUPLE hash check —
#   pending.payload == run.json.payload == recompute(plan)
#                   == ENVELOPE_BINDING.payload == ENVELOPE_APPROVAL.payload.
# On success echoes the plan_path (relative); on any drift/failure echoes nothing.
# The ENVELOPE_APPROVAL payload is bound to the plan too (mirror of the
# dispatch-side envelope_is_approved triple-check) — an approval marker over a different
# payload than the binding no longer passes the consumer guard.
ab_validate_chain() {
    local root="$1" runs_dir="$2" run_id="$3" packet_id="$4" pending_sha="$5"
    _wf_safe_id "$run_id" || return 1
    local run_json="$runs_dir/$run_id/run.json"
    [[ -f "$run_json" ]] || return 1
    local plan_path="" env_path="" run_payload=""
    # ONE jq for the three run.json fields (was 3 spawns — the chain runs at every
    # governed write, twice on the rebind path).
    IFS=$'\037' read -r plan_path env_path run_payload < <(jq -r '
        [ ((.plan_path // "") | tostring), ((.envelope_path // "") | tostring),
          ((.payload_sha256 // "") | tostring) ] | join("")' "$run_json" 2>/dev/null) || true
    plan_path="${plan_path//$'\r'/}"; env_path="${env_path//$'\r'/}"; run_payload="${run_payload//$'\r'/}"
    _wf_safe_repo_path "$plan_path" "context/orchestration/*.md" || return 1
    _wf_safe_repo_path "$env_path"  "context/orchestration/*-envelope.md" || return 1
    case "$plan_path" in *-envelope.md) return 1 ;; esac
    [[ -f "$root/$plan_path" && -f "$root/$env_path" ]] || return 1
    _wf_envelope_approved "$root/$env_path" || return 1
    local plan_hash env_hash appr_hash
    plan_hash=$(_wf_payload_sha256 "$root/$plan_path") || return 1
    env_hash=$(grep -oE 'BRAINIAC:ENVELOPE_BINDING payload_sha256=[a-f0-9]+' "$root/$env_path" 2>/dev/null | head -1 | sed 's/.*=//')
    appr_hash=$(grep -E 'BRAINIAC:ENVELOPE_APPROVAL' "$root/$env_path" 2>/dev/null | head -1 | grep -oE 'payload_sha256=[a-f0-9]+' | head -1 | sed 's/.*=//')
    [[ -n "$plan_hash" ]] || return 1
    [[ "$run_payload"  == "$plan_hash" ]] || return 1
    [[ "$env_hash"     == "$plan_hash" ]] || return 1
    [[ "$appr_hash"    == "$plan_hash" ]] || return 1
    [[ "$pending_sha"  == "$plan_hash" ]] || return 1
    printf '%s' "$plan_path"
}


# === ab_plan_packet_knowledge_refs(plan_md, packet_id) — declared knowledge_refs ===
# Echoes the packet's knowledge_refs JSON array (or "[]") from the approved plan.
ab_plan_packet_knowledge_refs() {
    local plan_md="$1" packet_id="$2" payload out
    [[ -f "$plan_md" ]] || return 1
    payload=$(awk '
        /BRAINIAC:WORK_PACKETS_JSON-START/ { in_b=1; next }
        /BRAINIAC:WORK_PACKETS_JSON-END/   { in_b=0; next }
        in_b { print }
    ' "$plan_md")
    [[ -z "${payload//[[:space:]]/}" ]] && return 1
    out=$(jq -c --arg id "$packet_id" 'map(select(.id == $id)) | .[0].knowledge_refs // []' <<< "$payload" 2>/dev/null) || return 1
    printf '%s' "$out"
}

# === ab_path_in_allowed(file_rel, allowed_json) — repo-relative containment ===
# (Moved from agent-binding.sh — 500-line gate.) Returns 0 if file_rel (repo-relative,
# normalized) is inside one of the allowed globs. Prefix semantics mirror the
# contract-matrix overlap engine (strip /**,/*, trailing /). A non-relative file_rel
# (root strip failed) matches nothing => block.
# SEC-1: any `..` segment is rejected (return 1) — a raw prefix match would otherwise
# accept `src/foo/../../escape` because the STRING starts with `src/foo/` even though
# the path escapes allowed_paths (anti-pattern lexical-path-validation-misses-symlink-
# toctou). Mirror of _wf_safe_repo_path's conservative `*..*` rejection.
ab_path_in_allowed() {
    local file_rel="$1" allowed_json="$2" entry e
    # Bug B: normalize the candidate to the canonical drive form (D:/ <-> d:/ <-> /d/) so a
    # repo-relative target survives; the anti-bypass guard then rejects anything STILL absolute
    # / drive / traversal AFTER normalizing — normalization unifies drive CASE only, it must
    # never turn an escaping path into a valid boundary (SEC-1).
    file_rel=$(_normalize_cwd_for_match "$file_rel")
    case "$file_rel" in /*|[A-Za-z]:*|""|*..*) return 1 ;; esac   # not repo-relative OR has traversal
    # ONE jq lists the entries (was 1 jq spawn per entry — this runs at every governed
    # write). `// empty` semantics preserved: null/false entries are skipped; every
    # per-entry SEC guard below is unchanged.
    while IFS= read -r entry; do
        entry="${entry//$'\r'/}"
        [[ -z "$entry" ]] && continue
        e=$(_normalize_cwd_for_match "$entry")
        # An allowed entry that is absolute / drive / traversal is NOT a valid boundary (a plan
        # declares repo-relative globs) — skip it, never let it match (anti-bypass, SEC-1).
        case "$e" in /*|[A-Za-z]:*|*..*) continue ;; esac
        e="${e#./}"; e="${e#/}"
        e="${e%/\*\*}"; e="${e%/\*}"; e="${e%/}"
        [[ -z "$e" ]] && continue                # root-glob entry => no boundary, skip
        [[ "$file_rel" == "$e" ]] && return 0
        [[ "$file_rel" == "$e/"* ]] && return 0
    done < <(jq -r 'if type == "array" then (.[] | . // empty | tostring) else empty end' \
        <<< "$allowed_json" 2>/dev/null)
    return 1
}


# === _ab_nap(seconds) — bounded-retry wait for agent_binding_verdict (materialization race) ===
# Lives here (not in agent_binding_verdict) for the same reason as the four above: keep
# agent-binding.sh under the clean-code 500-line hard gate. Primary path is a Bash-native
# EPOCHREALTIME spin wait: no fork, no MSYS `sleep` rounding, and no FIFO/read -t overhead
# (Git Bash measured FIFO≈200–500ms per "50ms" nap, which violates the verdict's <500ms
# total retry budget). Fallback keeps the old FIFO read-timeout only for shells without
# EPOCHREALTIME; any fallback failure just skips the nap.
_ab_now_us() {
    local _e="${EPOCHREALTIME:-}" _s _f
    [[ -n "$_e" ]] || return 1
    _e="${_e/,/.}"          # Git Bash may honor locale and use comma decimals.
    _s="${_e%%.*}"; _f="${_e#*.}"
    [[ "$_s" =~ ^[0-9]+$ ]] || return 1
    [[ "$_f" == "$_e" ]] && _f=0
    [[ "$_f" =~ ^[0-9]+$ ]] || return 1
    _f="${_f}000000"; _f="${_f:0:6}"
    _ab_now_us_out=$((10#$_s * 1000000 + 10#$_f))
}

_ab_duration_us() {
    local _v="$1" _s _f
    _v="${_v/,/.}"
    _s="${_v%%.*}"; _f="${_v#*.}"
    [[ "$_s" =~ ^[0-9]+$ ]] || _s=0
    [[ "$_f" == "$_v" ]] && _f=0
    [[ "$_f" =~ ^[0-9]+$ ]] || _f=0
    _f="${_f}000000"; _f="${_f:0:6}"
    _ab_duration_us_out=$((10#$_s * 1000000 + 10#$_f))
}

_ab_nap() {
    local _secs="$1" _start _deadline
    if _ab_now_us && _ab_duration_us "$_secs"; then
        _start="$_ab_now_us_out"
        _deadline=$((_start + _ab_duration_us_out))
        while _ab_now_us; do
            [[ "$_ab_now_us_out" -ge "$_deadline" ]] && break
        done
        return 0
    fi

    local _f _fd
    _f=$(mktemp -u 2>/dev/null) || return 0
    mkfifo "$_f" 2>/dev/null || { rm -f "$_f" 2>/dev/null; return 0; }
    exec {_fd}<>"$_f" 2>/dev/null || { rm -f "$_f" 2>/dev/null; return 0; }
    rm -f "$_f" 2>/dev/null   # unlink now; the RDWR fd keeps the pipe alive with no writer
    read -t "$_secs" -r -u "$_fd" _ 2>/dev/null || true
    exec {_fd}>&- 2>/dev/null || true
}


# End of library — no top-level code follows. Caller resumes.
