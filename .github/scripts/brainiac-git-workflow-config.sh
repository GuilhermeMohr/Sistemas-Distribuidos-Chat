#!/usr/bin/env bash
# PROJEÇÃO do canonical Brainiac — NÃO EDITAR.
#
# Instalada e verificada por hash por /brainiac-context-github. Editar aqui
# cria um fork silencioso: projeção e fonte divergem sem que nada acuse.
# Ajustes vão na fonte canonical; o corpo abaixo é cópia byte-a-byte dela.
#
# BRAINIAC:PROJECTION-SOURCE integrations/git/lib/git-workflow-config.sh
# BRAINIAC:PROJECTION-BODY-START
# git-workflow-config.sh — resolver único da política de workflow Git.
#
# Fonte ÚNICA de parsing, validação e fallback de `config/gitflow.json`.
# Consumidores (motor de política de branch, lifecycle de worktree, hook de
# pre-push, skills de Build/worktree/orquestração) DEVEM sourciar este arquivo;
# nenhum deles lê o JSON por conta própria. Reimplementar a semântica em um
# consumidor faz detectores irmãos divergirem silenciosamente.
#
# Source-only: apenas function defs e variáveis. NÃO seta `set -euo pipefail`
# (contaminaria o caller).
#
# Camada Git, não GitHub: worktrees e resolução de branch independem de onde o
# repositório está hospedado.
#
# shellcheck disable=SC2034
# As variáveis GWC_* são a interface pública do resolver: quem sourcia este
# arquivo as lê após `gwc_load`. Não são atribuições mortas.

[[ -n "${_BRAINIAC_GWC_SH:-}" ]] && return 0
_BRAINIAC_GWC_SH=1

# Versão de schema suportada. Desconhecida => falha explícita, nunca fallback.
readonly GWC_SCHEMA_SUPPORTED=1

# Tipos de branch reconhecidos quando a config não os enumera.
readonly GWC_DEFAULT_BRANCH_TYPES="feat feature fix bugfix chore docs test refactor style perf ci build"

# Perfis válidos.
readonly GWC_VALID_PROFILES="lean github-flow"

# Estado resolvido (preenchido por gwc_load). Estas variáveis SÃO a interface
# pública do resolver: os consumidores as leem após `gwc_load`. Não são "unused".
# shellcheck disable=SC2034
GWC_STATE=""              # legacy | lean | github-flow
GWC_PROFILE=""
GWC_PRODUCTION_BRANCH=""
GWC_INTEGRATION_BRANCH=""
GWC_BRANCH_TYPES=""
GWC_REQUIRE_ISSUE_FOR=""
GWC_RELEASE_ACCEPTS=""
GWC_ENFORCEMENT=""
GWC_SUPPORTS_RELEASE=0
GWC_CLAUDE_ROOT=""
GWC_CODEX_ROOT=""
GWC_RESERVED_ID_PREFIXES=""
GWC_ID_MAX_LENGTH=""
GWC_ID_HASH_ALGO=""
GWC_ID_HASH_LEN=""
GWC_FORCE_REMOVE=""
GWC_AUTO_PRUNE=""
GWC_ERROR=""

# _gwc_fail(msg) — registra o campo ofensor e sinaliza config inválida.
_gwc_fail() {
    GWC_ERROR="$1"
    printf 'brainiac: config de workflow inválida — %s\n' "$1" >&2
    return 2
}

