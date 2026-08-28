#!/bin/bash
# brainiac-allow-large reason="hook PreToolUse standalone distribuído self-contained a projetos-cliente; detector de secret (DET_BASH/DET_PATH + classificador de verbo + trip-wire) é um único domínio coeso — split fragmentaria e quebraria a paridade dual-hook"
# Brainiac Context — Secret-Read Gate (PreToolUse hook for Bash|Read|Grep|Glob)
#
# Defense-in-depth contra leitura de secret files (.env*, secrets/, *.key, *.pem,
# credentials.json, service-account*.json, *-secret.yaml) e exfiltração runtime
# óbvia de valores de ambiente (`process.env`, `env`, `printenv`). CLAUDE.md global
# já proíbe textualmente; este hook é a blindagem do lado do harness — bloqueia
# tool calls que tentem acessar paths sensíveis E educa via trip-wire de retry
# cumulativo na sessão.
#
# Detecção do path-alvo por tool:
#   - Read:  tool_input.file_path
#   - Grep:  tool_input.path
#   - Glob:  tool_input.pattern
#   - Bash:  varrer tool_input.command por tokens
#
# Whitelist: .env.example é permitido (template/
# exemplo) com mensagem informativa alertando o agente para avisar o usuário
# caso valor real seja visto durante a leitura.
#
# Trip-wire de retry: conta tentativas anteriores no transcript via jq scan
# de tool_use inputs com tokens de secret. Se contagem >= 1 ANTES desta
# tentativa, escala mensagem para "RETRY DETECTED".
#
# NB: pipefail OFF intencional (Git Bash MSYS2 + jq + pipe + pipefail
# produzem output vazio silencioso). set -u retained.

set -u

# === 1. Parse input ===
input=$(cat)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // ""')
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
grep_path=$(printf '%s' "$input" | jq -r '.tool_input.path // ""')
glob_pattern=$(printf '%s' "$input" | jq -r '.tool_input.pattern // ""')
bash_command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
project_dir=$(printf '%s' "$input" | jq -r '.cwd // empty')

[[ -z "$project_dir" ]] && project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Normalize Windows backslashes
file_path_norm=$(printf '%s\n' "$file_path" | tr '\\' '/')
grep_path_norm=$(printf '%s\n' "$grep_path" | tr '\\' '/')
glob_pattern_norm=$(printf '%s\n' "$glob_pattern" | tr '\\' '/')

# === Helper: i18n loading + optional shared lib ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional lib (only compute_sha256 used; safe to skip if absent)
if [[ -f "$SCRIPT_DIR/lib/hooks-common.sh" ]]; then
    # shellcheck source=lib/hooks-common.sh
    source "$SCRIPT_DIR/lib/hooks-common.sh"
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

# Fallback strings (English)
: "${MSG_SECRET_GATE_HEADER:=[Brainiac Secret-Read Gate]}"
: "${MSG_SECRET_GATE_BLOCKED:=Read blocked: target is in the secret-file class (.env*, secrets/, *.key, *.pem, credentials.json, service-account*.json, *-secret.yaml).}"
: "${MSG_SECRET_GATE_HINT:=To know WHICH env vars exist, read code that does process.env.X / Deno.env.get(). To know VALUES, ask the user. Permission denied is not an invitation to switch file or tool. If this was a jq filter accessing a key literally named env (e.g. jq '.env.FOO'), use bracket notation .[\"env\"] instead — it is not a secret file.}"
: "${MSG_SECRET_GATE_RETRY_HEADER:=[Brainiac Secret-Read Gate — RETRY DETECTED]}"
: "${MSG_SECRET_GATE_RETRY_BODY:=This is attempt N at accessing a secret in this session. STOP. You are in bypass-via-retry pattern. Acknowledge openly to the user that the evidence you want is not available without explicit authorization.}"
: "${MSG_SECRET_GATE_EXAMPLE_NOTICE:=Read allowed on .env.example (template/example file). REMINDER: this file must NOT contain real values. If you notice real secret/credential during reading, alert the user immediately.}"
: "${MSG_SECRET_GATE_ENV_BLOCKED:=Command blocked: it would expose environment variable values or parse a secret file at runtime (.env/process.env/env/printenv).}"
: "${MSG_SECRET_GATE_ENV_HINT:=Safe alternatives: search code for variable NAMES (e.g. rg 'process.env.NAME'), or ask the user for VALUES. Do not print process.env, env dumps, printenv secret variables, or parse .env files inside runtime scripts.}"
: "${MSG_SECRET_GATE_COPY_NOTICE:=Opaque same-class copy allowed: source and destination are both secret-class, so no value is exposed to the model (file → file, never stdout). The secret stays labeled at the destination — future reads of it remain blocked. Logged (reason=copy_safe).}"
: "${MSG_SECRET_GATE_COPY_LAUNDER_BLOCKED:=Copy blocked (laundering vector): the destination is NOT secret-class (a plain file, /dev/stdout, or a device). Copying a secret to a non-secret destination would strip its protection and let a later read expose the value.}"
: "${MSG_SECRET_GATE_COPY_LAUNDER_HINT:=To copy a secret into a worktree, the destination must also be secret-class (e.g. cp .env.local <worktree>/.env.local). To inspect VALUES, ask the user. Never copy a secret to /dev/stdout, '-', or a plain non-secret file.}"
: "${MSG_SECRET_GATE_SHELLVAR_BLOCKED:=Command blocked: an output command would print the VALUE of a sensitive environment variable through shell parameter expansion.}"
: "${MSG_SECRET_GATE_SHELLVAR_HINT:=BEWARE: \${VAR:-default} PRINTS THE VALUE whenever the variable IS set — it is not the inverse of \${VAR:+word}. To test EXISTENCE without revealing: [ -n \"\$VAR\" ] && echo SET || echo UNSET, or \${VAR:+SET}. For size only: \${#VAR}. To hand a credential to a child process, assign it inline (VAR=\"\$SECRET\" cmd) — that never reaches stdout. To learn the VALUE, ask the user.}"

