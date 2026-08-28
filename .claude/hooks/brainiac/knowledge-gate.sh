#!/usr/bin/env bash
# Brainiac Knowledge Consultation Gate (PreToolUse: Write|Edit)
#
# MOTOR GENÉRICO. Interpreta regras declarativas no context/knowledge/INDEX.md do
# projeto atual (bloco machine-readable entre os markers
# BRAINIAC:KNOWLEDGE-GATE-RULES-START/END, 1 regra JSON por linha). O hook NÃO
# conhece nenhum slug/anti-pattern específico — toda a policy é local do projeto.
# Sem INDEX, sem bloco, ou sem regra que case o path do edit → exit 0 (no-op).
#
# Schema de cada regra (1 objeto JSON por linha):
#   {"id":"<id>","mode":"block|advisory","path_regex":"^<rel-regex>$",
#    "knowledge_path":"context/knowledge/(patterns|anti-patterns)/<slug>.md",
#    "summary":"<risco 1 linha>","action":"<o que fazer antes do edit>"}
#
# Comportamento (fail-closed — policy quebrada NUNCA vira bypass silencioso):
#   - mode=block: exige evidência de consulta ao knowledge_path (Read OU @ref no
#     transcript, via is_loaded). Sem consulta → exit 2.
#   - mode=advisory: imprime aviso em stderr, exit 0.
#   - linha não-vazia entre markers que não seja objeto JSON → exit 2.
#   - knowledge_path fora de context/knowledge/{patterns,anti-patterns}/*.md, com
#     ../, ou ausente no disco = regra inválida: block→exit 2, advisory→aviso+exit 0.
#     (Defesa SEC: a "evidência = Read" não pode ser usada pra forçar leitura de
#      secret/arquivo arbitrário.)
#   - mode desconhecido em regra que casa → exit 2 (não dá pra classificar).
#
# Contrato (igual aos gates irmãos): block = texto em stderr + exit 2; allow = exit 0.
#
# pipefail intentionally OFF (set -u only): jq/grep retornam !=0 em no-match, que
# é fluxo de controle esperado aqui.

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/lib/hooks-common.sh" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/hooks-common.sh"
else
    echo "[Brainiac Knowledge Gate] FATAL: lib/hooks-common.sh missing — install via _install_hooks_only" >&2
    exit 2
fi

# Agent-packet binding: a bound Specialist whose packet declares the
# matching rule's knowledge_path in knowledge_refs is treated as having consulted it.
# Soft-source (absence => normal gate behaviour). workflow-binding first (resolve root).
[[ -f "$SCRIPT_DIR/lib/workflow-binding.sh" ]] && source "$SCRIPT_DIR/lib/workflow-binding.sh"
[[ -f "$SCRIPT_DIR/lib/agent-binding-plan.sh" ]] && source "$SCRIPT_DIR/lib/agent-binding-plan.sh"
[[ -f "$SCRIPT_DIR/lib/agent-binding.sh" ]] && source "$SCRIPT_DIR/lib/agent-binding.sh"