# gwc_config_path() — caminho da config. Override por env (usado por testes e
# por consumidores que já resolveram a raiz); senão <repo-root>/config/gitflow.json.
gwc_config_path() {
    # `BRAINIAC_GITFLOW_CONFIG` troca a AUTORIDADE inteira: aponta o resolver
    # para outro arquivo e, com isso, redefine produção, integração e conjunto
    # protegido. Isso contradiz o contrato de que a config é autoridade e o
    # ambiente só endurece — por isso NÃO é interface pública.
    #
    # Fica restrito a modo de teste, sinalizado explicitamente. Sem o opt-in a
    # variável é ignorada com aviso, em vez de silenciosamente obedecida.
    if [[ -n "${BRAINIAC_GITFLOW_CONFIG:-}" ]]; then
        if [[ "${BRAINIAC_GWC_TEST_MODE:-0}" == "1" ]]; then
            printf '%s\n' "$BRAINIAC_GITFLOW_CONFIG"
            return 0
        fi
        printf 'brainiac: BRAINIAC_GITFLOW_CONFIG ignorada — override de autoridade exige BRAINIAC_GWC_TEST_MODE=1 (uso restrito a testes).\n' >&2
    fi
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="$PWD"
    printf '%s/config/gitflow.json\n' "$root"
}

# _gwc_defaults() — estado legado: comportamento idêntico ao de um projeto que
# nunca ouviu falar de perfil. Integração É produção; sem release/hotfix.
_gwc_defaults() {
    GWC_STATE="legacy"
    GWC_PROFILE="legacy"
    GWC_PRODUCTION_BRANCH="main"
    GWC_INTEGRATION_BRANCH="main"
    GWC_BRANCH_TYPES="$GWC_DEFAULT_BRANCH_TYPES"
    GWC_REQUIRE_ISSUE_FOR="feat feature fix bugfix"
    GWC_RELEASE_ACCEPTS=""
    GWC_ENFORCEMENT="advisory"
    GWC_SUPPORTS_RELEASE=0
    GWC_CLAUDE_ROOT=".claude/worktrees/brainiac"
    GWC_CODEX_ROOT=".codex/worktrees/brainiac"
    GWC_RESERVED_ID_PREFIXES="wf_"
    GWC_ID_MAX_LENGTH="40"
    GWC_ID_HASH_ALGO="sha256"
    GWC_ID_HASH_LEN="8"
    GWC_FORCE_REMOVE="false"
    GWC_AUTO_PRUNE="false"
}

# _gwc_parse_once(file) — UMA passada de jq emitindo todos os campos como
# `chave<TAB>valor`. Consumidores iteram em memória.
#
# Por que passada única: um `jq` por campo multiplica forks; num laço de casos
# de teste isso vira centenas de processos e o custo explode em Windows/MSYS,
# onde spawn é caro. Arrays viram lista separada por espaço no próprio jq.
#
# `tr -d '\r'`: jq em Windows emite CRLF; sem isso um valor chega como `feat\r`
# e nunca casa com `feat` em comparação de string.
_gwc_parse_once() {
    # `set -o pipefail` LOCAL: sem ele o status do `tr` mascara a falha do jq, e
    # a função retornaria 0 sobre uma leitura que não terminou. Restaurado no
    # fim para não contaminar o caller.
    local _had_pf=0
    case "$-" in *f*) : ;; esac
    [[ -o pipefail ]] && _had_pf=1 || set -o pipefail

    local _out _rc=0
    _out="$(
    jq -r '
      def lst: (. // []) | map(tostring) | join(" ");
      [ "schema_version\t\(.schema_version // "")"
      , "has_gitflow\t\(if .gitflow then "1" else "0" end)"
      , "has_worktrees\t\(if .worktrees then "1" else "0" end)"
      , "profile\t\(.gitflow.profile // "")"
      , "production_branch\t\(.gitflow.production_branch // "")"
      , "integration_branch\t\(.gitflow.integration_branch // "")"
      , "branch_types\t\(.gitflow.branch_types | lst)"
      , "require_issue_for\t\(.gitflow.require_issue_for | lst)"
      , "release_accepts\t\(.gitflow.release_accepts | lst)"
      , "enforcement\t\(.gitflow.enforcement // "")"
      , "claude_root\t\(.worktrees.claude_root // "")"
      , "codex_root\t\(.worktrees.codex_root // "")"
      , "reserved_id_prefixes\t\(.worktrees.reserved_id_prefixes | lst)"
      , "id_max_length\t\(.worktrees.id_max_length // "")"
      , "id_hash_algo\t\(.worktrees.id_hash_algo // "")"
      , "id_hash_len\t\(.worktrees.id_hash_len // "")"
      , "force_remove\t\(.worktrees.force_remove // "")"
      , "auto_prune\t\(.worktrees.auto_prune // "")"
      ] | .[]
    ' "$1" 2>/dev/null | tr -d '\r'
    )" || _rc=$?

    [[ "$_had_pf" == "1" ]] || set +o pipefail
    printf '%s\n' "$_out"
    return "$_rc"
}

