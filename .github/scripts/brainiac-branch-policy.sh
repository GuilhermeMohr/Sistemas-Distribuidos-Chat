#!/usr/bin/env bash
# PROJEÇÃO do canonical Brainiac — NÃO EDITAR.
#
# Instalada e verificada por hash por /brainiac-context-github. Editar aqui
# cria um fork silencioso: projeção e fonte divergem sem que nada acuse.
# Ajustes vão na fonte canonical; o corpo abaixo é cópia byte-a-byte dela.
#
# BRAINIAC:PROJECTION-SOURCE integrations/github/scripts/branch-policy.sh
# BRAINIAC:PROJECTION-BODY-START
# branch-policy.sh — veredito determinístico de política de branch (head × base).
#
# Uso:
#   branch-policy.sh --head <branch> --base <branch> [--quiet]
#
# Exit codes (contrato):
#   0  aceita
#   1  bloqueia (viola a política)
#   2  configuração inválida — falha explícita, nunca fallback silencioso
#
# Implementação ÚNICA da política, consumida pelo workflow de CI, pela suíte
# determinística e pelas skills. A resolução da config vem toda de
# git-workflow-config.sh; este arquivo não faz parsing de configuração.
#
# Diagnóstico, não enforcement: um veredito de bloqueio aqui reporta. Enforcement
# real depende de branch protection ou ruleset server-side configurado para
# bloquear no repositório.
set -uo pipefail

_bp_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolver compartilhado. Duas origens possíveis: layout canonical do framework
# (integrations/git/lib/) e layout projetado no adopter (mesmo diretório).
for _cand in \
    "$_bp_script_dir/../../git/lib/git-workflow-config.sh" \
    "$_bp_script_dir/brainiac-git-workflow-config.sh" \
    "${BRAINIAC_GIT_WORKFLOW_CONFIG_LIB:-}"
do
    if [[ -n "$_cand" && -f "$_cand" ]]; then
        # shellcheck source=/dev/null
        source "$_cand"
        _bp_resolver="$_cand"
        break
    fi
done

if [[ -z "${_bp_resolver:-}" ]]; then
    printf 'brainiac: resolver de config não encontrado (git-workflow-config.sh)\n' >&2
    exit 2
fi

HEAD_REF=""
BASE_REF=""
VALIDATE_REF=""
QUIET=0

# Toda flag de valor exige valor PRESENTE e NÃO-VAZIO. Sem o guard, `shift 2`
# com $#==1 não desloca e retorna 1: `$1` continua sendo a mesma flag, a
# condição do laço segue verdadeira e o `case` casa o mesmo arm para sempre —
# busy-loop a 100% de CPU, sem mensagem e sem exit code. Este script não liga
# `set -e`, então nada aborta o laço. O `${2:-}` que estava aqui mascarava a
# causa: convertia a ausência do argumento em string vazia.
# Este arquivo é projetado para `.github/scripts/` e roda no CI: um busy-loop
# aqui consome o runner até o timeout do job.
_bp_need_val() {
    [[ $# -ge 2 && -n "${2:-}" ]] && return 0
    printf 'brainiac: %s exige um valor não-vazio\n' "$1" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --head)  _bp_need_val "$@"; HEAD_REF="$2"; shift 2 ;;
        --base)  _bp_need_val "$@"; BASE_REF="$2"; shift 2 ;;
        --validate-ref) _bp_need_val "$@"; VALIDATE_REF="$2"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        -h|--help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) printf 'brainiac: flag desconhecida: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ -n "$VALIDATE_REF" ]]; then
    [[ -z "$HEAD_REF$BASE_REF" ]] || {
        printf 'brainiac: --validate-ref não combina com --head/--base\n' >&2; exit 2; }
else
    [[ -n "$HEAD_REF" && -n "$BASE_REF" ]] || {
        printf 'brainiac: --head e --base são obrigatórios\n' >&2; exit 2; }
fi

# Normaliza refs vindas de eventos do GitHub (refs/heads/x -> x).
HEAD_REF="${HEAD_REF#refs/heads/}"
BASE_REF="${BASE_REF#refs/heads/}"
VALIDATE_REF="${VALIDATE_REF#refs/heads/}"

gwc_load || exit 2

_say() { [[ "$QUIET" == "1" ]] || printf '%s\n' "$*"; }

_accept() { _say "accept: $1"; exit 0; }
_block()  { _say "block: $1";  exit 1; }

_has() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

# SemVer estrito: cada componente é `0` ou começa com dígito não-zero. A forma
# frouxa `[0-9]+` aceitaria `v01.002.0003`, que SemVer proíbe — e classificar uma
# release malformada como válida é pior que recusá-la, porque a tag que sai dali
# não ordena corretamente contra as demais.
SEMVER='v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'