# i18n (optional; inline fallbacks guarantee operation if messages absent)
BRAINIAC_LANG="${BRAINIAC_LANG:-en}"
if [[ -f "$SCRIPT_DIR/messages/${BRAINIAC_LANG}.sh" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/messages/${BRAINIAC_LANG}.sh"
fi
: "${MSG_KNOWLEDGE_GATE_HEADER:=[Brainiac Knowledge Gate]}"
: "${MSG_KNOWLEDGE_GATE_BLOCKED:=Consult the required knowledge before this Write/Edit.}"
: "${MSG_KNOWLEDGE_GATE_UNLOCK:=Read (or @ref) the knowledge file above, apply its checklist, then retry the edit.}"
: "${MSG_KNOWLEDGE_GATE_BAD_JSON:=Invalid policy: non-empty line in BRAINIAC:KNOWLEDGE-GATE-RULES is not a JSON object. Fix context/knowledge/INDEX.md.}"
: "${MSG_KNOWLEDGE_GATE_INVALID_RULE:=Invalid rule: knowledge_path must point to context/knowledge/{patterns,anti-patterns}/*.md (no secrets, no traversal).}"
: "${MSG_KNOWLEDGE_GATE_MISSING_KNOWLEDGE:=Invalid rule: knowledge_path declared by the rule does not exist on disk.}"
: "${MSG_KNOWLEDGE_GATE_BAD_MODE:=Invalid rule: mode must be block or advisory.}"
: "${MSG_KNOWLEDGE_GATE_BAD_REGEX:=Invalid rule: path_regex is missing or not a valid regex. Fix context/knowledge/INDEX.md (fail-closed: an unevaluable matching predicate is not a silent bypass).}"
: "${MSG_KNOWLEDGE_GATE_BYPASS_NO_REASON:=Bypass requires BRAINIAC_KNOWLEDGE_GATE_BYPASS_REASON with at least 12 visible chars.}"
: "${MSG_KNOWLEDGE_GATE_SETTINGS_GUARD:=BRAINIAC_KNOWLEDGE_GATE_BYPASS must not live in versioned .claude/settings.json. Use .claude/settings.local.json (gitignored) or shell env.}"

# === 2. Scope guard por IDENTIDADE de repositório ===
# Antes usava contenção física (is_outside_project), o que tratava worktree
# linkada fora da raiz como cross-project e desligava o gate em silêncio.
# Identidade vence localização nos dois sentidos: worktree do mesmo repo pode
# viver fora, e repo aninhado/submódulo dentro da raiz é externo.
[[ -z "$file_path_norm" ]] && exit 0

kg_class="$(bc_classify_target "$file_path_norm" "$project_dir_norm")"
kg_state="${kg_class%%|*}"
target_root="${kg_class#*|}"

# external comprovado → cross-project, preserva o exit 0 histórico.
[[ "$kg_state" == "external" ]] && exit 0

# audit_root: onde a trilha de bypass é gravada. target_root quando conhecido;
# session_root no fallback local; /tmp quando indeterminado (§4 resolve).
audit_root="${target_root:-$project_dir_norm}"

# === 3. Settings-guard: bypass em settings.json versionada → fatal ===
settings_file="$project_dir_norm/.claude/settings.json"
if [[ -f "$settings_file" ]] \
   && grep -qE '"BRAINIAC_KNOWLEDGE_GATE_BYPASS"[[:space:]]*:[[:space:]]*"?true"?' "$settings_file" 2>/dev/null; then
    {
        echo "$MSG_KNOWLEDGE_GATE_HEADER"
        echo ""
        echo "FATAL: $MSG_KNOWLEDGE_GATE_SETTINGS_GUARD"
    } >&2
    exit 2
fi

# === 4. Bypass (env + reason >= 12 visible chars) ===
if [[ "${BRAINIAC_KNOWLEDGE_GATE_BYPASS:-false}" == "true" ]]; then
    reason_raw="${BRAINIAC_KNOWLEDGE_GATE_BYPASS_REASON:-}"
    reason_visible=$(printf '%s\n' "$reason_raw" | tr -d '[:space:]')
    if [[ ${#reason_visible} -lt 12 ]]; then
        {
            echo "$MSG_KNOWLEDGE_GATE_HEADER"
            echo ""
            echo "$MSG_KNOWLEDGE_GATE_BYPASS_NO_REASON"
        } >&2
        exit 2
    fi
    log_dir="$audit_root/context/evolution"
    log_file="$log_dir/knowledge-gate-bypasses.log"
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || log_file="/tmp/brainiac-knowledge-bypass-fallback.log"
    fi
    ts=$(date +'%Y-%m-%dT%H:%M:%S%z')
    sess_hash=$(compute_sha256 "$transcript_path")
    [[ -z "$sess_hash" ]] && sess_hash="unknown"
    reason_json=$(printf '%s\n' "$reason_raw" | sed 's/"/\\"/g')
    printf '{"ts":"%s","tool":"%s","file":"%s","reason":"%s","session_hash":"%s","user":"%s"}\n' \
        "$ts" "$tool_name" "$file_path" "$reason_json" "$sess_hash" "${USER:-unknown}" >> "$log_file"
    echo "[Brainiac Knowledge Gate] bypass logged ($log_file)" >&2
    exit 0
fi

# === 5. Load INDEX rules block ===
# policy_source_root: árvore que fornece INDEX, knowledge_path e evidência.
# Preferência pela árvore-alvo; fallback para a sessão SÓ com mesmo repositório
# comprovado (kg_state=resolved) — usar policy da sessão para outro repositório
# aplicaria a regra do repo A a um arquivo do repo B.
policy_source_root=""
if [[ -n "$target_root" && -f "$target_root/context/knowledge/INDEX.md" ]]; then
    policy_source_root="$target_root"
elif [[ "$kg_state" == "resolved" || "$kg_state" == "local-fallback" ]] \
     && [[ -f "$project_dir_norm/context/knowledge/INDEX.md" ]]; then
    policy_source_root="$project_dir_norm"
fi

if [[ -z "$policy_source_root" ]]; then
    # Sem policy determinável. Se há fronteira git mas a identidade não pôde ser
    # resolvida, não dá para PROVAR que a árvore-alvo não tem regra block →
    # fail-closed (indeterminate-policy-unknown). Caso contrário, allow.
    if [[ "$kg_state" == "indeterminate" ]]; then
        {
            echo "$MSG_KNOWLEDGE_GATE_HEADER"
            echo ""
            echo "Nao foi possivel determinar a raiz do repositorio do arquivo alvo."
            echo "Ha fronteira git, mas a identidade nao pode ser resolvida, entao nao e"
            echo "possivel provar que a arvore alvo nao declara regra 'block'."
            echo "Alvo: $file_path_norm"
        } >&2
        exit 2
    fi
    exit 0
fi

index_file="$policy_source_root/context/knowledge/INDEX.md"
[[ -f "$index_file" ]] || exit 0   # sem INDEX → sem policy → allow

rules=$(awk '
    /BRAINIAC:KNOWLEDGE-GATE-RULES-START/ { in_block=1; next }
    /BRAINIAC:KNOWLEDGE-GATE-RULES-END/   { in_block=0; next }
    in_block { print }
' "$index_file" 2>/dev/null)

[[ -z "$(printf '%s\n' "$rules" | tr -d '[:space:]')" ]] && exit 0   # bloco ausente/vazio → allow

# === 6. Caminho relativo, ancorado na TARGET_ROOT (não no cwd da sessão) ===
# Este é o ponto da Causa A: com a sessão na raiz e o arquivo no worktree, o
# strip pelo cwd produzia ".claude/worktrees/X/context/qa/x.md", que não casa
# uma regra ancorada em "^context/qa/". Normaliza-se antes de comparar porque
# --show-toplevel devolve "D:/..." e o cwd pode chegar como "/d/...".
kg_anchor="${target_root:-$project_dir_norm}"
_kg_fp_n=$(bc_normalize_path "$file_path_norm")
_kg_anchor_n=$(bc_normalize_path "$kg_anchor")
rel_path="$file_path_norm"
case "$_kg_fp_n" in
    "$_kg_anchor_n"/*) rel_path="${_kg_fp_n#"$_kg_anchor_n"/}" ;;
esac

# === 7. Avaliar regras ===
matched_block_rule=""
mb_rule_id=""; mb_knowledge_path=""; mb_summary=""; mb_action=""
advisory_msgs=()

# Pré-passe ÚNICO de jq: converte todas as regras em registros separados por US (0x1f).
# Antes, o loop gastava 7 chamadas de jq POR REGRA (1 de validação + 6 de campo). Cada
# spawn de processo no Git Bash/Windows custa ~0,3 s, então o custo era ~2 s por regra em
# TODO Write/Edit, casando ou não. Medido no MMO: 0 regras = 1,9 s, 14 regras = 30,9 s,
# 57 regras = 107,6 s por edit — atrito alto o bastante para o gate virar teatro (todo
# mundo desliga). Uma passada só torna o custo praticamente independente do nº de regras.
rules_parsed=$(printf '%s\n' "$rules" | jq -Rr '
    select(test("\\S"))
    | . as $raw
    | (try fromjson catch null) as $o
    | if ($o | type) != "object" then "\u0001BADJSON\u001f" + $raw
      else [($o.id // ""), ($o.mode // ""), ($o.path_regex // ""),
            ($o.knowledge_path // ""), ($o.summary // ""), ($o.action // "")] | join("\u001f")
      end
' 2>/dev/null)

# Bloco não-vazio que não produz nenhum registro = jq ausente/quebrado = policy
# inavaliável → fail-closed, nunca skip silencioso.
if [[ -z "$rules_parsed" ]]; then
    {
        echo "$MSG_KNOWLEDGE_GATE_HEADER"
        echo ""
        echo "$MSG_KNOWLEDGE_GATE_BAD_JSON"
        echo "Line: <bloco de regras não pôde ser parseado (jq indisponível ou entrada inválida)>"
    } >&2
    exit 2
fi

while IFS=$'\x1f' read -r rule_id mode path_regex knowledge_path summary action; do
    [[ -z "$rule_id$mode$path_regex$knowledge_path$summary$action" ]] && continue

    # Fail-closed: linha não-vazia que não é OBJETO JSON. O pré-passe marca com
    # \x01BADJSON no 1º campo e devolve a linha crua no 2º.
    if [[ "$rule_id" == $'\x01BADJSON' ]]; then
        {
            echo "$MSG_KNOWLEDGE_GATE_HEADER"
            echo ""
            echo "$MSG_KNOWLEDGE_GATE_BAD_JSON"
            echo "Line: $mode"
        } >&2
        exit 2
    fi

    # path_regex ausente/vazio = regra sem predicado de match = malformada → fail-closed.
    if [[ -z "$path_regex" ]]; then
        {
            echo "$MSG_KNOWLEDGE_GATE_HEADER"
            echo ""
            echo "$MSG_KNOWLEDGE_GATE_BAD_REGEX"
            echo "Rule: ${rule_id:-<no-id>} — path_regex ausente/vazio"
        } >&2
        exit 2
    fi
    # Distinguir no-match (rc=1) de regex INVÁLIDA (rc=2). Regex inválida = predicado
    # inavaliável = policy quebrada → fail-closed (exit 2), NUNCA skip silencioso.
    # `[[ =~ ]]` do bash usa ERE e devolve exatamente os mesmos códigos que `grep -qE`
    # (0 casa, 1 não casa, 2 regex inválida), sem custar um subprocesso por regra.
    { [[ $rel_path =~ $path_regex ]]; } 2>/dev/null
    grep_rc=$?
    if [[ "$grep_rc" -eq 2 ]]; then
        {
            echo "$MSG_KNOWLEDGE_GATE_HEADER"
            echo ""
            echo "$MSG_KNOWLEDGE_GATE_BAD_REGEX"
            echo "Rule: ${rule_id:-<no-id>} — path_regex='$path_regex' (regex inválida)"
        } >&2
        exit 2
    fi
    [[ "$grep_rc" -eq 0 ]] || continue

    # --- Regra casou. Validar mode. ---
    if [[ "$mode" != "block" && "$mode" != "advisory" ]]; then
        {
            echo "$MSG_KNOWLEDGE_GATE_HEADER"
            echo ""
            echo "$MSG_KNOWLEDGE_GATE_BAD_MODE"
            echo "Rule: ${rule_id:-<no-id>} — mode='$mode'"
        } >&2
        exit 2
    fi

    # --- Validar knowledge_path (allowlist + sem traversal). ---
    kp_valid=1
    case "$knowledge_path" in
        context/knowledge/patterns/*.md|context/knowledge/anti-patterns/*.md)
            [[ "$knowledge_path" == *".."* ]] && kp_valid=0 ;;
        *) kp_valid=0 ;;
    esac
    if [[ "$kp_valid" -eq 0 ]]; then
        if [[ "$mode" == "block" ]]; then
            {
                echo "$MSG_KNOWLEDGE_GATE_HEADER"
                echo ""
                echo "$MSG_KNOWLEDGE_GATE_INVALID_RULE"
                echo "Rule: ${rule_id:-<no-id>} — knowledge_path='$knowledge_path'"
            } >&2
            exit 2
        fi
        advisory_msgs+=("rule ${rule_id:-<no-id>}: knowledge_path inválido ('$knowledge_path') — regra ignorada")
        continue
    fi

    # --- knowledge_path deve existir no disco. ---
    kp_abs="$policy_source_root/$knowledge_path"
    if [[ ! -f "$kp_abs" ]]; then
        if [[ "$mode" == "block" ]]; then
            {
                echo "$MSG_KNOWLEDGE_GATE_HEADER"
                echo ""
                echo "$MSG_KNOWLEDGE_GATE_MISSING_KNOWLEDGE"
                echo "Rule: ${rule_id:-<no-id>} — knowledge_path='$knowledge_path'"
            } >&2
            exit 2
        fi
        advisory_msgs+=("rule ${rule_id:-<no-id>}: knowledge ausente ('$knowledge_path')")
        continue
    fi

    if [[ "$mode" == "advisory" ]]; then
        advisory_msgs+=("${rule_id:-<no-id>}: ${summary:-<risco>} → ${action:-consultar} (ref: $knowledge_path)")
        continue
    fi

    # --- mode=block: exigir evidência de consulta ao knowledge_path. ---
    # Evidência por IGUALDADE LITERAL do caminho ABSOLUTO normalizado, sempre.
    # Casar por sufixo relativo permitia o bypass inverso: ler o arquivo homônimo
    # em OUTRA árvore satisfazia a regra desta.
    if is_path_loaded_exact "$kp_abs" "$transcript_path"; then
        continue   # consultado (Read do arquivo certo) → regra satisfeita
    fi
    # @ref textual: relativo resolve contra a policy_source_root. Mantido como
    # canal secundário, escapando TODOS os metacaracteres (não só o ponto).
    kp_escaped=$(printf '%s' "$knowledge_path" | sed 's/[][\.*^$(){}?+|/\\]/\\&/g')
    kp_regex=$(printf '%s$' "$kp_escaped")
    if [[ "$policy_source_root" == "$project_dir_norm" ]] && is_loaded "$kp_regex" "$transcript_path"; then
        continue
    fi
    # Bound Specialist whose packet declares this knowledge_path in
    # knowledge_refs is treated as having consulted it (its fresh transcript has no Read).
    if declare -f agent_bound_knowledge_has >/dev/null 2>&1; then
        _kg_aid=$(printf '%s' "$input" | jq -r '.agent_id // ""')
        _kg_root=$(resolve_project_root "$project_dir_norm" 2>/dev/null || printf '%s' "$project_dir_norm")
        if agent_bound_knowledge_has "$_kg_aid" "$transcript_path" "$project_dir" "$_kg_root" "$file_path_norm" "$knowledge_path"; then
            continue
        fi
    fi
    # Guarda os campos já parseados: reparsear a linha com jq na seção 8 custaria mais
    # 4 subprocessos sem ganho algum.
    matched_block_rule="1"
    mb_rule_id="$rule_id"
    mb_knowledge_path="$knowledge_path"
    mb_summary="$summary"
    mb_action="$action"
    break          # bloqueia na primeira regra block não satisfeita
done <<< "$rules_parsed"

# === 8. Decidir ===
if [[ -n "$matched_block_rule" ]]; then
    rule_id="$mb_rule_id"
    knowledge_path="$mb_knowledge_path"
    summary="$mb_summary"
    action="$mb_action"
    {
        echo "$MSG_KNOWLEDGE_GATE_HEADER"
        echo ""
        echo "$MSG_KNOWLEDGE_GATE_BLOCKED"
        echo "Blocked $tool_name on: $rel_path"
        echo ""
        echo "Matched knowledge rule: ${rule_id:-<no-id>}"
        echo "Required knowledge: $knowledge_path"
        echo ""
        echo "Risk: ${summary:-<não declarado>}"
        echo "Action: ${action:-consultar o arquivo}"
        echo ""
        echo "$MSG_KNOWLEDGE_GATE_UNLOCK"
    } >&2
    exit 2
fi

# Advisory notes (não-bloqueantes)
if [[ ${#advisory_msgs[@]} -gt 0 ]]; then
    {
        echo "$MSG_KNOWLEDGE_GATE_HEADER (advisory)"
        for m in "${advisory_msgs[@]}"; do
            echo "  - $m"
        done
    } >&2
fi

exit 0
