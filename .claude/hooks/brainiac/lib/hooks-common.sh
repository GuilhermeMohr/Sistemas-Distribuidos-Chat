# Brainiac Context — Shared helpers for Claude Code PreToolUse hooks
# Shared helpers extracted from the context gates.
#
# Shell library — ONLY function definitions, ZERO top-level executable code.
# Source from any Brainiac hook that needs these helpers. Idempotent.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/hooks-common.sh"
#
# Caller resumes top-level execution after sourcing — lib has no side effects.

# shellcheck disable=SC2148
# (no shebang on purpose; lib is sourced, not executed standalone)


# === compute_sha256(input) — portable SHA-256 ===
# Linux/Git Bash: sha256sum. macOS without coreutils: shasum -a 256.
# Fallback "unknown" prevents cache file collapse to shared /tmp/<empty>.json.
compute_sha256() {
    local input="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$input" | sha256sum 2>/dev/null | cut -c1-16
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$input" | shasum -a 256 2>/dev/null | cut -c1-16
    else
        echo "unknown"
    fi
}


# === is_allowlisted(path) — path-based allowlist (no generic *.md) ===
# Returns 0 (allowed) for context/, root docs, lockfiles, generated files,
# canonical configs. Returns 1 (not allowed) otherwise. Prompts in product
# code are NOT exempt — caller decides what happens for non-allowlisted paths.
is_allowlisted() {
    local p="$1"
    [[ "$p" == *"/context/"* ]] && return 0
    [[ "$p" == */CLAUDE.md ]] && return 0
    [[ "$p" == */AGENTS.md ]] && return 0
    [[ "$p" == */README.md ]] && return 0
    [[ "$p" == */CHANGELOG.md ]] && return 0
    [[ "$p" == */GLOSSARY.md ]] && return 0
    [[ "$p" == */GETTING_STARTED.md ]] && return 0
    [[ "$p" == */FAQ.md ]] && return 0
    [[ "$p" == */package.json ]] && return 0
    [[ "$p" == */tsconfig*.json ]] && return 0
    [[ "$p" == */*.config.* ]] && return 0
    [[ "$p" == */drizzle.config.* ]] && return 0
    [[ "$p" == */.env* ]] && return 0
    [[ "$p" == */.gitignore ]] && return 0
    [[ "$p" == */.github/* ]] && return 0
    [[ "$p" == *.gen.* ]] && return 0
    [[ "$p" == *-lock.* ]] && return 0
    [[ "$p" == */yarn.lock ]] && return 0
    [[ "$p" == */Cargo.lock ]] && return 0
    [[ "$p" == */Gemfile.lock ]] && return 0
    [[ "$p" == */poetry.lock ]] && return 0
    [[ "$p" == */composer.lock ]] && return 0
    return 1
}


# === _normalize_drive_letter(path) — lowercase a leading Windows drive ===
# "C:/x" -> "c:/x". No-op for POSIX paths (no "X:" prefix), so case-sensitive
# Linux/macOS filesystems are untouched — only the drive letter is folded, never
# the rest of the path. Portable (no bash-4 `${,,}`): `case` guard + `tr` on the
# single drive char. Internal helper for is_outside_project.
_normalize_drive_letter() {
    case "$1" in
        [A-Za-z]:*)
            local drive rest
            drive=$(printf '%s' "${1%%:*}" | tr '[:upper:]' '[:lower:]')
            rest="${1#*:}"
            printf '%s:%s' "$drive" "$rest"
            ;;
        *) printf '%s' "$1" ;;
    esac
}