# === Regex de detecção (DRY — reusadas na detecção §4 e no trip-wire §5) ===
# Discriminador: `.env` ancorado no PRECEDE por separador de path/
# whitespace/início/redireção — nunca por aspa. Assim `jq '.env.x'`/`jq ".env.x"`
# (precede aspa) NÃO casa, mas `cat .env`/`cat x/.env`/`cat<.env` casam. Aspas +
# delimitadores shell entram no FOLLOW: bloqueiam `cat './.env'`, `cat "x/.env"`,
# `cat .env.local;`, `(cat .env)` — e preservam jq, pois o precede já o exclui.
# `.key`/`.pem`: um desenho ingênuo
# (`.*` no basename + delimitadores no follow) teria 2 defeitos — (1) FP em filtro jq
# COMPOSTO (`jq '.key|x'`, `'(.pem)'`, `'.key>0'`), pois `.*` engolia a aspa de
# abertura e o delimitador jq casava o follow; (2) bypass por redireção SEM espaço
# (`cat<deploy.key`). Correção: basename QUOTE-AWARE `_BASE_NOQUOTE` (a aspa de
# abertura vira barreira → jq composto passa) + precede `_PRECEDE` inclui `<` `>`
# (redireção). Também no follow-set: backtick (`_BT`) (bloqueia
# `` cat `printf x.key` ``) e ramo BARE-REDIRECT `[<>]\.key|pem` (bloqueia `cat<.key`/
# `bash<.pem` mesmo sem basename). Residual best-effort aceito (no-silent-cap):
# (a) path citado com aspas (`cat 'x.key'`); (b) variável (`cat $KEYFILE`); (c) bare
# dotfile separado por ESPAÇO (`cat .key`/`cat .pem`) — indistinguível de prosa
# (` .key` em commit-msg/echo); `.*`/`*` aqui bloqueariam prosa legítima. Read/Grep/
# Glob ancoram em basename (DET_PATH) e bloqueiam todos esses (vetor mais provável).
# Cobertura exaustiva de metachar shell exigiria tokenização (fora de escopo por
# desenho: este gate é heurística regex best-effort, não um parser de shell).
_SQ="'"; _DQ='"'; _BT='`'
_FOLLOW="[[:space:]/;&|<>()${_SQ}${_DQ}${_BT}]"
_FOLLOW_NOQUOTE="[[:space:]/;&|<>()${_BT}]"
# Precede de secret real: separador de path/whitespace/início + redireção (`<` `>`).
# NUNCA aspa (excluiria jq). Usado tanto pelo `.env` quanto pelos `.key`/`.pem`.
_PRECEDE="[[:space:]/<>]"
# Basename quote-aware: nome de arquivo SEM aspas e SEM espaço — a aspa de abertura
# de um filtro jq (`'.key`) vira barreira intransponível ao `+`.
_BASE_NOQUOTE="[^${_SQ}${_DQ}[:space:]]+"
# Comando Bash cru (detecção §4 Bash + valores Bash do trip-wire §5). Ramos `.key`/
# `.pem`: basename quote-aware OU bare-redirect (`[<>]\.key` — redireção sem basename).
# PARIDADE DE CLASSE: a classe-secret é enumerada à mão em 4 detectores que
# DEVEM cobrir o mesmo conjunto — DET_PATH (Read/Grep/Glob) + DET_BASH + _GIT_FFS_BASE +
# objectspec (_has_git_objectspec_secret). Ao adicionar/remover um membro da classe
# (`.env`/`secrets/`/`.key`/`.pem`/`credentials.json`/`service-account*.json`/`*-secret.ya?ml`),
# atualizar TODOS os 4 — o teste de paridade em validation/suites/secret-gate.sh (Seção 11)
# falha se o ramo Bash ficar atrás do DET_PATH.
DET_BASH="(^|${_PRECEDE})\\.env(\\.[a-z0-9_.-]+)?(${_FOLLOW}|\$)|(^|${_PRECEDE})secrets?/|(^|${_PRECEDE})credentials\\.json(${_FOLLOW}|\$)|${_PRECEDE}${_BASE_NOQUOTE}\\.key(${_FOLLOW_NOQUOTE}|\$)|[<>]\\.key(${_FOLLOW_NOQUOTE}|\$)|${_PRECEDE}${_BASE_NOQUOTE}\\.pem(${_FOLLOW_NOQUOTE}|\$)|[<>]\\.pem(${_FOLLOW_NOQUOTE}|\$)|service-account[^[:space:]]*\\.json|${_PRECEDE}${_BASE_NOQUOTE}-secret\\.ya?ml(${_FOLLOW_NOQUOTE}|\$)|[<>]-secret\\.ya?ml(${_FOLLOW_NOQUOTE}|\$)"
# Path puro (branches Read/Grep/Glob §4 + valores path do trip-wire §5):
DET_PATH="(^|/)(\\.env(\\.[a-z0-9_-]+)?\$|secrets?/|credentials\\.json\$|.*\\.key\$|.*\\.pem\$|service-account[^/]*\\.json\$|.*-secret\\.ya?ml\$)"

# Runtime/env exfiltration guard.
# Escopo: bloquear padrões que expõem VALORES ao stdout/transcript ou fazem parsing
# runtime de secret files; preservar code search de NOMES (`rg process.env.X`) e
# variáveis públicas comuns (`NODE_ENV`, `CI`, etc.) para reduzir falso positivo.
_ENV_VALUE_ALLOWLIST_RE='^(NODE_ENV|CI|PWD|OLDPWD|PATH|HOME|USER|USERNAME|SHELL|TERM|LANG|LC_[A-Za-z0-9_]+|TZ|PORT|HOST|TMPDIR|TEMP|TMP)$'
_RUNTIME_SECRET_FILE_API_RE="(readFileSync|readFile|createReadStream|Deno\.read(Text)?File|Bun\.file|dotenv[^;&|]{0,80}config|config[[:space:]]*\()[^;&|]{0,200}(\./)?\.env(\.[A-Za-z0-9_.-]+)?"
_RUNTIME_ENV_OUTPUT_RE="(console\.(log|error|warn)|process\.stdout\.write|JSON\.stringify|Object\.(entries|values)|print[[:space:]]*\(|puts[[:space:]]|Deno\.env\.toObject|dict[[:space:]]*\([[:space:]]*os\.environ|os\.environ\.items)"
_RUNTIME_ENV_DUMP_RE="(JSON\.stringify[[:space:]]*\([[:space:]]*process\.env[[:space:]]*\)|Object\.(entries|values)[[:space:]]*\([[:space:]]*process\.env[[:space:]]*\)|console\.(log|error|warn)[^;&|]{0,80}\([[:space:]]*process\.env[[:space:]]*\)|process\.stdout\.write[^;&|]{0,80}\([[:space:]]*process\.env[[:space:]]*\)|Deno\.env\.toObject[[:space:]]*\(|dict[[:space:]]*\([[:space:]]*os\.environ[[:space:]]*\)|os\.environ\.items[[:space:]]*\()"

