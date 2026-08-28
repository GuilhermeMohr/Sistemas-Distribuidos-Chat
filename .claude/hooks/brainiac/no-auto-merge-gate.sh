#!/bin/bash
# Brainiac Context — No Auto-Merge Gate (PreToolUse hook for Bash).
#
# Blocks `git merge <ref>` and `gh pr merge` while a Master Orchestration Run is ACTIVE (a
# run.json with >=1 non-completed packet AND recent activity). A merge mid-run is a false-green:
# it would land work before the integrate closeout attested the run. Also hard-blocks
# `git push --force ... main` UNCONDITIONALLY (destructive). Régua anti-ritual: hard
# block ONLY for real risk (false-green / destructive); everything else is a warning or a no-op.
#
# Parser, NOT naive grep (so it does not over-block): `git merge-base`, `git fmt-merge-msg`,
# `git merge --abort|--continue|--quit`, and plain `git push` are ALLOWED. A STALE/orphan run
# (open packets but no recent activity — no session lifecycle exists to confirm liveness) yields
# a WARNING, never a permanent block: an abandoned run.json
# must not lock merges forever (that gate would become a candidate for being disabled).
#
# Detection is ANCHORED AT COMMAND POSITION (token 0, or after a separator &&/;/||/|/& or a wrapper
# command/env/exec/…): so `echo git merge x` (git as an argument, not a command) is NOT matched.
#
# Alias scope (hard-block only when DETERMINISTIC + low false-positive):
#   - INLINE alias injection `git -c alias.X=merge X ...` / `-c alias.Y="push --force … main" Y` IS
#     resolved and blocked — the dangerous verb is present in the command string itself (deterministic).
#   - EXTERNAL/configured aliases (defined in ~/.gitconfig, invoked as a bare `git X`) are OUT OF
#     SCOPE: resolving them would require reading git config — environment-dependent (non-deterministic
#     across machines) and an extra attack surface. This is a documented limit, not a silent gap.
#     Defense-in-depth: the human merge + integrate closeout remain the real attestation.
#
# Env: BRAINIAC_RUNS_DIR (runs root; default <cwd>/.brainiac/runs),
#      BRAINIAC_RUN_ACTIVE_WINDOW_SECONDS (active vs stale threshold; default 21600 = 6h).
#
# NB: pipefail INTENTIONALLY OFF (MSYS2 jq+pipe rationale, same as sibling gates); set -u kept.

set -u

# === 1. Parse input — act only on Bash ===
input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
[[ "$tool_name" == "Bash" ]] || exit 0
bash_command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
project_dir=$(printf '%s' "$input" | jq -r '.cwd // empty')
[[ -z "$project_dir" ]] && project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
[[ -n "${bash_command//[[:space:]]/}" ]] || exit 0

# Newlines/tabs → spaces so a merge on a later line is still tokenized (line-oriented match would
# miss it). Quotes/heredocs remain an accepted heuristic limit (documented).
cmd_norm=$(printf '%s' "$bash_command" | tr '\n\t' '  ')

# === 2. i18n messages (stderr only; inline fallback) ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANG_VAL="${BRAINIAC_LANG:-en}"
[[ "$LANG_VAL" != "en" && "$LANG_VAL" != "pt-BR" ]] && LANG_VAL="en"
if [[ -f "$SCRIPT_DIR/messages/${LANG_VAL}.sh" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/messages/${LANG_VAL}.sh"
elif [[ -f "$SCRIPT_DIR/messages/en.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/messages/en.sh"
fi
: "${MSG_NOMERGE_HEADER:=[Brainiac No Auto-Merge Gate]}"
: "${MSG_NOMERGE_FORCE:=Blocked: destructive force-push to main.}"
: "${MSG_NOMERGE_ACTIVE:=Blocked: merge during an ACTIVE orchestration run (false-green risk — let the integrate closeout attest first).}"
: "${MSG_NOMERGE_STALE:=Warning: an open orchestration run exists but is stale (no recent activity) — merge allowed; consider closing the run.}"
: "${MSG_NOMERGE_HINT:=Human merge only after the integrate closeout attests the run. Allowed mid-run: git merge --abort/--continue/--quit, git merge-base. Close/clean stale runs under .brainiac/runs/.}"

# === 3. Command classifiers (subcommand parser, not naive grep) ===
# Tokens live in TOKS[]/N (populated in §5 from cmd_norm). The parser SKIPS git/gh GLOBAL options
# before the subcommand, so `git -C . merge`, `git --no-pager merge`, `git --git-dir=.git push`,
# `gh -R o/r pr merge` are NOT bypasses (the subcommand is resolved, not assumed to be token[i+1]).

# _is_cmd_pos <i> — true if TOKS[i] is in COMMAND position: index 0, or after a separator
# (&&/;/||/|/&/(/{ ) or a wrapper (command/env/exec/…). Leading env assignments (FOO=bar) are
# transparent. So `echo git merge x` is NOT a command (git is echo's arg) → no false positive.
_is_cmd_pos() {
    local i="$1" j p
    ((i == 0)) && return 0
    j=$((i - 1))
    while ((j >= 0)); do
        p="${TOKS[$j]}"
        case "$p" in
            "&&"|";"|"||"|"|"|"&"|"("|"{") return 0 ;;
            command|builtin|exec|time|nohup|sudo|env|then|do|else) return 0 ;;
            *=*) j=$((j - 1)); continue ;;   # leading VAR=value env-assignment — transparent
            *) return 1 ;;
        esac
    done
    return 0
}