# _gwc_contains(haystack_words, needle)
_gwc_contains() {
    case " $1 " in *" $2 "*) return 0 ;; esac
    return 1
}

# gwc_load([path]) — resolve o estado. 0 = ok (legado ou perfil), 2 = inválida.
#
# Quatro estados formais:
#   legado       arquivo ausente  -> defaults; comportamento atual preservado
#   lean         perfil completo  -> exige integration != production
#   github-flow  integração = produção; sem release/hotfix branches
#   inválido     falha EXPLÍCITA, nunca fallback silencioso
gwc_load() {
    local cfg="${1:-$(gwc_config_path)}"
    GWC_ERROR=""

    _gwc_defaults

    [[ -f "$cfg" ]] || return 0   # estado legado

    command -v jq >/dev/null 2>&1 || { _gwc_fail "jq indisponível; necessário para ler $cfg"; return 2; }

    # Passada única, com o EXIT CODE do jq verificado.
    #
    # Checar apenas "saída não-vazia" aceita saída PARCIAL de um jq que falhou no
    # meio: os campos que saíram viram configuração, os que faltaram viram
    # default silencioso, e uma config quebrada passa por válida. O código de
    # saída é a única evidência de que a leitura terminou.
    local parsed parse_rc=0
    parsed="$(_gwc_parse_once "$cfg")" || parse_rc=$?
    if [[ "$parse_rc" != "0" ]]; then
        _gwc_fail "falha ao ler $cfg (jq saiu com $parse_rc); JSON malformado ou ilegível"
        return 2
    fi
    [[ -n "$parsed" ]] || { _gwc_fail "JSON malformado ou vazio em $cfg"; return 2; }

    # Iteração em memória sobre o resultado da passada única.
    local k v
    local p_schema="" p_has_gitflow="0"
    local p_profile="" p_prod="" p_integ="" p_types="" p_require="" p_accepts="" p_enforce=""
    while IFS=$'\t' read -r k v; do
        case "$k" in
            schema_version)       p_schema="$v" ;;
            has_gitflow)          p_has_gitflow="$v" ;;
            profile)              p_profile="$v" ;;
            production_branch)    p_prod="$v" ;;
            integration_branch)   p_integ="$v" ;;
            branch_types)         p_types="$v" ;;
            require_issue_for)    p_require="$v" ;;
            release_accepts)      p_accepts="$v" ;;
            enforcement)          p_enforce="$v" ;;
            claude_root)          [[ -n "$v" ]] && GWC_CLAUDE_ROOT="$v" ;;
            codex_root)           [[ -n "$v" ]] && GWC_CODEX_ROOT="$v" ;;
            reserved_id_prefixes) [[ -n "$v" ]] && GWC_RESERVED_ID_PREFIXES="$v" ;;
            id_max_length)        [[ -n "$v" ]] && GWC_ID_MAX_LENGTH="$v" ;;
            id_hash_algo)         [[ -n "$v" ]] && GWC_ID_HASH_ALGO="$v" ;;
            id_hash_len)          [[ -n "$v" ]] && GWC_ID_HASH_LEN="$v" ;;
            force_remove)         [[ -n "$v" ]] && GWC_FORCE_REMOVE="$v" ;;
            auto_prune)           [[ -n "$v" ]] && GWC_AUTO_PRUNE="$v" ;;
        esac
    done <<< "$parsed"

    [[ -n "$p_schema" ]] || { _gwc_fail "campo obrigatório ausente: schema_version"; return 2; }
    [[ "$p_schema" == "$GWC_SCHEMA_SUPPORTED" ]] || {
        _gwc_fail "schema_version '$p_schema' desconhecido (suportado: $GWC_SCHEMA_SUPPORTED)"; return 2; }

    # Bloco gitflow ausente => só o eixo worktrees foi configurado; a política de
    # branch segue no estado legado.
    if [[ "$p_has_gitflow" == "1" ]]; then
        [[ -n "$p_profile" ]] || { _gwc_fail "campo obrigatório ausente: gitflow.profile"; return 2; }
        _gwc_contains "$GWC_VALID_PROFILES" "$p_profile" || {
            _gwc_fail "gitflow.profile '$p_profile' fora do enum ($GWC_VALID_PROFILES)"; return 2; }

        [[ -n "$p_prod" ]] || p_prod="main"
        # integration_branch nulo/ausente resolve para produção — o default
        # distribuído, que preserva o comportamento legado.
        [[ -n "$p_integ" && "$p_integ" != "null" ]] || p_integ="$p_prod"

        if [[ "$p_profile" == "lean" && "$p_integ" == "$p_prod" ]]; then
            _gwc_fail "gitflow.profile 'lean' exige integration_branch != production_branch (ambos '$p_prod'); uma integração que É produção não é Lean"
            return 2
        fi

        # A recíproca vale e precisa ser dita: `github-flow` é definido por
        # integração e produção serem a MESMA branch. Validar só o lado lean
        # deixa passar uma config que declara `github-flow` e nomeia integração
        # separada — o consumidor então roteia trabalho para uma branch de
        # integração num perfil que, por contrato, não tem nenhuma, e o motor de
        # política resolve pelo perfil enquanto o resolver resolve pelo campo.
        # Duas verdades sobre a mesma pergunta é o estado que os quatro estados
        # formais existem para impedir.
        if [[ "$p_profile" == "github-flow" && "$p_integ" != "$p_prod" ]]; then
            _gwc_fail "gitflow.profile 'github-flow' exige integration_branch == production_branch (recebeu integração '$p_integ' e produção '$p_prod'); para topologia com integração separada use profile 'lean'"
            return 2
        fi

        # `lean` exige que a integração EXISTA. Um perfil apontando para uma
        # branch ausente produziria pull requests contra uma base que ninguém
        # pode mergear, e o erro só apareceria no GitHub, longe da causa.
        # Fail-closed: a config nomeia o que não existe, então a config está
        # errada.
        #
        # Só verificável dentro de um repositório: fora dele a pergunta não tem
        # resposta, e ausência de resposta não vira veredito — daí o guard.
        # O skip da verificação de existência é bypass de um fail-closed, então
        # exige o MESMO opt-in de teste que o override de config. Um bypass
        # irrestrito por ambiente reabre exatamente o buraco que o fail-closed
        # fecha: bastaria exportar a variável para aceitar uma integração que
        # não existe.
        if [[ "$p_profile" == "lean" ]] \
           && ! { [[ "${BRAINIAC_GWC_SKIP_REF_EXISTS:-0}" == "1" ]] && [[ "${BRAINIAC_GWC_TEST_MODE:-0}" == "1" ]]; }; then
            if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
                if ! git show-ref --verify --quiet "refs/heads/$p_integ" \
                   && ! git show-ref --verify --quiet "refs/remotes/origin/$p_integ"; then
                    _gwc_fail "gitflow.profile 'lean' nomeia integration_branch '$p_integ', que não existe local nem em origin; crie a branch antes de ativar o perfil (decisão humana) ou use profile 'github-flow'"
                    return 2
                fi
            fi
        fi

        [[ -n "$p_types" ]] || p_types="$GWC_DEFAULT_BRANCH_TYPES"

        local t
        for t in $p_require; do
            _gwc_contains "$p_types" "$t" || {
                _gwc_fail "gitflow.require_issue_for contém tipo desconhecido: '$t'"; return 2; }
        done
        for t in $p_accepts; do
            _gwc_contains "$p_types" "$t" || {
                _gwc_fail "gitflow.release_accepts contém tipo desconhecido: '$t'"; return 2; }
        done

        GWC_STATE="$p_profile"
        GWC_PROFILE="$p_profile"
        GWC_PRODUCTION_BRANCH="$p_prod"
        GWC_INTEGRATION_BRANCH="$p_integ"
        GWC_BRANCH_TYPES="$p_types"
        GWC_REQUIRE_ISSUE_FOR="$p_require"
        GWC_RELEASE_ACCEPTS="$p_accepts"
        GWC_ENFORCEMENT="${p_enforce:-advisory}"
        [[ "$p_profile" == "lean" ]] && GWC_SUPPORTS_RELEASE=1 || GWC_SUPPORTS_RELEASE=0
    fi

    # --- Validação do eixo worktrees -------------------------------------
    # Sem isto, valores absurdos passam por gwc_load e só explodem depois, em
    # aritmética ou em operação de filesystem — fora do contrato de erro
    # explícito, e longe do campo que causou o problema.
    local n
    for n in "$GWC_ID_MAX_LENGTH" "$GWC_ID_HASH_LEN"; do
        [[ "$n" =~ ^[0-9]+$ ]] || {
            _gwc_fail "worktrees: id_max_length e id_hash_len devem ser inteiros (obtido '$n')"; return 2; }
    done
    # Piso de 4: abaixo disso o sufixo tem espaço de colisão trivial e deixa de
    # cumprir a função de desambiguar branches truncadas.
    # Teto de 64: é o comprimento hex do SHA-256. Pedir mais entregaria menos
    # caracteres do que o configurado, em silêncio.
    (( GWC_ID_HASH_LEN >= 4 && GWC_ID_HASH_LEN <= 64 )) || {
        _gwc_fail "worktrees.id_hash_len deve estar entre 4 e 64 (obtido $GWC_ID_HASH_LEN); abaixo de 4 colide trivialmente, acima de 64 excede o hex do SHA-256"
        return 2; }
    # Teto de 200: nomes de componente de path têm limite real de filesystem
    # (255 na maioria, menos em caminhos longos no Windows). Sem teto, um valor
    # enorme só falharia no filesystem, longe do campo que o causou.
    (( GWC_ID_MAX_LENGTH >= 8 && GWC_ID_MAX_LENGTH <= 200 )) || {
        _gwc_fail "worktrees.id_max_length deve estar entre 8 e 200 (obtido $GWC_ID_MAX_LENGTH)"
        return 2; }
    (( GWC_ID_MAX_LENGTH > GWC_ID_HASH_LEN + 1 )) || {
        _gwc_fail "worktrees.id_max_length ($GWC_ID_MAX_LENGTH) precisa exceder id_hash_len ($GWC_ID_HASH_LEN) + 1; senão a truncagem não deixa espaço para o slug"
        return 2; }

    case "$GWC_ID_HASH_ALGO" in
        sha256) : ;;
        *) _gwc_fail "worktrees.id_hash_algo '$GWC_ID_HASH_ALGO' não suportado (aceito: sha256)"; return 2 ;;
    esac

    local b
    for b in "$GWC_FORCE_REMOVE" "$GWC_AUTO_PRUNE"; do
        case "$b" in
            true|false) : ;;
            *) _gwc_fail "worktrees: force_remove e auto_prune devem ser booleanos (obtido '$b')"; return 2 ;;
        esac
    done

    # Roots precisam ser relativos e sem traversal: um root absoluto ou com `..`
    # coloca worktrees fora do repositório por configuração.
    local r
    for r in "$GWC_CLAUDE_ROOT" "$GWC_CODEX_ROOT"; do
        [[ -n "$r" ]] || { _gwc_fail "worktrees: root vazio"; return 2; }
        case "$r" in
            /*|[A-Za-z]:[/\\]*) _gwc_fail "worktrees: root '$r' é absoluto; use caminho relativo à raiz do repositório"; return 2 ;;
            *..*)               _gwc_fail "worktrees: root '$r' contém '..'"; return 2 ;;
        esac
    done

    case "$GWC_ENFORCEMENT" in
        advisory|enforced) : ;;
        *) _gwc_fail "gitflow.enforcement '$GWC_ENFORCEMENT' fora do enum (advisory|enforced)"; return 2 ;;
    esac

    # Nome de branch: quem decide o que é válido é o próprio Git, não um filtro
    # manual. `check-ref-format` conhece as formas que uma lista escrita à mão
    # esquece — `foo~bar`, `foo^bar`, `foo:bar`, `foo?bar`, `foo[bar`,
    # `foo@{bar`, componente terminado em ponto. Reimplementar essa gramática é
    # convite a divergir dela.
    for b in "$GWC_PRODUCTION_BRANCH" "$GWC_INTEGRATION_BRANCH"; do
        [[ -n "$b" ]] || { _gwc_fail "branch de produção/integração vazia"; return 2; }
        if command -v git >/dev/null 2>&1; then
            git check-ref-format --branch "$b" >/dev/null 2>&1 \
                || { _gwc_fail "nome de branch inválido segundo git check-ref-format: '$b'"; return 2; }
        else
            # Fallback quando o git não está no PATH. Precisa ser um SUBCONJUNTO
            # estrito do que o git aceita — um fallback mais permissivo que o
            # validador real deixa passar nomes que quebram depois, e a promessa
            # de "conservador" vira falsa.
            #
            # Charset restrito, e cada forma que o git recusa é recusada aqui:
            # `..`, `@{`, barra final ou inicial, barras consecutivas, sufixo
            # `.lock`, e componente começando ou terminando em ponto.
            if ! [[ "$b" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
               || [[ "$b" == *..* || "$b" == *@\{* || "$b" == */ || "$b" == /* \
                     || "$b" == *//* || "$b" == *. \
                     || "$b" == *"/."* || "$b" == *"./"* ]]; then
                _gwc_fail "nome de branch inválido: '$b'"; return 2
            fi
            # `.lock` é proibido em QUALQUER componente, não só no fim do nome:
            # `foo.lock/bar` é recusado pelo git. Checar apenas o sufixo do nome
            # completo deixaria o fallback mais permissivo que o validador real.
            local _seg
            local _rest="$b"
            while [[ -n "$_rest" ]]; do
                _seg="${_rest%%/*}"
                [[ "$_seg" == *.lock ]] && { _gwc_fail "nome de branch inválido: componente '.lock' em '$b'"; return 2; }
                [[ "$_rest" == */* ]] && _rest="${_rest#*/}" || _rest=""
            done
        fi
    done

    return 0
}