_is_code_search_command() {
    local cmd trimmed
    cmd="$1"
    trimmed=$(printf '%s' "$cmd" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    printf '%s\n' "$trimmed" | grep -qE '^(rg|grep|git[[:space:]]+grep|ag|ack)([[:space:]]|$)'
}

_env_name_allowed() {
    local name="$1"
    [[ "$name" =~ $_ENV_VALUE_ALLOWLIST_RE ]]
}

_has_non_allowlisted_env_ref() {
    local text="$1" match name

    while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        name="${match##*.}"
        if ! _env_name_allowed "$name"; then return 0; fi
    done < <(printf '%s\n' "$text" | grep -oE 'process\.env\.[A-Za-z_][A-Za-z0-9_]*' 2>/dev/null || true)

    while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        name=$(printf '%s\n' "$match" | sed -E "s/.*\[['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\].*/\1/")
        if ! _env_name_allowed "$name"; then return 0; fi
    done < <(printf '%s\n' "$text" | grep -oE "process\.env\[['\"][A-Za-z_][A-Za-z0-9_]*['\"]\]" 2>/dev/null || true)

    while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        name=$(printf '%s\n' "$match" | sed -E "s/.*\(['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\).*/\1/")
        if ! _env_name_allowed "$name"; then return 0; fi
    done < <(printf '%s\n' "$text" | grep -oE "Deno\.env\.get[[:space:]]*\([[:space:]]*['\"][A-Za-z_][A-Za-z0-9_]*['\"][[:space:]]*\)" 2>/dev/null || true)

    while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        name=$(printf '%s\n' "$match" | sed -E "s/.*\(['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\).*/\1/")
        if ! _env_name_allowed "$name"; then return 0; fi
    done < <(printf '%s\n' "$text" | grep -oE "os\.(getenv|environ\.get)[[:space:]]*\([[:space:]]*['\"][A-Za-z_][A-Za-z0-9_]*['\"][[:space:]]*\)" 2>/dev/null || true)

    while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        name=$(printf '%s\n' "$match" | sed -E "s/.*\[['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\].*/\1/")
        if ! _env_name_allowed "$name"; then return 0; fi
    done < <(printf '%s\n' "$text" | grep -oE "os\.environ\[['\"][A-Za-z_][A-Za-z0-9_]*['\"]\]" 2>/dev/null || true)

    return 1
}

# === Expansão de parâmetro do SHELL que revela valor de env sensível ===
# Exemplo perigoso: `echo "${TOKEN:+SIM}${TOKEN:-NAO}"` pode imprimir um PAT.
# Neste vetor, o secret vem da MEMÓRIA do
# processo (não de arquivo, então DET_BASH não casa) e não passa por
# process.env/Deno.env/os.environ/env/printenv (então os runtime guards não casam).
#
# Duas discriminações mantêm o falso-positivo baixo:
#  (1) FORMA da expansão — `${VAR:+x}`/`${VAR+x}` imprimem a PALAVRA (seguros);
#      `${#VAR}` imprime o tamanho (seguro); `$VAR`/`${VAR}`/`${VAR:-x}`/`${VAR-x}`/
#      `${VAR:=x}` imprimem o VALOR. A armadilha do incidente foi exatamente supor
#      que `:-` é o inverso de `:+` — não é.
#  (2) VERBO do segmento — só comandos de OUTPUT. Sem isso quebraríamos o uso
#      legítimo de repassar credencial a um processo filho
#      (`VAR="$SECRET" npx deploy`), que nunca toca o stdout.
#
# Nome sensível é heurística por SUBSTRING. Residual aceito (no-silent-cap): sufixo
# `_KEY` genérico ficou FORA (`CACHE_KEY`/`SORT_KEY`/`IDEMPOTENCY_KEY` seriam FP);
# os compostos reais (`API_KEY`/`ACCESS_KEY`/`PRIVATE_KEY`/`ANON_KEY`/…) estão cobertos.
_SENSITIVE_ENV_NAME_RE='(TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|SIGNING_?KEY|ENCRYPTION_?KEY|SESSION_?KEY|CREDENTIAL|SERVICE_ROLE|ANON_KEY|AUTH_?KEY|BEARER|DSN|CONNECTION_STRING)'
_OUTPUT_VERBS_RE='^(echo|printf|print|cat|tee|Write-Host|Write-Output|write-host|write-output)$'

# _leading_verb_of(segmento) → verbo efetivo, pulando prefixos de atribuição e wrappers.
# Duplica de propósito o preâmbulo de _verb_class_of: aquela função devolve CLASSE, esta
# devolve o NOME do verbo; uni-las criaria acoplamento entre contratos distintos.
_leading_verb_of() {
    local seg="$1" first
    seg="${seg#"${seg%%[![:space:]]*}"}"
    while :; do
        first="${seg%%[[:space:]]*}"
        case "$first" in
            *=*|sudo|command|time|nice) seg="${seg#"$first"}"; seg="${seg#"${seg%%[![:space:]]*}"}" ;;
            *) break ;;
        esac
    done
    printf '%s' "${seg%%[[:space:]]*}"
}

# _expansion_reveals_value(expansão) → 0 quando a expansão IMPRIME o valor.
# Recebe um token já extraído: `$VAR`, `${VAR...}` ou `$env:VAR` (PowerShell).
_expansion_reveals_value() {
    local exp="$1" body name rest
    case "$exp" in
        '${#'*)   return 1 ;;                        # ${#VAR} — só o tamanho
        '${'*)    body="${exp#\$\{}"; body="${body%\}}" ;;
        '$env:'*) body="${exp#\$env:}" ;;            # PowerShell — sempre revela
        '$'*)     body="${exp#\$}" ;;
        *)        return 1 ;;
    esac
    name="${body%%[^A-Za-z0-9_]*}"
    [[ -z "$name" ]] && return 1
    _env_name_allowed "$name" && return 1
    printf '%s' "$name" | grep -qiE "$_SENSITIVE_ENV_NAME_RE" || return 1
    rest="${body#"$name"}"
    case "$rest" in
        '+'*|':+'*) return 1 ;;                      # alternate — imprime a palavra, não o valor
    esac
    return 0
}

_has_shell_env_value_exfil() {
    local cmd="$1" seg nl=$'\n' s verb exp
    s="$cmd"
    # Mesma segmentação do _classify_secret_access, MENOS os parênteses: `${VAR:-(x)}`
    # é uma expansão válida e fatiá-la esconderia o operador.
    s="${s//'$('/$nl}"; s="${s//'`'/$nl}"
    s="${s//'&&'/$nl}"; s="${s//'||'/$nl}"
    s="${s//';'/$nl}"; s="${s//'|'/$nl}"; s="${s//'&'/$nl}"
    while IFS= read -r seg; do
        [[ -z "$seg" ]] && continue
        verb=$(_leading_verb_of "$seg")
        [[ "$verb" =~ $_OUTPUT_VERBS_RE ]] || continue
        while IFS= read -r exp; do
            [[ -z "$exp" ]] && continue
            if _expansion_reveals_value "$exp"; then return 0; fi
        done < <(printf '%s\n' "$seg" | grep -oE '\$\{[^}]*\}|\$env:[A-Za-z_][A-Za-z0-9_]*|\$[A-Za-z_][A-Za-z0-9_]*' 2>/dev/null || true)
    done <<< "$s"
    return 1
}