# --- Validação de ref isolada (evento push, sem par head/base) ---------------
# Confirma que a ref é uma branch de longa vida RECONHECIDA pela política. Um
# filtro de trigger deixa passar `release/**`; só aqui se decide se
# `release/not-semver` é realmente uma release.
if [[ -n "$VALIDATE_REF" ]]; then
    if [[ "$VALIDATE_REF" == "$GWC_PRODUCTION_BRANCH" ]]; then
        _accept "'$VALIDATE_REF' é a branch de produção"
    elif [[ "$VALIDATE_REF" == "$GWC_INTEGRATION_BRANCH" ]]; then
        _accept "'$VALIDATE_REF' é a branch de integração"
    elif [[ "$GWC_SUPPORTS_RELEASE" == "1" ]] && [[ "$VALIDATE_REF" =~ ^release/${SEMVER}$ ]]; then
        _accept "'$VALIDATE_REF' é uma branch de release válida"
    elif [[ "$GWC_SUPPORTS_RELEASE" == "1" ]] && [[ "$VALIDATE_REF" =~ ^hotfix/${SEMVER}-[a-z0-9._-]+$ ]]; then
        _accept "'$VALIDATE_REF' é uma branch de hotfix válida"
    else
        _block "'$VALIDATE_REF' não é uma branch de longa vida reconhecida pela política (produção: '$GWC_PRODUCTION_BRANCH', integração: '$GWC_INTEGRATION_BRANCH')"
    fi
fi

# --- Classificação do head ---------------------------------------------------

head_kind=""
head_type=""
if [[ "$HEAD_REF" =~ ^release/${SEMVER}$ ]]; then
    head_kind="release"
elif [[ "$HEAD_REF" =~ ^hotfix/${SEMVER}-[a-z0-9._-]+$ ]]; then
    head_kind="hotfix"
elif [[ "$HEAD_REF" == release/* || "$HEAD_REF" == hotfix/* ]]; then
    # Prefixo reservado com forma inválida: SemVer malformado ou slug ausente.
    _block "'$HEAD_REF' usa prefixo de release/hotfix com forma inválida (esperado release/vX.Y.Z ou hotfix/vX.Y.Z-<slug>)"
elif [[ "$HEAD_REF" == */* ]]; then
    head_type="${HEAD_REF%%/*}"
    _has "$GWC_BRANCH_TYPES" "$head_type" \
        || _block "tipo de branch desconhecido: '$head_type' (aceitos: $GWC_BRANCH_TYPES)"
    head_kind="work"
else
    _block "'$HEAD_REF' não segue <tipo>/<escopo>"
fi

# release/hotfix só existem no perfil que os define.
if [[ "$head_kind" == "release" || "$head_kind" == "hotfix" ]] && [[ "$GWC_SUPPORTS_RELEASE" != "1" ]]; then
    _block "perfil '$GWC_PROFILE' não define branches de $head_kind"
fi

# Forma do trabalho normal: Issue obrigatória apenas nos tipos de produto.
if [[ "$head_kind" == "work" ]]; then
    rest="${HEAD_REF#*/}"
    if _has "$GWC_REQUIRE_ISSUE_FOR" "$head_type"; then
        [[ "$rest" =~ ^[0-9]+-[a-z0-9._-]+$ ]] \
            || _block "'$head_type' exige número de Issue e slug: <tipo>/<issue>-<slug>"
    else
        [[ "$rest" =~ ^[a-z0-9._-]+$ ]] \
            || _block "escopo inválido em '$HEAD_REF' (esperado kebab-case)"
    fi
fi

# --- Classificação da base ---------------------------------------------------
# Integração é avaliada ANTES de produção: quando as duas coincidem (github-flow
# e legado), trabalho normal deve ser aceito.
base_kind=""
if [[ "$BASE_REF" == "$GWC_INTEGRATION_BRANCH" ]]; then
    base_kind="integration"
elif [[ "$BASE_REF" == "$GWC_PRODUCTION_BRANCH" ]]; then
    base_kind="production"
elif [[ "$BASE_REF" =~ ^release/${SEMVER}$ ]] && [[ "$GWC_SUPPORTS_RELEASE" == "1" ]]; then
    base_kind="release"
else
    _block "base não reconhecida: '$BASE_REF' (integração: '$GWC_INTEGRATION_BRANCH', produção: '$GWC_PRODUCTION_BRANCH')"
fi

# --- Veredito ----------------------------------------------------------------
case "$head_kind" in
    release)
        case "$base_kind" in
            production)  _accept "release '$HEAD_REF' promove para produção" ;;
            integration) _accept "backmerge de release para integração" ;;
            *)           _block  "release só mira produção ou faz backmerge para integração" ;;
        esac
        ;;
    hotfix)
        case "$base_kind" in
            production)  _accept "hotfix '$HEAD_REF' corrige produção" ;;
            integration) _accept "backmerge de hotfix para integração" ;;
            release)     _accept "backmerge de hotfix para release aberta" ;;
        esac
        ;;
    work)
        case "$base_kind" in
            integration)
                _accept "'$head_type' mira a branch de integração '$BASE_REF'" ;;
            release)
                _has "$GWC_RELEASE_ACCEPTS" "$head_type" \
                    && _accept "'$head_type' é estabilização aceita em release" \
                    || _block  "release aceita apenas estabilização ($GWC_RELEASE_ACCEPTS); '$head_type' expande escopo" ;;
            production)
                _block "trabalho normal nunca mira produção; use a branch de integração '$GWC_INTEGRATION_BRANCH'" ;;
        esac
        ;;
esac

_block "combinação não coberta: head='$HEAD_REF' base='$BASE_REF'"
