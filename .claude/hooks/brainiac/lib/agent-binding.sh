# Brainiac Context — Agent-packet binding helpers (consumer side)
#
# Shell library — ONLY function definitions, ZERO top-level executable code.
# Source AFTER lib/hooks-common.sh, lib/workflow-binding.sh (reuses their
# _wf_sha256_stdin / _wf_payload_sha256 / _wf_safe_id / _wf_safe_repo_path /
# _wf_envelope_approved / resolve_project_root / _normalize_cwd_for_match /
# is_workflow_subagent helpers) AND lib/agent-binding-plan.sh (the PLAN-derivation
# layer: ab_validate_chain / ab_plan_packet_allowed / ab_plan_packet_write_capable /
# ab_plan_packet_knowledge_refs — split out to keep this file under the 500-line
# gate, called by the verdict below).
#
# Why this exists (distinct from workflow-binding.sh): a native Dynamic Workflow
# subagent runs in a worktree and is bound by cwd. An orchestration Specialist Implementer
# is instead spawned via the Agent tool by its Axis Lead, shares the main checkout
# (runtime_kind:subagent, isolation:none), has NO Bash/MultiEdit/Agent, and is bound
# LAZILY at its FIRST Write/Edit. The Axis Lead injects a bearer marker
#   BRAINIAC_AGENT_BINDING run_id=<id> packet_id=<id> nonce=<hex>
# into the specialist's prompt; pretool-agent-envelope-guard.sh reads it from the
# specialist's OWN isolated transcript, proves nonce possession against a run-scoped
# pending-spawns.ndjson, revalidates the payload hash chain + allowed_paths AGAINST
# THE APPROVED PLAN (the binding/pending allowed_paths are caches, never the source
# of truth), writes the binding, and only then allows a write inside allowed_paths.
# A write outside allowed_paths, a missing/invalid nonce, or any hash drift => block.
#
# Binding source (SEC-1): the runtime hands a subagent's PreToolUse(Write)
# the PARENT-session transcript, NOT the subagent's isolated file. The marker therefore
# MUST be read from <session>/subagents/agent-<agent_id>.jsonl (built here from a safe
# agent_id, never trusted from the runtime spelling), and the binding key is aid:<id>
# only — NEVER tp:<hash(transcript)> (that would key, and govern, the parent/main
# session). The verdict governs ONLY a subagent under active orchestration; a generic
# subagent (no marker in its own transcript) and a parent/main session pass through.
#
# shellcheck disable=SC2148
# (no shebang on purpose; lib is sourced, not executed standalone)


# === ab_runs_dir(root) — the run store root (override via BRAINIAC_RUNS_DIR) ===
ab_runs_dir() {
    local root="${1:-}"
    printf '%s' "${BRAINIAC_RUNS_DIR:-$root/.brainiac/runs}"
}


# === ab_binding_key(id) — stable per-subagent key ===
# Returns "aid:<id>" ONLY for a safe id; otherwise return 1 (no key). NEVER derives a
# key from the transcript path: the runtime hands the PARENT transcript to a subagent
# write, so a tp:<sha(transcript)> fallback would key — and govern — the parent/main
# session (the over-block vector). A caller with no safe id is not
# a governed leaf (verdict => normal).
ab_binding_key() {
    local id="${1:-}"
    { [[ -n "$id" ]] && _wf_safe_id "$id"; } || return 1
    printf 'aid:%s' "$id"
}