_has_runtime_secret_file_api() {
    local text sanitized
    text="$1"
    # `.env.example` é template público; remova antes da regex para evitar FP.
    sanitized=$(printf '%s\n' "$text" | sed -E 's#(\./)?\.env\.example##g')
    printf '%s\n' "$sanitized" | grep -qE "$_RUNTIME_SECRET_FILE_API_RE"
}

_has_runtime_env_value_exfil() {
    local text="$1"
    if _is_code_search_command "$text"; then return 1; fi
    if printf '%s\n' "$text" | grep -qE "$_RUNTIME_ENV_DUMP_RE"; then return 0; fi
    if printf '%s\n' "$text" | grep -qE "$_RUNTIME_ENV_OUTPUT_RE" && _has_non_allowlisted_env_ref "$text"; then
        return 0
    fi
    return 1
}

_has_env_command_exfil() {
    local text trimmed name shell_cmd
    text="$1"
    trimmed=$(printf '%s' "$text" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

    case "$trimmed" in
        env|env\ \|*|env\ \>*|env\;*|env\&*) return 0 ;;
    esac

    # `bash -lc env` / `sh -c "env"` executa dump de ambiente mesmo sem `env` no início.
    shell_cmd=$(printf '%s\n' "$trimmed" | sed -E 's/^(bash|sh)[[:space:]]+-l?c[[:space:]]+["'"'"']?([^"'"'"']+)["'"'"']?$/\2/' 2>/dev/null)
    if [[ "$shell_cmd" != "$trimmed" ]]; then
        case "$shell_cmd" in
            env|env\ \|*|env\ \>*|env\;*|env\&*) return 0 ;;
        esac
    fi

    if [[ "$trimmed" == "printenv" ]]; then return 0; fi
    if [[ "$trimmed" == printenv\ * ]]; then
        name="${trimmed#printenv }"
        name="${name%%[ ;|&>]*}"
        name="${name%\"}"; name="${name#\"}"; name="${name%\'}"; name="${name#\'}"
        if [[ -z "$name" ]]; then return 0; fi
        if ! _env_name_allowed "$name"; then return 0; fi
    fi

    if [[ "$shell_cmd" != "$trimmed" && "$shell_cmd" == printenv\ * ]]; then
        name="${shell_cmd#printenv }"
        name="${name%%[ ;|&>]*}"
        name="${name%\"}"; name="${name#\"}"; name="${name%\'}"; name="${name#\'}"
        if [[ -z "$name" ]]; then return 0; fi
        if ! _env_name_allowed "$name"; then return 0; fi
    fi

    return 1
}