# gwc_protected_branches() — conjunto protegido, uma branch por linha.
#
# Precedência: a config é autoridade. `BRAINIAC_PROTECTED_BRANCHES` só ENDURECE
# — acrescenta branches ao conjunto e NUNCA remove nem substitui as que a config
# determinou. Um env vazio, ou apontando para outro conjunto, não consegue
# desproteger produção ou integração.
gwc_protected_branches() {
    local out="$GWC_PRODUCTION_BRANCH"
    [[ -n "$GWC_INTEGRATION_BRANCH" && "$GWC_INTEGRATION_BRANCH" != "$GWC_PRODUCTION_BRANCH" ]] \
        && out="$out $GWC_INTEGRATION_BRANCH"

    if [[ -n "${BRAINIAC_PROTECTED_BRANCHES:-}" ]]; then
        local extra b
        # `set -f` impede que um `*` no env expanda para nomes de arquivo.
        set -f
        # shellcheck disable=SC2206 # word-splitting intencional, glob desligado
        extra=( ${BRAINIAC_PROTECTED_BRANCHES//,/ } )
        set +f
        for b in "${extra[@]}"; do
            [[ -n "$b" ]] || continue
            _gwc_contains "$out" "$b" || out="$out $b"
        done
    fi

    printf '%s\n' $out
}

# gwc_is_protected(branch) — 0 se protegida.
gwc_is_protected() {
    local b
    while IFS= read -r b; do
        [[ "$b" == "$1" ]] && return 0
    done < <(gwc_protected_branches)
    return 1
}