# === is_outside_project(file_path_norm, project_dir_norm) — scope guard ===
# Returns 0 (true) if file_path is outside project_dir. Use for early-exit in
# PreToolUse / Stop hooks that should only act on product code inside the
# project. Paths fora do project (plan files em ~/.claude/plans/, auto-memory
# em ~/.claude/projects/, edits cross-project) são layer pessoal/meta, não
# product code — gates não devem aplicar.
#
# Tradeoff: string-prefix vs `realpath --relative-to`. String-prefix funciona
# porque `jq` extrai `tool_input.file_path` direto do transcript (sempre
# absoluto) + normalização `\→/` já feita pelos callers via `tr '\\' '/'`.
# `realpath --relative-to` é GNU-only, sem fallback portátil em Git Bash
# MSYS2 — rejeitado.
#
# Robustez do compare:
#   - Drive case (Windows): o Claude Code pode emitir `cwd` e `file_path` com a
#     letra de drive em case diferente (`d:/...` vs `D:/...`). Sem normalizar, um
#     edit DENTRO do projeto é julgado "fora" → o gate PULA silenciosamente. Fold
#     da letra de drive em ambos os lados resolve (no-op em POSIX).
#   - Boundary com separador: exigir igualdade exata OU prefixo seguido de `/`.
#     Sem isso, um diretório IRMÃO com nome em prefixo (`.../proj-2/x` vs projeto
#     `.../proj`) seria julgado "dentro" → gate dispara em path alheio.
is_outside_project() {
    local file_path_norm="$1"
    local project_dir_norm="$2"
    [[ -z "$file_path_norm" || -z "$project_dir_norm" ]] && return 1

    file_path_norm=$(_normalize_drive_letter "$file_path_norm")
    project_dir_norm=$(_normalize_drive_letter "$project_dir_norm")
    project_dir_norm="${project_dir_norm%/}"

    [[ "$file_path_norm" != "$project_dir_norm" && "$file_path_norm" != "$project_dir_norm"/* ]]
}


# === active_intent_path(transcript_path) — resolve active intent ===
# Definition: last intent (i) loaded via Read tool OR (ii) @-referenced
# in USER message (NOT assistant message). Chronological ordering via
# .timestamp from NDJSON transcript.
#
# NB: subshell `(jqA; jqB) | sort` had subtle
# interaction with `set -uo pipefail` where Source B silently produced
# empty output in nested function context. Workaround: temp file + sort once.
#
# NB: jq scan() with `\\\\.md` regex behaved unreliably in some
# shells. Replaced with 2-stage extract: jq returns user text+timestamp,
# shell grep extracts @-ref. More robust across Git Bash MSYS2, WSL, Linux.
active_intent_path() {
    local transcript_path="$1"
    [[ -f "$transcript_path" ]] || return 0

    local tmp_file
    tmp_file=$(mktemp -t brainiac-aip.XXXXXX 2>/dev/null || echo "/tmp/brainiac-aip-$$.txt")
    : > "$tmp_file"

    # Source A: Read tool_use by assistant
    jq -r '
        select(.type == "assistant")
        | .timestamp as $ts
        | .message.content[]?
        | select(.type == "tool_use" and .name == "Read")
        | (.input.file_path // empty)
        | "\($ts)\t\(.)"
    ' "$transcript_path" 2>/dev/null \
    | tr -d '\r' \
    | tr '\\' '/' \
    | awk -F'\t' '$2 ~ /context\/intent\/(feature|bug|refactor)-[a-zA-Z0-9_-]+\.md$/ {print}' \
    >> "$tmp_file"

    # Source B: @ref in user messages (pipeline 2-stage)
    local ts text ref ref_clean
    while IFS=$'\t' read -r ts text; do
        [[ -z "$text" ]] && continue
        ref=$(printf '%s\n' "$text" | grep -oE "@[^[:space:]]*context/intent/(feature|bug|refactor)-[a-zA-Z0-9_-]+\.md" | head -1)
        [[ -z "$ref" ]] && continue
        ref_clean=$(printf '%s\n' "$ref" | sed 's/^@//')
        printf '%s\t%s\n' "$ts" "$ref_clean"
    done < <(jq -r '
        select(.type == "user")
        | .timestamp as $ts
        | (.message.content | if type == "string" then [{"type":"text","text":.}] else . end)[]?
        | select(.type == "text")
        | "\($ts)\t\(.text // empty)"
    ' "$transcript_path" 2>/dev/null | tr -d '\r') >> "$tmp_file"

    sort -k1,1 "$tmp_file" | tail -1 | cut -f2-
    rm -f "$tmp_file"
}


# === loaded_paths(transcript_path) — extract Read tool call paths ===
# Returns all file_paths from Read tool calls in transcript, normalized
# (Windows backslash → forward slash). Caller filters via grep regex.
loaded_paths() {
    local transcript_path="$1"
    [[ -f "$transcript_path" ]] || return 0
    jq -r '
        select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use" and .name == "Read")
        | (.input.file_path // empty)
    ' "$transcript_path" 2>/dev/null | tr -d '\r' | tr '\\' '/'
}


# === user_text(transcript_path) — extract text from USER messages ===
# Returns concatenated text content from user messages (string or array form).
# Used by is_loaded() to detect @-refs in free-form user prompts.
user_text() {
    local transcript_path="$1"
    [[ -f "$transcript_path" ]] || return 0
    jq -r '
        select(.type == "user")
        | (.message.content | if type == "string" then [{"type":"text","text":.}] else . end)[]?
        | select(.type == "text")
        | (.text // empty)
    ' "$transcript_path" 2>/dev/null
}


# === is_loaded(regex, transcript_path) — check if a path is loaded ===
# Returns 0 if regex matches either:
#   (a) any path in loaded_paths (Read tool calls), OR
#   (b) any @-ref in user_text matching the regex
# Returns 1 otherwise.
#
# NB: for ramo (b), strips trailing `$` from regex before applying
# to free-form text. Without strip, prompts like
#   "carregue @context/intent/foo.md e edita src/bar.js"
# fail because grep `$` anchors end-of-line. loaded_paths ramo (a) keeps
# the `$` — semantics preserved for transcript-extracted paths.
is_loaded() {
    local regex="$1"
    local transcript_path="$2"
    loaded_paths "$transcript_path" | grep -E "$regex" >/dev/null 2>&1 && return 0
    local regex_atref="${regex%\$}"
    user_text "$transcript_path" | grep -oE "@[^[:space:]]*${regex_atref}" >/dev/null 2>&1 && return 0
    return 1
}


# End of library — no top-level code follows. Caller resumes.

# === bc_normalize_path(path) — forma canônica p/ comparação de prefixo ===
# Unifica as três formas que convivem no Windows/Git Bash e no POSIX:
#   "D:\x" | "D:/x" | "d:/x" -> "d:/x"        (backslash + drive minúsculo)
#   "/d/x"                   -> "d:/x"        (forma MSYS)
#   "/home/x"                -> "/home/x"     (POSIX intocado)
# Remove barra final (exceto raiz). Necessário porque `--show-toplevel` devolve
# "D:/..." enquanto `pwd`/resolve_project_root devolvem "/d/...": comparar sem
# unificar faz o strip de prefixo falhar em SILÊNCIO.
bc_normalize_path() {
    # CR nunca faz parte de um path legitimo. Ele entra quando a origem e `jq`
    # sob Git Bash/MSYS, que emite CRLF: `read -r` consome o \n e deixa o \r, e
    # a igualdade literal do bash — ao contrario de grep e awk, que toleram CR
    # no fim da linha — nunca casa. Removido aqui, na forma canonica, toda
    # comparacao fica protegida, e nao apenas o call-site que revelou o
    # problema. Remove qualquer CR, nao so o terminal: um path valido nao
    # contem CR em posicao alguma.
    local p="${1//$'\r'/}"
    p="${p//\\//}"
    case "$p" in
        /[A-Za-z]/*)
            local d rest
            d=$(printf '%s' "$p" | cut -c2 | tr '[:upper:]' '[:lower:]')
            rest=${p#/?}
            p="$d:$rest" ;;
        [A-Za-z]:/*)
            local d rest
            d=$(printf '%s' "$p" | cut -c1 | tr '[:upper:]' '[:lower:]')
            rest=${p#?}
            p="$d$rest" ;;
    esac
    [[ ${#p} -gt 1 ]] && p="${p%/}"
    printf '%s' "$p"
}

# === bc_path_under(child, parent) — contenção COM limite de diretório ===
# "/repo-foo" NÃO está sob "/repo". Comparação por string pura erraria isso.
bc_path_under() {
    local c p
    c=$(bc_normalize_path "$1"); p=$(bc_normalize_path "$2")
    [[ "$c" == "$p" || "$c" == "$p"/* ]]
}

# === bc_nearest_existing_dir(path) — ancestral existente mais próximo ===
# Arquivo novo cujo diretório ainda não existe: git precisa de um -C válido.
bc_nearest_existing_dir() {
    local d; d=$(dirname "$1")
    while [[ -n "$d" && "$d" != "/" && "$d" != "." && ! -d "$d" ]]; do d=$(dirname "$d"); done
    [[ -d "$d" ]] && printf '%s' "$d" || printf '%s' "."
}

# === bc_has_git_boundary(dir) — existe .git em algum ancestral? ===
# Sondagem de FILESYSTEM, sem executar git. Ausência do git como FERRAMENTA não
# é prova de ausência de FRONTEIRA git: worktree linkada tem um arquivo .git no
# disco. Sem esta distinção, git indisponível viraria "cross-project" (fail-open).
bc_has_git_boundary() {
    local d="$1"
    while [[ -n "$d" && "$d" != "/" && "$d" != "." ]]; do
        [[ -e "$d/.git" ]] && return 0
        local up; up=$(dirname "$d"); [[ "$up" == "$d" ]] && break; d="$up"
    done
    return 1
}

# === bc_classify_target(file_path, session_dir) ===
# Ecoa "<estado>|<target_root>". Estados:
#   resolved       — mesmo repositório comprovado (--git-common-dir absolutizado
#                    igual ao da sessão). Cobre worktree interna E externa.
#   local-fallback — sem fronteira git, mas dentro da sessão: policy da sessão.
#   external       — repo comprovadamente diferente, ou sem fronteira git e fora
#                    da sessão. Preserva exit 0 (cross-project).
#   indeterminate  — há fronteira git mas a identidade não pôde ser resolvida.
#                    NÃO libera: quem chama decide fail-closed.
# Identidade vence localização nos DOIS sentidos: worktree do mesmo repo pode
# viver fora da raiz, e repo aninhado dentro da raiz é externo.
bc_classify_target() {
    local fp="$1" sess="$2" probe f_top f_common s_common
    probe=$(bc_nearest_existing_dir "$fp")

    if ! command -v git >/dev/null 2>&1; then
        if bc_has_git_boundary "$probe"; then printf 'indeterminate|'; return 0; fi
        bc_path_under "$fp" "$sess" && { printf 'local-fallback|%s' "$sess"; return 0; }
        printf 'external|'; return 0
    fi

    # --path-format=absolute é OBRIGATÓRIO: sem ele a raiz principal devolve
    # ".git" relativo e a worktree devolve caminho absoluto — a comparação
    # classificaria worktree legítima como repositório diferente.
    f_common=$(git -C "$probe" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    f_top=$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null)
    s_common=$(git -C "$sess" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)

    if [[ -z "$f_common" || -z "$f_top" ]]; then
        if bc_has_git_boundary "$probe"; then printf 'indeterminate|'; return 0; fi
        bc_path_under "$fp" "$sess" && { printf 'local-fallback|%s' "$sess"; return 0; }
        printf 'external|'; return 0
    fi

    if [[ -n "$s_common" ]] && [[ "$(bc_normalize_path "$f_common")" == "$(bc_normalize_path "$s_common")" ]]; then
        printf 'resolved|%s' "$f_top"; return 0
    fi

    # Repo diferente comprovado (inclui aninhado/submódulo dentro da sessão).
    printf 'external|'; return 0
}

# === is_path_loaded_exact(abs_path, transcript) — evidência por IGUALDADE ===
# Compara o caminho ABSOLUTO normalizado contra cada path lido no transcript.
# Substitui o match por sufixo em regex: `.../test-ap.md$` casava o arquivo
# homônimo de QUALQUER árvore, então ler a cópia da raiz liberava uma regra cuja
# policy vive no worktree (bypass inverso).
is_path_loaded_exact() {
    local want seen
    want=$(bc_normalize_path "$1")
    while IFS= read -r seen; do
        [[ -z "$seen" ]] && continue
        [[ "$(bc_normalize_path "$seen")" == "$want" ]] && return 0
    done < <(loaded_paths "$2")
    return 1
}