_scan_runtime_source_file() {
    local candidate="$1" normalized full size source
    normalized="${candidate%\"}"; normalized="${normalized#\"}"
    normalized="${normalized%\'}"; normalized="${normalized#\'}"
    normalized="${normalized//\\//}"

    case "$normalized" in
        ''|-*|*'$'*|*'`'*|*'<'*|*'>'*|*';'*|*'|'*|*'&'*) return 1 ;;
    esac

    if printf '%s\n' "$normalized" | grep -qE '(^|/)(\.env(\.|$)|secrets?/|.*\.(key|pem)$|credentials\.json$|service-account[^/]*\.json$|.*-secret\.ya?ml$)'; then
        return 1
    fi

    case "$normalized" in
        /*) full="$normalized" ;;
        [A-Za-z]:/*) full="$normalized" ;;
        *) full="$project_dir/$normalized" ;;
    esac

    [[ -f "$full" ]] || return 1
    size=$(wc -c < "$full" 2>/dev/null | tr -d '[:space:]')
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    [[ "$size" -le 262144 ]] || return 1

    source=$(head -c 262144 "$full" 2>/dev/null)
    if _has_runtime_secret_file_api "$source" || _has_runtime_env_value_exfil "$source"; then
        return 0
    fi
    return 1
}

_scan_runtime_script_sources() {
    local cmd normalized
    local -a tokens
    local i j tok candidate
    cmd="$1"
    normalized=$(printf '%s' "$cmd" | tr '\n' ' ' | sed -E 's/[;|&()]/ /g')
    # shellcheck disable=SC2206 # word-splitting intentional: only simple script paths are inspected.
    tokens=($normalized)

    for ((i = 0; i < ${#tokens[@]}; i++)); do
        tok="${tokens[$i]}"
        case "$tok" in
            node|node.exe|bun|bun.exe)
                for ((j = i + 1; j < ${#tokens[@]}; j++)); do
                    candidate="${tokens[$j]}"
                    case "$candidate" in
                        -e|--eval|-*) break ;;
                        *.js|*.mjs|*.cjs|*.ts) if _scan_runtime_source_file "$candidate"; then return 0; fi; break ;;
                    esac
                done
                ;;
            python|python3|python.exe|python3.exe|ruby|ruby.exe|perl|perl.exe)
                for ((j = i + 1; j < ${#tokens[@]}; j++)); do
                    candidate="${tokens[$j]}"
                    case "$candidate" in
                        -c|-*) break ;;
                        *.py|*.rb|*.pl) if _scan_runtime_source_file "$candidate"; then return 0; fi; break ;;
                    esac
                done
                ;;
            deno|deno.exe)
                for ((j = i + 1; j < ${#tokens[@]}; j++)); do
                    candidate="${tokens[$j]}"
                    case "$candidate" in
                        eval|run|--allow-*|--quiet|-*) continue ;;
                        *.js|*.mjs|*.cjs|*.ts) if _scan_runtime_source_file "$candidate"; then return 0; fi; break ;;
                    esac
                done
                ;;
        esac
    done
    return 1
}

# === Classificação de verbo (R1 menção / R2 cópia opaca / R3 trip-wire) ===
# A invariante do gate é UMA: o VALOR de um secret nunca pode entrar no contexto do
# modelo (stdout/stderr → transcript, ou ambiente exposto). Copiar (arquivo→arquivo) e
# mencionar (string literal) NÃO violam; ler/exfiltrar viola. Quando DET_BASH casa (há um
# secret-path como operando), classificamos o VERBO em vez de bloquear pela mera presença.
#
# Precedência (mais severa vence): read_expose > copy_launder > copy_safe > mention.
# DEFAULT-DENY: DET_BASH casou mas nada classificou como mention/copy_safe → read_expose.
# Só afrouxamos onde sabemos ser seguro (allowlist explícita). DET_BASH/DET_PATH e os
# runtime guards ficam intactos — esta é uma camada POR CIMA, não uma reescrita.
_COPY_VERBS_RE='^(cp|mv|rsync|install|ln|copy|move|Copy-Item|Move-Item|New-Item)$'
_MENTION_VERBS_RE='^(echo|printf|:|true|test|\[)$'
# Subcomandos git de MENÇÃO pura (operam msg/ref, nunca o conteúdo/path de um arquivo secret).
# `show`/`diff`/`log`/`blame`/`cat-file`/`grep`/`config` expõem ou leem → default-deny (read_expose).
# Fora do allowlist: `mv` (move → laundering: `git mv .env leak.txt`
# renomeia secret p/ não-secret → tratado como COPY via _classify_destino); `add`/`rm`/`stash`
# (operam o PATH do secret: stage/remove/stash → habilitam leitura via object spec → default-deny);
# `config` (`git config -f <secret> --list` imprime valores).
_GIT_MENTION_SUB_RE='^(commit|tag|notes|branch|remote|push|pull|fetch)$'
# Flags que fazem git LER um arquivo como mensagem/template (`git commit -F <secret>` ecoa o
# subject no stdout → vaza valor). Presença com secret-operando → read_expose, não mention.
# Cobre formas separada (`-F .env`), com `=` (`--file=.env`) e COLADA (`-Fconfig/.env`,
# `-t.env` — short-arg attached).
_GIT_FILE_FLAG_RE='(^|[[:space:]])(--file|--template)([[:space:]=]|$)|(^|[[:space:]])-[Ft]([[:space:]=]|$|[^-[:space:]=])'

# _classify_destino(segmento_de_cópia) → "copy_safe" | "copy_launder".
# R2: cópia é segura SÓ quando o destino também é secret-class (same-class) — o secret
# continua "etiquetado" e leituras futuras sobre o destino seguem bloqueadas. Destino
# não-secret ou device de saída (/dev/stdout etc.) = laundering → block.
_classify_destino() {
    local seg="$1" tok dest="" dest_norm i _f tflag_idx=-1 targ_arg_idx=-1

    # Aspas no segmento tornam o word-split não-confiável — um
    # destino quoted com espaço (`cp .env.local "leak .env.local"`) seria fatiado e o último
    # token pareceria secret-class, mascarando laundering. Default-deny: trata como laundering.
    case "$seg" in
        *\"*|*\'*) echo "copy_launder"; return ;;
    esac

    # shellcheck disable=SC2206 # word-splitting intencional: só inspecionamos paths simples.
    local -a toks=($seg)

    # Flag de destino EXPLÍCITO (inclusive clustered). O destino é o
    # ARGUMENTO da flag — não o último token (que em `cp -t leakdir .env.local` é a ORIGEM).
    # Cobre GNU `-t DIR` (separado) e `-tDIR` (colado), `--target-directory[=]`, PowerShell
    # `-Destination`. Roda ANTES do check recursivo, marcando o token consumido p/ excluí-lo
    # (senão `-tsecrets/` — dest válido com 'r' — dispararia o heurístico recursivo).
    for ((i=1; i<${#toks[@]}; i++)); do
        case "${toks[$i]}" in
            -t|--target-directory|-Destination) dest="${toks[$((i+1))]:-}"; tflag_idx=$i; targ_arg_idx=$((i+1)); break ;;
            -t?*)                  dest="${toks[$i]#-t}"; tflag_idx=$i; break ;;
            --target-directory=*)  dest="${toks[$i]#*=}"; tflag_idx=$i; break ;;
            -Destination:*)        dest="${toks[$i]#*:}"; tflag_idx=$i; break ;;
        esac
    done

    # Same-class só é provável p/ ARQUIVO→ARQUIVO. Cópia RECURSIVA
    # (`cp -r secrets/ backup.key`, `rsync -a ...`, `Copy-Item -Recurse`) NÃO garante que os
    # descendentes no destino fiquem secret-class. Default-deny: copy_launder. Discrimina combos
    # curtos Unix (`-rf`/`-Rv`/`-a`) de flags-palavra PowerShell (`-Destination`/`-Path`, que
    # contêm a/r mas NÃO são recursivas) e de long flags GNU. Pula o token de target-flag (e seu
    # arg separado), já consumidos como destino.
    for ((i=1; i<${#toks[@]}; i++)); do
        [[ $i -eq $tflag_idx || $i -eq $targ_arg_idx ]] && continue
        case "${toks[$i]}" in
            -r|-R|-a|--recursive|--archive|-Recurse) echo "copy_launder"; return ;;
            --*) : ;;                              # outras long flags GNU: não-recursivas
            -R[a-zA-Z]*) echo "copy_launder"; return ;;  # combo c/ R maiúsculo (-Rv, -Rf)
            -[a-z]*)                               # combo curto lowercase Unix
                _f="${toks[$i]#-}"
                case "$_f" in *r*|*a*) echo "copy_launder"; return ;; esac ;;
        esac
    done

    # Sem flag de destino explícito: destino = último token não-flag.
    if [[ -z "$dest" ]]; then
        for ((i=${#toks[@]}-1; i>=1; i--)); do
            tok="${toks[$i]}"
            case "$tok" in
                -) dest="$tok"; break ;;  # '-' isolado = stdout (destino real, NÃO flag)
                -*) continue ;;           # pula flags; destino é o último token não-flag
                *) dest="$tok"; break ;;
            esac
        done
    fi
    [[ -z "$dest" ]] && { echo "copy_launder"; return; }

    # Same-class é ARQUIVO-secret → ARQUIVO-secret. Cada ORIGEM (token
    # não-flag ≠ destino, ≠ arg consumido do target-flag) precisa: (a) NÃO terminar em '/'
    # (diretório → `mv secrets/ x` espalha descendentes), e (b) casar DET_PATH (ser um arquivo
    # secret-class identificável). `mv secrets backup.key` (origem-dir SEM barra, fora de
    # DET_PATH) → laundering. Senão o destino secret-só-por-sufixo etiquetaria conteúdo não-secret.
    local _src
    for ((i=1; i<${#toks[@]}; i++)); do
        [[ $i -eq $tflag_idx || $i -eq $targ_arg_idx ]] && continue
        tok="${toks[$i]}"
        [[ "$tok" == "$dest" ]] && continue
        case "$tok" in
            -*) continue ;;
            */) echo "copy_launder"; return ;;
        esac
        _src=$(printf '%s' "$tok" | tr '\\' '/')
        printf '%s\n' "$_src" | grep -qE "$DET_PATH" || { echo "copy_launder"; return; }
    done
    dest="${dest%\"}"; dest="${dest#\"}"; dest="${dest%\'}"; dest="${dest#\'}"
    dest_norm=$(printf '%s' "$dest" | tr '\\' '/')
    case "$dest_norm" in
        /dev/stdout|/dev/stderr|/dev/fd/*|/dev/tty|-|con|con:|CON|CON:) echo "copy_launder"; return ;;
    esac
    if printf '%s\n' "$dest_norm" | grep -qE "$DET_PATH"; then
        echo "copy_safe"
    else
        echo "copy_launder"
    fi
}

# _verb_class_of(comando, allow_copy) → classe de um único comando (verbo + operandos).
# allow_copy=0 (usado p/ o verbo-líder do comando inteiro): verbos de cópia retornam "none"
# e deferem ao nível de segmento (o destino tem de ser avaliado no segmento certo, não no
# comando inteiro com `&&`). allow_copy=1 (nível de segmento): avalia o destino da cópia.
_verb_class_of() {
    local seg="$1" allow_copy="$2" first verb rest sub
    seg="${seg#"${seg%%[![:space:]]*}"}"   # ltrim
    while :; do
        first="${seg%%[[:space:]]*}"
        case "$first" in
            *=*|sudo|command|time|nice) seg="${seg#"$first"}"; seg="${seg#"${seg%%[![:space:]]*}"}" ;;
            *) break ;;
        esac
    done
    verb="${seg%%[[:space:]]*}"
    rest="${seg#"$verb"}"; rest="${rest#"${rest%%[![:space:]]*}"}"; sub="${rest%%[[:space:]]*}"
    if [[ "$verb" =~ $_COPY_VERBS_RE ]]; then
        if [[ "$allow_copy" == "1" ]]; then _classify_destino "$seg"; else echo "none"; fi
    elif [[ "$verb" =~ $_MENTION_VERBS_RE ]]; then
        echo "mention"
    elif [[ "$verb" == "git" ]]; then
        if [[ "$sub" == "mv" ]]; then
            # git mv = move → regra de cópia (origem+destino same-class). Respeita allow_copy
            # como os demais verbos de cópia: defere ao segmento no passe whole-cmd.
            if [[ "$allow_copy" == "1" ]]; then _classify_destino "$rest"; else echo "none"; fi
        elif [[ "$sub" =~ $_GIT_MENTION_SUB_RE ]] \
           && ! printf '%s' "$seg" | grep -qE "$_GIT_FILE_FLAG_RE"; then
            echo "mention"   # git commit/tag/... sem flag que leia arquivo
        else
            echo "read_expose"  # git show/diff/log/config/add/rm/stash OU mention-sub com -F/--file/-t
        fi
    else
        echo "read_expose"   # cat/grep/rg/sed/awk/source/head/tail/less + verbo desconhecido
    fi
}

# _has_git_file_flag_secret(cmd) — guard runtime INDEPENDENTE do DET_BASH.
# `git commit -F.env` / `-t.env.local` (secret COLADO à flag, sem path-sep) não casa DET_BASH
# (o precede exige path-sep/whitespace), então o classificador nem roda — mas `git commit`
# ecoa o subject no stdout, vazando a 1ª linha do secret. Detecta git (commit/tag/notes) +
# `-F`/`--file`/`-t`/`--template` cujo argumento (colado ou separado) é secret-class, sem
# depender do DET_BASH. Args não-secret (`-F changelog.md`) não casam → commit legítimo passa.
_GIT_FFS_BASE='(\.env([.a-z0-9_-]*)?|[^[:space:];|&"'"'"'/]*\.(key|pem)|credentials\.json|service-account[^[:space:]/]*\.json|[^[:space:];|&"'"'"'/]*-secret\.ya?ml)'
_has_git_file_flag_secret() {
    local text="$1"
    printf '%s' "$text" | grep -qE 'git[[:space:]]+(commit|tag|notes)([[:space:]]|$)' || return 1
    printf '%s' "$text" | grep -qE "(-F|--file|-t|--template)[=[:space:]]*[\"']?([^[:space:];|&\"']*/)?${_GIT_FFS_BASE}([^a-z0-9]|$)" \
        || printf '%s' "$text" | grep -qE "(-F|--file|-t|--template)[=[:space:]]*[\"']?([^[:space:];|&\"']*/)?(secrets?/)"
}