# _git_sub_idx <start> — echo the index of the git subcommand at/after <start>, skipping global
# options (value-taking ones — -C -c --git-dir --work-tree --namespace --exec-path --super-prefix
# --config-env — consume the next token; `--opt=value` and valueless flags consume just themselves).
# Echoes -1 when no subcommand follows.
_git_sub_idx() {
    local j="$1"
    while ((j < N)); do
        case "${TOKS[$j]}" in
            -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env) j=$((j + 2)) ;;
            -*) j=$((j + 1)) ;;
            *) echo "$j"; return ;;
        esac
    done
    echo "-1"
}

# _cmd_is_merge — true for a real `git merge <ref>` or `gh pr merge` (globals skipped). "merge"
# must be the RESOLVED subcommand (so "merge-base"/"fmt-merge-msg" never match) and not --abort/--continue/--quit.
_cmd_is_merge() {
    local i si j
    for ((i = 0; i < N; i++)); do
        if [[ "${TOKS[$i]}" == "git" ]] && _is_cmd_pos "$i"; then
            si=$(_git_sub_idx $((i + 1)))
            if [[ "$si" -ge 0 && "${TOKS[$si]}" == "merge" ]]; then
                case "${TOKS[$((si + 1))]:-}" in
                    --abort|--continue|--quit) ;;   # in-progress merge control — safe
                    *) return 0 ;;
                esac
            fi
        elif [[ "${TOKS[$i]}" == "gh" ]] && _is_cmd_pos "$i"; then
            j=$((i + 1))
            while ((j < N)); do
                case "${TOKS[$j]}" in
                    -R|--repo|--hostname) j=$((j + 2)) ;;       # gh global opts that take a value
                    -*) j=$((j + 1)) ;;
                    pr) [[ "${TOKS[$((j + 1))]:-}" == "merge" ]] && return 0; break ;;
                    *) break ;;
                esac
            done
        fi
    done
    return 1
}

# _cmd_is_force_push_main — true for `git [globals] push [opts] (--force|-f|--force-with-lease) [opts] main`.
# Globals skipped; the arg scan stops at a command separator so a later `main` is not miscounted.
_cmd_is_force_push_main() {
    local i si k hf hm
    for ((i = 0; i < N; i++)); do
        [[ "${TOKS[$i]}" == "git" ]] && _is_cmd_pos "$i" || continue
        si=$(_git_sub_idx $((i + 1)))
        [[ "$si" -ge 0 && "${TOKS[$si]}" == "push" ]] || continue
        hf=0; hm=0
        for ((k = si + 1; k < N; k++)); do
            case "${TOKS[$k]}" in
                "&&"|";"|"|"|"||") break ;;
                --force|-f|--force-with-lease|--force-with-lease=*) hf=1 ;;
                main|*:main|*/main) hm=1 ;;
            esac
        done
        [[ "$hf" -eq 1 && "$hm" -eq 1 ]] && return 0
    done
    return 1
}

# _alias_body <git_idx> <want> — scan the option span of the git invocation at <git_idx> (up to its
# resolved subcommand) for an INLINE alias injection `-c alias.NAME=<body>` / `-cNAME=<body>`. Returns
# 0 if any alias body's first word matches <want> (exact, e.g. "merge" — not "merge-base"; or prefix
# "push" via the caller). Resolves only command-string-visible aliases (external .gitconfig out of scope).
_git_alias_body_matches() {
    local gi="$1" want="$2" j sub val body end
    sub=$(_git_sub_idx $((gi + 1)))
    end="$N"; [[ "$sub" -ge 0 ]] && end="$sub"
    for ((j = gi + 1; j < end; j++)); do
        case "${TOKS[$j]}" in
            -c)  val="${TOKS[$((j + 1))]:-}" ;;
            -c*) val="${TOKS[$j]#-c}" ;;
            *)   continue ;;
        esac
        [[ "$val" == alias.*=* ]] || continue
        body="${val#alias.*=}"; body="${body#[\"\']}"; body="${body%[\"\']}"
        case "$want" in
            merge) [[ "$body" == "merge" ]] && return 0 ;;   # exact: merge-base/merge-file are read-only
            push)  [[ "$body" == push* ]] && return 0 ;;
        esac
    done
    return 1
}