# === ab_resolve_subagent(transcript, agent_id) — locate the subagent's OWN transcript ===
# Echoes "<eff_id>\t<sub_tp>" (TAB) where sub_tp is the subagent's isolated transcript
# file and eff_id is the effective binding id; returns 1 if this is not a resolvable
# subagent. SEC-1: the path is BUILT from a safe id, never trusted from the runtime
# spelling. Two accepted input shapes:
#   - PARENT form (current runtime): transcript=<sess>.jsonl + a safe agent_id =>
#     sub_tp = "<sess>/subagents/agent-<agent_id>.jsonl" (eff_id = agent_id).
#   - DIRECT form (future runtime): transcript is already a subagents/agent-<X>.jsonl;
#     accepted ONLY via an anchored regex whose id segment is _wf_safe_id-shaped (no
#     '/'/'..'), and — when agent_id is present — the basename MUST equal
#     "agent-<agent_id>.jsonl" (stop agent_id=A reading agent-B.jsonl).
# Any '..' anywhere => reject. The file must exist ([-f]); otherwise return 1.
ab_resolve_subagent() {
    local transcript="${1:-}" agent_id="${2:-}" tpn id stem sub_tp
    [[ -n "$transcript" ]] || return 1
    tpn=$(printf '%s' "$transcript" | tr '\\' '/')
    case "$tpn" in *..*) return 1 ;; esac
    if [[ "$tpn" =~ ^(.+)/subagents/agent-([A-Za-z0-9][A-Za-z0-9._-]*)\.jsonl$ ]]; then
        id="${BASH_REMATCH[2]}"
        _wf_safe_id "$id" || return 1
        if [[ -n "$agent_id" ]]; then
            _wf_safe_id "$agent_id" || return 1
            [[ "$id" == "$agent_id" ]] || return 1
        fi
        sub_tp="$tpn"
    else
        { [[ -n "$agent_id" ]] && _wf_safe_id "$agent_id"; } || return 1
        id="$agent_id"
        stem="${tpn%.jsonl}"
        sub_tp="$stem/subagents/agent-$id.jsonl"
    fi
    case "$sub_tp" in *..*) return 1 ;; esac
    [[ -f "$sub_tp" ]] || return 1
    printf '%s\t%s' "$id" "$sub_tp"
}


# === ab_extract_markers(transcript) — read ALL bearer markers from the prompt ===
# The Axis Lead injects exactly: BRAINIAC_AGENT_BINDING run_id=<id> packet_id=<id> nonce=<hex>
# into the specialist's prompt, which appears verbatim in its isolated transcript. Echoes one
# "run_id<TAB>packet_id<TAB>nonce" line PER well-formed marker (NOT head -1): the subagent's
# transcript can legitimately carry more than one marker (e.g. it READ a file containing the
# literal token), so the caller must select the one that proves an ACTIVE pending-spawn rather
# than trusting position. Only safe-id run_id/packet_id and a hex nonce are emitted.
ab_extract_markers() {
    local transcript="$1" line run_id packet_id nonce
    local re='^BRAINIAC_AGENT_BINDING run_id=([A-Za-z0-9._-]+) packet_id=([A-Za-z0-9._-]+) nonce=([A-Fa-f0-9]+)$'
    [[ -f "$transcript" ]] || return 1
    # Field split via pure-bash regex over the grep-normalized shape (was 3 greps +
    # 3 seds PER marker — a fork-storm on Git Bash MSYS where the verdict runs at
    # every subagent write). The outer grep still defines/anchors the marker grammar.
    grep -oE 'BRAINIAC_AGENT_BINDING run_id=[A-Za-z0-9._-]+ packet_id=[A-Za-z0-9._-]+ nonce=[A-Fa-f0-9]+' "$transcript" 2>/dev/null \
    | while IFS= read -r line; do
        [[ "$line" =~ $re ]] || continue
        run_id="${BASH_REMATCH[1]}"
        packet_id="${BASH_REMATCH[2]}"
        nonce="${BASH_REMATCH[3]}"
        _wf_safe_id "$run_id" || continue
        _wf_safe_id "$packet_id" || continue
        [[ -n "$nonce" ]] || continue
        printf '%s\t%s\t%s\n' "$run_id" "$packet_id" "$nonce"
    done
}


# === ab_text_has_marker(file) — is there ANY well-formed bearer marker in <file>? ===
ab_text_has_marker() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    grep -qE 'BRAINIAC_AGENT_BINDING run_id=[A-Za-z0-9._-]+ packet_id=[A-Za-z0-9._-]+ nonce=[A-Fa-f0-9]+' "$f" 2>/dev/null
}


# === _ab_file_mtime(file) — epoch mtime, cross-platform (GNU `stat -c` / BSD `stat -f`) ===
_ab_file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}