# _has_git_objectspec_secret(cmd) — guard runtime INDEPENDENTE do DET_BASH.
# `git show HEAD:.env` / `git cat-file -p :0:.env` / `git diff HEAD:secrets/x` lêem um secret
# VERSIONADO/STAGED e imprimem no stdout. O objectspec `<REV>:<path>` tem o `.env` precedido por
# `:` — fora do _PRECEDE do DET_BASH (mesmo gap do precede), então o classificador nem roda. Detecta
# git (show/cat-file/diff/log/grep) + um objectspec cujo path é secret-class, sem depender do DET_BASH.
_has_git_objectspec_secret() {
    local text="$1"
    printf '%s' "$text" | grep -qE 'git[[:space:]]+([^[:space:]]+[[:space:]]+)*(show|cat-file|diff|log|grep)([[:space:]]|$)' || return 1
    printf '%s' "$text" | grep -qE ':[^[:space:];|&"'"'"']*(\.env([.a-z0-9_-]*)?|[^[:space:];|&"'"'"'/:]*\.(key|pem)|credentials\.json|service-account[^[:space:];|&/:]*\.json|[^[:space:];|&"'"'"'/:]*-secret\.ya?ml)([^a-z0-9]|$)' \
        || printf '%s' "$text" | grep -qE ':[^[:space:];|&"'"'"']*secrets?/'
}

# _classify_secret_access(cmd) → classe de maior severidade do acesso ao secret.
# Pré-condição: DET_BASH já casou o comando. Combina (a) verbo-líder do comando inteiro
# (pega o caso command-substitution que esconde o verbo externo: `cat ` + "`printf x.key`")
# com (b) cada segmento que casa DET_BASH (pega o read interno: `echo "$(cat .env)"`).
_classify_secret_access() {
    local cmd="$1" seg c nl=$'\n' s
    local read=0 launder=0 copysafe=0 mention=0 rt

    # Passo 0: redireção de ENTRADA de um secret (`cmd < .env`) expõe conteúdo via stdin → read.
    while IFS= read -r rt; do
        [[ -z "$rt" ]] && continue
        rt="${rt%\"}"; rt="${rt#\"}"; rt="${rt%\'}"; rt="${rt#\'}"
        rt=$(printf '%s' "$rt" | tr '\\' '/')
        if printf '%s\n' "$rt" | grep -qE "$DET_PATH"; then echo "read_expose"; return; fi
    done < <(printf '%s\n' "$cmd" | grep -oE "<[[:space:]]*[\"']?[^[:space:];|&<>()\"']+" 2>/dev/null \
             | sed -E "s/^<[[:space:]]*[\"']?//")

    # (a) verbo-líder do comando inteiro — allow_copy=0 (cópia deferida aos segmentos).
    c=$(_verb_class_of "$cmd" 0)
    case "$c" in read_expose) read=1 ;; mention) mention=1 ;; esac

    # (b) segmentar por separadores de comando + command-substitution e classificar cada
    # segmento com secret-operando. Bash puro (sem `sed '\n'` — BSD/macOS não interpreta).
    s="$cmd"
    s="${s//'$('/$nl}"; s="${s//'`'/$nl}"
    s="${s//'&&'/$nl}"; s="${s//'||'/$nl}"
    s="${s//';'/$nl}"; s="${s//'|'/$nl}"; s="${s//'&'/$nl}"
    s="${s//'('/$nl}"; s="${s//')'/$nl}"
    while IFS= read -r seg; do
        [[ -z "$seg" ]] && continue
        printf '%s\n' "$seg" | grep -qE "$DET_BASH" || continue
        c=$(_verb_class_of "$seg" 1)
        case "$c" in
            read_expose)  read=1 ;;
            copy_launder) launder=1 ;;
            copy_safe)    copysafe=1 ;;
            mention)      mention=1 ;;
        esac
    done <<< "$s"

    if [[ "$read" == "1" ]]; then echo "read_expose"
    elif [[ "$launder" == "1" ]]; then echo "copy_launder"
    elif [[ "$copysafe" == "1" ]]; then echo "copy_safe"
    elif [[ "$mention" == "1" ]]; then echo "mention"
    else echo "read_expose"; fi   # default-deny
}