# _cmd_string_has_force_main — true if any token (quotes stripped) is a force flag AND any is a main
# target. Used with a push-alias injection: the alias body is `push` but `--force … main` are scattered
# tokens (read -a does not honor quotes), so the force/main signal is searched across the whole command.
_cmd_string_has_force_main() {
    local k t hf=0 hm=0
    for ((k = 0; k < N; k++)); do
        t="${TOKS[$k]//[\"\']/}"
        case "$t" in --force|-f|--force-with-lease|--force-with-lease=*) hf=1 ;; esac
        case "$t" in main|*:main|*/main) hm=1 ;; esac
    done
    [[ "$hf" -eq 1 && "$hm" -eq 1 ]]
}

# _has_merge_alias_injection — true if a git in command position defines an inline `merge` alias.
_has_merge_alias_injection() {
    local i
    for ((i = 0; i < N; i++)); do
        [[ "${TOKS[$i]}" == "git" ]] && _is_cmd_pos "$i" || continue
        _git_alias_body_matches "$i" merge && return 0
    done
    return 1
}

# _has_force_push_main_alias_injection — true if a git in command position defines an inline `push`
# alias AND the command carries a force flag + a main target (destructive force-push-to-main via alias).
_has_force_push_main_alias_injection() {
    local i
    for ((i = 0; i < N; i++)); do
        [[ "${TOKS[$i]}" == "git" ]] && _is_cmd_pos "$i" || continue
        if _git_alias_body_matches "$i" push && _cmd_string_has_force_main; then return 0; fi
    done
    return 1
}

# === 4. Active-run detection: run.json with open packets + recent activity ===

# _run_state <project_dir> — echoes active | stale | none. "active" = an open run (>=1 packet not
# completed AND not integration_ready) touched within the active window. "stale" = open but old.
_run_state() {
    local pdir="$1" root rj now mt age win has_open=0 has_recent=0
    if [[ -n "${BRAINIAC_RUNS_DIR:-}" ]]; then root="$BRAINIAC_RUNS_DIR"; else root="$pdir/.brainiac/runs"; fi
    [[ -d "$root" ]] || { echo none; return; }
    win="${BRAINIAC_RUN_ACTIVE_WINDOW_SECONDS:-21600}"
    now=$(date +%s)
    while IFS= read -r rj; do
        [[ -f "$rj" ]] || continue
        jq -e '([.packets[]? | select(.status != "completed")] | length > 0)
               and ((.integration_status // "") != "integration_ready")' "$rj" >/dev/null 2>&1 || continue
        has_open=1
        mt=$(stat -c %Y "$rj" 2>/dev/null || stat -f %m "$rj" 2>/dev/null || echo 0)
        age=$((now - mt))
        [[ "$age" -lt "$win" ]] && has_recent=1
    done < <(find "$root" -maxdepth 2 -name run.json 2>/dev/null)
    if [[ "$has_open" -eq 1 && "$has_recent" -eq 1 ]]; then echo active
    elif [[ "$has_open" -eq 1 ]]; then echo stale
    else echo none; fi
}

# === 5. Decide ===
# Tokenize once into TOKS[]/N (the classifiers in §3 read these globals).
read -r -a TOKS <<< "$cmd_norm"; N=${#TOKS[@]}

# 5a. Force-push to main is destructive → hard block, independent of any run.
#     (direct `git push --force … main` OR an inline `-c alias.X="push … --force … main"` injection)
if _cmd_is_force_push_main || _has_force_push_main_alias_injection; then
    { echo "$MSG_NOMERGE_HEADER"; echo ""; echo "$MSG_NOMERGE_FORCE"; echo ""
      echo "Tool: Bash"; echo "Command: $bash_command"; echo ""; echo "$MSG_NOMERGE_HINT"; } >&2
    exit 2
fi

# 5b. Merge / gh pr merge → depends on run state (active=block, stale=warn, none=allow).
#     (direct `git merge <ref>`/`gh pr merge` OR an inline `-c alias.X=merge` injection)
if _cmd_is_merge || _has_merge_alias_injection; then
    case "$(_run_state "$project_dir")" in
        active)
            { echo "$MSG_NOMERGE_HEADER"; echo ""; echo "$MSG_NOMERGE_ACTIVE"; echo ""
              echo "Tool: Bash"; echo "Command: $bash_command"; echo ""; echo "$MSG_NOMERGE_HINT"; } >&2
            exit 2
            ;;
        stale)
            { echo "$MSG_NOMERGE_HEADER"; echo "$MSG_NOMERGE_STALE"; } >&2
            exit 0
            ;;
        none) exit 0 ;;
    esac
fi

exit 0