# === ab_run_is_active(runs_dir) — is at least one orchestration run LIVE? ===
# Replaces the broad ab_orchestration_live. A run is LIVE iff it has a pending-spawns.ndjson
# with >=1 nonce_sha256 entry, is NOT closed (run.json.status == "closed" is the ONLY close
# authority — closed_at is metadata, never self-closing), AND its most-recent signal-file mtime
# is within BRAINIAC_RUN_TTL_SECONDS (default 86400). Activity = MAX mtime over the run's FILES
# {pending-spawns, agent-bindings, run.json, sessions.json} — NOT the directory mtime (an append
# to a file does not bump the dir mtime, so a long run would falsely look stale). Any live run => 0.
ab_run_is_active() {
    local runs_dir="$1" rd ps rj status f m now ttl newest
    ttl="${BRAINIAC_RUN_TTL_SECONDS:-86400}"; [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=86400
    now=$(date +%s 2>/dev/null); [[ "$now" =~ ^[0-9]+$ ]] || return 1
    for rd in "$runs_dir"/*/; do
        [[ -d "$rd" ]] || continue
        ps="$rd/pending-spawns.ndjson"
        [[ -f "$ps" ]] || continue
        grep -qE '"nonce_sha256"' "$ps" 2>/dev/null || continue
        rj="$rd/run.json"; status=""
        [[ -f "$rj" ]] && status=$(jq -r '.status // ""' "$rj" 2>/dev/null)
        [[ "$status" == "closed" ]] && continue
        newest=0
        for f in "$ps" "$rd/agent-bindings.ndjson" "$rj" "$rd/sessions.json"; do
            [[ -f "$f" ]] || continue
            m=$(_ab_file_mtime "$f"); [[ "$m" =~ ^[0-9]+$ ]] || continue
            [[ "$m" -gt "$newest" ]] && newest="$m"
        done
        [[ "$newest" -gt 0 ]] || continue
        [[ $(( now - newest )) -lt "$ttl" ]] && return 0
    done
    return 1
}


# === ab_find_pending_spawn(runs_dir, run_id, packet_id, nonce) — prove nonce ===
# Scan .brainiac/runs/<run_id>/pending-spawns.ndjson for a line whose packet_id
# matches AND whose nonce_sha256 == sha256(nonce). Echoes the matching JSON line
# (or nothing). This is the bearer-credential check: only the Axis Lead that wrote
# the pending-spawn knew the nonce and injected it into the prompt.
ab_find_pending_spawn() {
    local runs_dir="$1" run_id="$2" packet_id="$3" nonce="$4"
    _wf_safe_id "$run_id" || return 1
    local file="$runs_dir/$run_id/pending-spawns.ndjson"
    [[ -f "$file" ]] || return 1
    local want_sha out
    want_sha=$(printf '%s' "$nonce" | _wf_sha256_stdin)
    [[ -n "$want_sha" ]] || return 1
    # ONE jq scans the whole NDJSON (was 3 jq spawns PER LINE). Raw mode + try/catch
    # keeps the tolerance for malformed lines (skip, never abort); first match wins,
    # exactly like the line loop it replaces.
    out=$(jq -cR --arg p "$packet_id" --arg s "$want_sha" \
        'try fromjson catch empty | select(.packet_id == $p and .nonce_sha256 == $s)' \
        "$file" 2>/dev/null | head -1)
    out="${out//$'\r'/}"
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
    return 0
}


# ab_path_in_allowed(file_rel, allowed_json) lives in agent-binding-plan.sh (sourced
# BEFORE this lib): it is a plan-derived decision helper, and the split keeps this
# file under the 500-line Clean Code gate.


# === ab_read_binding(runs_dir, run_id, key) — last binding line for key ===
ab_read_binding() {
    local runs_dir="$1" run_id="$2" key="$3"
    _wf_safe_id "$run_id" || return 1
    local file="$runs_dir/$run_id/agent-bindings.ndjson" out=""
    [[ -f "$file" ]] || return 1
    # ONE jq scans the whole NDJSON (was 2 jq spawns PER LINE); malformed lines are
    # skipped via try/catch; LAST match wins (append-only store — the newest binding
    # for the key is authoritative), exactly like the line loop it replaces.
    out=$(jq -cR --arg k "$key" \
        'try fromjson catch empty | select(.key == $k)' "$file" 2>/dev/null | tail -1)
    out="${out//$'\r'/}"
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}


# === ab_find_binding_for_key(runs_dir, key) — the SINGLE run binding this key ===
# Scans every run store for a binding under <key>. Echoes the binding line + return 0 when
# EXACTLY ONE run holds it; return 1 when none; return 2 when MORE THAN ONE distinct run
# holds it (_wf_safe_id constrains agent_id charset, not uniqueness/lifetime across runs —
# two runs binding the same aid:<id> is an ambiguous cross-run collision the caller must
# fail-closed on, never first-match-wins).
ab_find_binding_for_key() {
    local runs_dir="$1" key="$2" rd run b found="" count=0
    for rd in "$runs_dir"/*/; do
        [[ -d "$rd" ]] || continue
        run=$(basename "$rd")
        b=$(ab_read_binding "$runs_dir" "$run" "$key") || continue
        count=$((count+1)); found="$b"
    done
    [[ "$count" -eq 0 ]] && return 1
    [[ "$count" -gt 1 ]] && return 2
    printf '%s' "$found"
    return 0
}


# === ab_write_binding(runs_dir, run_id, key, packet_id, payload_sha, allowed_json) ===
# Append-only with an atomic mkdir lock (NDJSON stays one-valid-JSON-per-line even
# under two concurrent lazy-binds). Best-effort: a lock/IO failure is non-fatal to
# the caller's verdict (the binding is a cache; the plan revalidation is authoritative).
ab_write_binding() {
    local runs_dir="$1" run_id="$2" key="$3" packet_id="$4" payload_sha="$5" allowed_json="$6"
    _wf_safe_id "$run_id" || return 1
    local dir="$runs_dir/$run_id"
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 1
    local file="$dir/agent-bindings.ndjson" lock="$dir/.agent-bindings.lock" line
    line=$(jq -c -n --arg k "$key" --arg r "$run_id" --arg p "$packet_id" \
        --arg s "$payload_sha" --argjson ap "$allowed_json" \
        '{key:$k, run_id:$r, packet_id:$p, payload_sha256:$s, allowed_paths:$ap}' 2>/dev/null) || return 1
    local tries=0
    while ! mkdir "$lock" 2>/dev/null; do
        tries=$((tries+1)); [[ "$tries" -gt 50 ]] && break
        sleep 0.05 2>/dev/null || true
    done
    printf '%s\n' "$line" >> "$file" 2>/dev/null
    rmdir "$lock" 2>/dev/null || true
    return 0
}


# === agent_binding_verdict(agent_id, transcript, cwd, root, file_path[, agent_type]) ===
# THE entry point for pretool-agent-envelope-guard.sh. Pure (no exit). Echoes one of:
#   normal                      — not a governed leaf (parent/main session, generic subagent, or
#                                 a Workflow-tool subagent delegated to the workflow-binding)
#   allow<TAB>run_id            — bound + file_path INSIDE allowed_paths (plan-revalidated)
#   block<TAB>reason            — marker/binding present but invalid, write outside allowed_paths,
#                                 or a governed Specialist under a LIVE run whose binding can't be
#                                 proven (the fail-close family — the hook may downgrade to advisory)
#
# Flow: (0a) exclude Workflow-tool subagents (cwd-keyed workflow-binding governs them —
# they must never reach the fail-close). (0b) governed_ctx = non-wf + a LIVE run + the PARENT
# transcript carries >=1 marker (the signal that this context spawns bound leaves — it is what
# keeps a write-capable Axis Lead / generic subagent OUT of the fail-close).
# Resolve the subagent's OWN transcript + a safe key (aid:<id>, never tp:<parent>); an unsafe id
# in a governed_ctx => INVALID_AGENT_ID, otherwise no key => normal. Normalize the target (Bug B).
# (A) read markers from the ISOLATED transcript with a BOUNDED RETRY for the materialization race
# (Bug A), pick the ONE proving an active pending-spawn, validate hash chain + allowed_paths +
# write_capable AGAINST THE PLAN, bind, decide. (B) else an already-bound specialist's 2nd write —
# revalidate the run-scoped binding (a valid prior binding always wins). (C) else, in a governed_ctx,
# fail-close with a race-specific reason (MISSING / NOT_MATERIALIZED). (D) else normal.
agent_binding_verdict() {
    local agent_id="$1" transcript="$2" cwd="$3" root="$4" file_path="$5" agent_type="${6:-}"
    local runs_dir; runs_dir=$(ab_runs_dir "$root")

    # (0a) Workflow-tool exclusion: a Workflow-tool subagent is governed by
    # the cwd-keyed workflow-binding, NOT this layer. Detect via is_workflow_subagent (agent_type /
    # worktree cwd / wf transcript) OR a sibling isolated transcript under
    # <sess>/subagents/workflows/*/agent-<id>.jsonl. A wf subagent is delegated (=> normal), so the
    # fail-close never usurps that authority.
    local is_wf=0
    if is_workflow_subagent "$agent_type" "$cwd" "$transcript"; then is_wf=1; fi
    if [[ "$is_wf" -eq 0 && -n "$agent_id" ]] && _wf_safe_id "$agent_id"; then
        local _ss _wfg
        _ss=$(printf '%s' "$transcript" | tr '\\' '/'); _ss="${_ss%.jsonl}"
        for _wfg in "$_ss"/subagents/workflows/*/agent-"$agent_id".jsonl; do
            [[ -f "$_wfg" ]] && { is_wf=1; break; }
        done
    fi

    # (0b) Governed context: non-wf, a LIVE orchestration run, AND the parent transcript carries a
    # marker. This is the guard that the fail-close below must NOT exceed: a
    # write-capable Axis Lead (tools include Write/Edit, NO injected marker) or a generic subagent
    # whose parent context has no marker stays OUT of the fail-close (=> normal). Computed once; the
    # parent grep + run scan are skipped entirely for a parent/main session (no agent_id).
    local governed_ctx=0
    if [[ "$is_wf" -eq 0 && -n "$agent_id" ]] && ab_run_is_active "$runs_dir" && ab_text_has_marker "$transcript"; then
        governed_ctx=1
    fi

    # (0c) Resolve the subagent's OWN transcript + the safe binding key (best-effort first pass).
    local resolved eff_id="" sub_tp=""
    resolved=$(ab_resolve_subagent "$transcript" "$agent_id") && IFS=$'\t' read -r eff_id sub_tp <<< "$resolved"
    local key=""
    if [[ -n "$eff_id" ]]; then key="aid:$eff_id"
    elif [[ -n "$agent_id" ]] && _wf_safe_id "$agent_id"; then key="aid:$agent_id"; fi
    if [[ -z "$key" ]]; then
        # A present-but-UNSAFE agent_id in a governed context cannot be keyed safely => fail-close
        # (never silent normal). A wf subagent or a non-governed session passes through.
        if [[ "$governed_ctx" -eq 1 && -n "$agent_id" ]] && ! _wf_safe_id "$agent_id"; then
            printf 'block\tINVALID_AGENT_ID: agent_id is not a safe identifier in a governed run context'; return 0
        fi
        echo "normal"; return 0
    fi

    # Normalize the write target to a repo-relative path (Bug B: drive-case D:/ vs d:/ vs /d/).
    # _normalize_cwd_for_match unifies the three forms of the SAME root; the anti-bypass (a file_rel
    # still abs/drive/.. after normalize stays rejected) lives in ab_path_in_allowed.
    local file_norm file_rel root_norm
    file_norm=$(_normalize_cwd_for_match "$file_path")
    root_norm=$(_normalize_cwd_for_match "$root"); root_norm="${root_norm%/}"
    if [[ "$file_norm" == "$root_norm/"* ]]; then file_rel="${file_norm#"$root_norm"/}"; else file_rel="$file_norm"; fi

    # (A) Governing marker from the ISOLATED transcript, with a bounded retry for the
    # materialization race: at the FIRST write the runtime may not have flushed the marker
    # (or created the isolated file) yet. NFR: we DO NOT fork `sleep` (MSYS `sleep` rounds up to
    # ~0.3s, wrecking the <500ms budget) — instead poll a cheap [[ -f ]] (case i: file absent) or
    # grep (case ii: file present, marker not yet written) and wait via `_ab_nap` (a fork-free
    # short sleep — see its definition in agent-binding-plan.sh). The retry runs ONLY in a
    # governed_ctx (a single pass otherwise — zero added latency for a normal/idle session).
    local cand_tp=""
    if [[ -z "$sub_tp" && -n "$agent_id" ]] && _wf_safe_id "$agent_id"; then
        local _stem; _stem=$(printf '%s' "$transcript" | tr '\\' '/'); _stem="${_stem%.jsonl}"
        cand_tp="$_stem/subagents/agent-$agent_id.jsonl"
        case "$cand_tp" in *..*) cand_tp="" ;; esac
    fi
    local attempts=0 max_attempts=6 had_marker_text=0
    while : ; do
        # (re)resolve only once the isolated file has appeared (cheap -f test, no resolver fork).
        if [[ -z "$sub_tp" && -n "$cand_tp" && -f "$cand_tp" ]]; then
            resolved=$(ab_resolve_subagent "$transcript" "$agent_id") && IFS=$'\t' read -r eff_id sub_tp <<< "$resolved" || { eff_id=""; sub_tp=""; }
        fi
        if [[ -n "$sub_tp" ]] && ab_text_has_marker "$sub_tp"; then
            local m_run m_pkt m_nonce pending matched=0 g_run="" g_pkt="" g_pending=""
            while IFS=$'\t' read -r m_run m_pkt m_nonce; do
                [[ -z "$m_run" ]] && continue
                pending=$(ab_find_pending_spawn "$runs_dir" "$m_run" "$m_pkt" "$m_nonce") || continue
                matched=$((matched+1)); g_run="$m_run"; g_pkt="$m_pkt"; g_pending="$pending"
            done < <(ab_extract_markers "$sub_tp")

            if [[ "$matched" -gt 1 ]]; then
                printf 'block\tambiguous binding: %d markers prove active pending-spawns' "$matched"; return 0
            fi
            if [[ "$matched" -eq 1 ]]; then
                local pend_sha allowed plan_path wcap
                pend_sha=$(jq -r '.payload_sha256 // ""' <<< "$g_pending" 2>/dev/null)
                plan_path=$(ab_validate_chain "$root" "$runs_dir" "$g_run" "$g_pkt" "$pend_sha") \
                    || { printf 'block\tapproval hash chain failed for run %s (payload drift / unapproved envelope)' "$g_run"; return 0; }
                allowed=$(ab_plan_packet_allowed "$root/$plan_path" "$g_pkt") \
                    || { printf 'block\tpacket %s not found in approved plan (or no allowed_paths)' "$g_pkt"; return 0; }
                wcap=$(ab_plan_packet_write_capable "$root/$plan_path" "$g_pkt")
                [[ "$wcap" == "true" ]] || { printf 'block\tNOT_WRITE_CAPABLE: packet %s is not write_capable in the approved plan' "$g_pkt"; return 0; }
                ab_write_binding "$runs_dir" "$g_run" "$key" "$g_pkt" "$pend_sha" "$allowed"
                if ab_path_in_allowed "$file_rel" "$allowed"; then printf 'allow\t%s' "$g_run"; else printf 'block\twrite outside allowed_paths: %s' "$file_rel"; fi
                return 0
            fi
            # Marker text present but no nonce proves an active pending => forged/drifted => suspect;
            # stop retrying (this is not a race) and block after the loop.
            had_marker_text=1; break
        fi
        attempts=$((attempts+1))
        if [[ "$governed_ctx" -eq 1 && "$attempts" -lt "$max_attempts" ]]; then
            _ab_nap 0.05
            continue
        fi
        break
    done
    if [[ "$had_marker_text" -eq 1 ]]; then
        printf 'block\tmarker present but no active pending-spawn proves it (nonce unproven)'; return 0
    fi

    # (B) Already-bound specialist's 2nd+ write — revalidate the run-scoped binding against the
    # plan (a key bound in >1 run => ambiguous block). A valid prior binding ALWAYS wins
    # the fail-close below.
    local binding rc
    binding=$(ab_find_binding_for_key "$runs_dir" "$key"); rc=$?
    if [[ "$rc" -eq 2 ]]; then
        printf 'block\tambiguous binding: agent key %s bound in more than one run' "$key"; return 0
    fi
    if [[ "$rc" -eq 0 && -n "$binding" ]]; then
        local b_run="" b_pkt="" b_sha="" allowed plan_path wcap2
        # ONE jq for the three binding fields (was 3 spawns — this is the 2nd+-write hot path).
        IFS=$'\037' read -r b_run b_pkt b_sha < <(jq -r '
            [ ((.run_id // "") | tostring), ((.packet_id // "") | tostring),
              ((.payload_sha256 // "") | tostring) ] | join("")' <<< "$binding" 2>/dev/null) || true
        b_run="${b_run//$'\r'/}"; b_pkt="${b_pkt//$'\r'/}"; b_sha="${b_sha//$'\r'/}"
        plan_path=$(ab_validate_chain "$root" "$runs_dir" "$b_run" "$b_pkt" "$b_sha") \
            || { printf 'block\tbinding revalidation failed for run %s (plan/payload drift)' "$b_run"; return 0; }
        allowed=$(ab_plan_packet_allowed "$root/$plan_path" "$b_pkt") \
            || { printf 'block\tpacket %s no longer in approved plan' "$b_pkt"; return 0; }
        wcap2=$(ab_plan_packet_write_capable "$root/$plan_path" "$b_pkt")
        [[ "$wcap2" == "true" ]] || { printf 'block\tNOT_WRITE_CAPABLE: packet %s is not write_capable in the approved plan' "$b_pkt"; return 0; }
        if ab_path_in_allowed "$file_rel" "$allowed"; then printf 'allow\t%s' "$b_run"; else printf 'block\twrite outside allowed_paths: %s' "$file_rel"; fi
        return 0
    fi

    # (C) Fail-closed (Bug A): a governed leaf under a LIVE run whose binding could not be proven —
    # neither a governing marker (transcript missing OR marker not materialized within the retry
    # window) nor a prior binding. Gated by governed_ctx so wf subagents (0a) and non-governed
    # write-capable subagents never reach here. Distinct reasons feed the E2E; the hook's
    # BRAINIAC_AGENT_UNBOUND=advisory may downgrade ONLY these to a warning.
    if [[ "$governed_ctx" -eq 1 ]]; then
        if [[ -z "$sub_tp" ]]; then
            printf 'block\tSUBAGENT_TRANSCRIPT_MISSING: agent %s isolated transcript absent in a governed run (materialization race)' "$agent_id"; return 0
        fi
        printf 'block\tSUBAGENT_MARKER_NOT_MATERIALIZED: agent %s transcript carries no proven binding marker in a governed run' "$agent_id"; return 0
    fi

    # (D) No governed context => generic subagent / Axis Lead / normal session => pass through.
    echo "normal"
    return 0
}


# === agent_bound_in_allowed(agent_id, transcript, cwd, root, file_path) — gate helper ===
# Lighter check for the context-load / context-research / knowledge gates, which run
# AFTER the envelope-guard (chain order). Returns 0 iff there is a VALID binding for
# this key whose plan-revalidated allowed_paths contain file_path. Does NOT lazy-bind
# (the envelope-guard already did). Echoes "run_id" on success.
agent_bound_in_allowed() {
    local agent_id="$1" transcript="$2" cwd="$3" root="$4" file_path="$5" agent_type="${6:-}"
    local v; v=$(agent_binding_verdict "$agent_id" "$transcript" "$cwd" "$root" "$file_path" "$agent_type" 2>/dev/null)
    case "${v%%$'\t'*}" in
        allow) printf '%s' "$(printf '%s' "$v" | cut -f2)"; return 0 ;;
        *) return 1 ;;
    esac
}


# === agent_bound_knowledge_has(agent_id, transcript, cwd, root, file_path, knowledge_path) ===
# For the knowledge-gate conditional early-exit: returns 0 iff this is a
# valid bound-in-allowed write AND the bound packet declares <knowledge_path> in its
# machine-readable knowledge_refs. Otherwise the knowledge-gate applies normally.
agent_bound_knowledge_has() {
    local agent_id="$1" transcript="$2" cwd="$3" root="$4" file_path="$5" kpath="$6" agent_type="${7:-}"
    agent_bound_in_allowed "$agent_id" "$transcript" "$cwd" "$root" "$file_path" "$agent_type" >/dev/null 2>&1 || return 1
    local runs_dir resolved eff_id="" sub_tp key binding b_run b_pkt plan_path refs
    runs_dir=$(ab_runs_dir "$root")
    resolved=$(ab_resolve_subagent "$transcript" "$agent_id") && IFS=$'\t' read -r eff_id sub_tp <<< "$resolved"
    if [[ -n "$eff_id" ]]; then key="aid:$eff_id"
    elif [[ -n "$agent_id" ]] && _wf_safe_id "$agent_id"; then key="aid:$agent_id"
    else return 1; fi
    binding=$(ab_find_binding_for_key "$runs_dir" "$key") || return 1
    b_run=$(jq -r '.run_id // ""'    <<< "$binding" 2>/dev/null)
    b_pkt=$(jq -r '.packet_id // ""' <<< "$binding" 2>/dev/null)
    plan_path=$(ab_validate_chain "$root" "$runs_dir" "$b_run" "$b_pkt" "$(jq -r '.payload_sha256 // ""' <<< "$binding" 2>/dev/null)") || return 1
    refs=$(ab_plan_packet_knowledge_refs "$root/$plan_path" "$b_pkt") || return 1
    jq -e --arg k "$kpath" 'index($k) != null' <<< "$refs" >/dev/null 2>&1
}


# End of library — no top-level code follows. Caller resumes.