# _secret_log(tool, target_safe, retry_count, reason) — NDJSON append-only (auditoria).
# R2 exige logar cópias same-class permitidas; reusado pelo block path (§6).
_secret_log() {
    local _tool="$1" _target="$2" _retry="$3" _reason="$4"
    local _dir="$project_dir/context/evolution" _file
    _file="$_dir/secret-read-gate.log"
    if [[ ! -d "$_dir" ]]; then
        mkdir -p "$_dir" 2>/dev/null || _file="/tmp/brainiac-secret-read-gate-fallback.log"
    fi
    local _ts; _ts=$(date +'%Y-%m-%dT%H:%M:%S%z')
    local _sess="unknown"
    if command -v compute_sha256 >/dev/null 2>&1; then
        local _try; _try=$(compute_sha256 "$transcript_path" 2>/dev/null)
        [[ -n "$_try" ]] && _sess="$_try"
    fi
    printf '{"ts":"%s","tool":"%s","target":"%s","retry_count":%s,"reason":"%s","session_hash":"%s","user":"%s"}\n' \
        "$_ts" "$_tool" "$_target" "$_retry" "$_reason" "$_sess" "${USER:-unknown}" >> "$_file" 2>/dev/null
}

# Strip ANCORADO de .env.example (whitelist §3 Bash): remove só o token exato,
# preservando os delimitadores ao redor (\1 precede, \2 follow).
_SED_STRIP_EXAMPLE="s/(^|${_PRECEDE})\\.env\\.example(${_FOLLOW}|\$)/\\1\\2/g"

# === 2. Determine effective target string ===
target=""
case "$tool_name" in
    Read)  target="$file_path_norm" ;;
    Grep)  target="$grep_path_norm" ;;
    Glob)  target="$glob_pattern_norm" ;;
    Bash)  target="$bash_command" ;;
    *)     exit 0 ;;
esac

[[ -z "$target" ]] && exit 0

# === 3. Whitelist check: .env.example always passes (with informative notice) ===
# Para Read/Grep/Glob: target termina em .env.example.
# Para Bash: command menciona .env.example E NÃO menciona outros secrets.
target_is_example=0
case "$tool_name" in
    Read|Grep|Glob)
        if printf '%s\n' "$target" | grep -qE '(^|/)\.env\.example$'; then
            target_is_example=1
        fi
        ;;
    Bash)
        # Strip ANCORADO de .env.example + reaplica a detecção no resíduo:
        # example puro passa; comando misto (.env.example + secret real) bloqueia;
        # variante que não é o example (.env.example.local / .env.example_prod)
        # bloqueia; `jq '.env.x'` segue passando.
        if printf '%s\n' "$target" | grep -qE "(^|${_PRECEDE})\\.env\\.example(${_FOLLOW}|\$)"; then
            _stripped=$(printf '%s\n' "$target" | sed -E "$_SED_STRIP_EXAMPLE")
            if ! printf '%s\n' "$_stripped" | grep -qE "$DET_BASH"; then
                target_is_example=1
            fi
        fi
        ;;
esac

if [[ "$target_is_example" == "1" ]]; then
    {
        echo "$MSG_SECRET_GATE_HEADER — INFO"
        echo ""
        echo "$MSG_SECRET_GATE_EXAMPLE_NOTICE"
    } >&2
    exit 0
fi

# === 4. Detect secret class (DRY: DET_PATH/DET_BASH definidos no topo) ===
# `.env` discriminado por PRECEDE (path-sep, nunca aspa) → `jq '.env.x'`
# e `jq ".env.x"` passam; secret real (com qualquer delimitador shell ou aspa-com-
# separador-antes no follow) bloqueia.
target_hit=0
target_reason="secret_file"
det_class=""
case "$tool_name" in
    Read|Grep|Glob)
        if printf '%s\n' "$target" | grep -qE "$DET_PATH"; then
            target_hit=1
        fi
        ;;
    Bash)
        # Quando DET_BASH casa, classificar o VERBO (não bloquear pela mera
        # presença). read_expose/copy_launder bloqueiam; mention/copy_safe rebaixam (R1/R2).
        if printf '%s\n' "$target" | grep -qE "$DET_BASH"; then
            det_class=$(_classify_secret_access "$target")
        fi
        case "$det_class" in
            read_expose)  target_hit=1; target_reason="secret_file" ;;
            copy_launder) target_hit=1; target_reason="copy_launder" ;;
        esac
        # Runtime guards são INDEPENDENTES: rodam mesmo quando DET_BASH foi rebaixado
        # (mention/copy_safe), pois um comando pode mencionar .env numa string E exfiltrar
        # process.env em outro segmento.
        if [[ "$target_hit" == "0" ]] \
          && { _has_runtime_secret_file_api "$target" \
            || _has_env_command_exfil "$target" \
            || _has_runtime_env_value_exfil "$target" \
            || _has_git_file_flag_secret "$target" \
            || _has_git_objectspec_secret "$target" \
            || _scan_runtime_script_sources "$target"; }; then
            target_hit=1
            target_reason="runtime_env"
        fi
        # Expansão de shell é guard INDEPENDENTE e tem reason próprio: a mensagem
        # de block precisa ensinar a forma segura (`${VAR:+x}` / `${#VAR}`), que não tem
        # nada a ver com o hint de process.env do runtime_env.
        if [[ "$target_hit" == "0" ]] && _has_shell_env_value_exfil "$target"; then
            target_hit=1
            target_reason="shell_env_value"
        fi
        ;;
esac

# R2: cópia opaca same-class (origem+destino secret-class) — permitida, logada, com INFO.
# O secret continua etiquetado no destino (leituras futuras seguem bloqueadas); não há
# byte exposto ao modelo (arquivo → arquivo). Auditável no log com reason=copy_safe.
if [[ "$tool_name" == "Bash" && "$target_hit" == "0" && "$det_class" == "copy_safe" ]]; then
    copy_target_safe=$(printf '%s\n' "$target" | head -c 200 | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r')
    _secret_log "$tool_name" "$copy_target_safe" 0 "copy_safe"
    {
        echo "$MSG_SECRET_GATE_HEADER — INFO"
        echo ""
        echo "$MSG_SECRET_GATE_COPY_NOTICE"
    } >&2
    exit 0
fi

# Target não casa pattern de secret — pass-through
[[ "$target_hit" == "0" ]] && exit 0

# === 5. Trip-wire: contar tentativas REAIS e RECENTES no transcript ===
# Duas premissas do contador:
#  (a) POR-TOOL, não `tostring`: extrai o valor cru de cada tool_use (Bash→command,
#      Read/Grep/Glob→path) e aplica a regex daquele tool (DET_BASH/DET_PATH).
#      Evita a ambiguidade do `tostring` (que cercava tudo de aspas JSON e contava
#      `jq ".env.x"` como tentativa). `jq '.env.x'`/`jq ".env.x"` não casam
#      DET_BASH (precede aspa).
#  (b) RECÊNCIA, não transcript inteiro: o transcript NÃO trunca em /compact
#      (insere `compact_boundary`, mantém sessionId; não há marcador de `resume`),
#      então varrer tudo fazia o contador nunca zerar e escalar `RETRY` espúrio.
#      Conta só os últimos N tool_use (BRAINIAC_SECRET_RETRY_WINDOW, default 10,
#      sanitizado). MITIGAÇÃO por recência — não isola a sessão deterministicamente
#      (hardening futuro: reset via SessionStart, que recebe source=resume).
N="${BRAINIAC_SECRET_RETRY_WINDOW:-10}"
[[ "$N" =~ ^[1-9][0-9]*$ ]] || N=10
retry_count=0
if [[ -f "$transcript_path" ]]; then
    tw_stream=$(jq -r '
        select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use")
        | if .name == "Bash" then "B " + ((.input.command // "") | gsub("\n"; " "))
          elif (.name == "Read" or .name == "Grep" or .name == "Glob")
               then "P " + ((.input.file_path // .input.path // .input.pattern // "") | gsub("\n"; " "))
          else empty end
    ' "$transcript_path" 2>/dev/null | tail -n "$N")
    # R3: só conta como tentativa um Bash que classifica como leitura/exfil
    # REAL (read_expose/copy_launder). Menção textual e cópia same-class NÃO contam —
    # mata o "trip-wire envenenado" (um `git commit -m "...env..."` não escala o próximo
    # comando legítimo a RETRY DETECTED). Pré-filtra por DET_BASH (barato) antes de classificar.
    tw_b=0
    while IFS= read -r _bcmd; do
        [[ -z "$_bcmd" ]] && continue
        case "$(_classify_secret_access "$_bcmd")" in
            read_expose|copy_launder) tw_b=$((tw_b + 1)) ;;
        esac
    done < <(printf '%s\n' "$tw_stream" | sed -n 's/^B //p' | grep -E "$DET_BASH" 2>/dev/null)
    tw_p=$(printf '%s\n' "$tw_stream" | sed -n 's/^P //p' | grep -cE "$DET_PATH" 2>/dev/null)
    tw_p=$(printf '%s\n' "$tw_p" | tr -d '[:space:]'); [[ "$tw_p" =~ ^[0-9]+$ ]] || tw_p=0
    retry_count=$((tw_b + tw_p))
fi

# === 6. Log attempt (NDJSON append-only) ===
log_dir="$project_dir/context/evolution"
log_file="$log_dir/secret-read-gate.log"
if [[ ! -d "$log_dir" ]]; then
    if ! mkdir -p "$log_dir" 2>/dev/null; then
        log_file="/tmp/brainiac-secret-read-gate-fallback.log"
    fi
fi

ts=$(date +'%Y-%m-%dT%H:%M:%S%z')
sess_hash="unknown"
if command -v compute_sha256 >/dev/null 2>&1; then
    sess_hash_try=$(compute_sha256 "$transcript_path" 2>/dev/null)
    [[ -n "$sess_hash_try" ]] && sess_hash="$sess_hash_try"
fi
# Truncate + escape target for JSON safety (200 chars max)
target_safe=$(printf '%s\n' "$target" | head -c 200 | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r')
# Campo reason (secret_file/runtime_env/copy_launder) para auditoria forense.
printf '{"ts":"%s","tool":"%s","target":"%s","retry_count":%s,"reason":"%s","session_hash":"%s","user":"%s"}\n' \
    "$ts" "$tool_name" "$target_safe" "$retry_count" "$target_reason" "$sess_hash" "${USER:-unknown}" >> "$log_file" 2>/dev/null

# === 7. Block (escalate on retry) ===
if [[ "$retry_count" -ge 1 ]]; then
    attempt_n=$((retry_count + 1))
    retry_body=$(printf '%s\n' "$MSG_SECRET_GATE_RETRY_BODY" | sed "s/N/$attempt_n/")
    {
        echo "$MSG_SECRET_GATE_RETRY_HEADER"
        echo ""
        echo "$retry_body"
        echo ""
        echo "Tool: $tool_name | Target (truncated): $target_safe"
    } >&2
    exit 2
fi

# First attempt — standard block
if [[ "$target_reason" == "runtime_env" ]]; then
    block_body="$MSG_SECRET_GATE_ENV_BLOCKED"
    block_hint="$MSG_SECRET_GATE_ENV_HINT"
elif [[ "$target_reason" == "copy_launder" ]]; then
    block_body="$MSG_SECRET_GATE_COPY_LAUNDER_BLOCKED"
    block_hint="$MSG_SECRET_GATE_COPY_LAUNDER_HINT"
elif [[ "$target_reason" == "shell_env_value" ]]; then
    block_body="$MSG_SECRET_GATE_SHELLVAR_BLOCKED"
    block_hint="$MSG_SECRET_GATE_SHELLVAR_HINT"
else
    block_body="$MSG_SECRET_GATE_BLOCKED"
    block_hint="$MSG_SECRET_GATE_HINT"
fi
{
    echo "$MSG_SECRET_GATE_HEADER"
    echo ""
    echo "$block_body"
    echo ""
    echo "Tool: $tool_name | Target: $target_safe"
    echo ""
    echo "$block_hint"
} >&2

exit 2
