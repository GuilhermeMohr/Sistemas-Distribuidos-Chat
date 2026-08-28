#!/bin/bash
# Brainiac Context — UserPromptSubmit hook
# Detects trigger patterns in the user prompt and reminds Claude of the
# corresponding framework step.
#
# Exit 0 + stdout (plain text) is added to Claude's context for this prompt.

set -euo pipefail

input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null || echo "")
project_dir=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || echo "")
[[ -z "$project_dir" ]] && project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Normalize: lowercase + strip leading whitespace
prompt_lc=$(printf '%s\n' "$prompt" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//')

# _has_approved_anchor <project_dir> — DETERMINISTIC detection of an approved goal/MOR
# anchor: any context/orchestration/*-envelope.md carrying ENVELOPE_APPROVAL
# approved=true. Its presence means the human already approved → the orchestration offers
# point at the AUTONOMOUS orchestrate-run, not at "never auto-run / copy-paste".
_has_approved_anchor() {
    local dir="$1" f
    [[ -d "$dir/context/orchestration" ]] || return 1
    for f in "$dir"/context/orchestration/*-envelope.md; do
        [[ -f "$f" ]] || continue
        if grep -qE 'BRAINIAC:ENVELOPE_APPROVAL[^>]*approved=true' "$f" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}
has_anchor=0
if _has_approved_anchor "$project_dir"; then has_anchor=1; fi

trigger=""

# Build triggers
if printf '%s\n' "$prompt_lc" | grep -qE '^(implementa|adiciona|cria|constr[óo]i|faz|build|monta)'; then
    trigger="[Brainiac trigger: BUILD detected]
- Carregue feature-*.md relevante em context/intent/. Se não existe, crie Intent antes (Step 1).
- Verifique ADRs relacionadas (seção Related do feature file).
- Siga Plan → Approve → Execute — não edite código sem aprovação do Plan.
- sensors.md deve passar antes de declarar done."

# Bugfix triggers
elif printf '%s\n' "$prompt_lc" | grep -qE '^(corrige|fixa|resolve|bugfix|conserta|arruma|da erro)'; then
    trigger="[Brainiac trigger: BUGFIX detected]
- Triage L1/L2/L3 antes de qualquer arquivo.
- L1 (default): só entrada em context/evolution/buglog.md após o fix.
- L2 (condicional): crie context/intent/bug-<slug>.md se bate 1+ dos 7 critérios
  (root cause não-óbvia, toca arquitetura, alto risco regressão, impacto
  significativo, teste específico, cross-layer, gera pattern).
- L3 (raro): entrada em changelog.md apenas para incidentes majors."

# Update feature triggers
elif printf '%s\n' "$prompt_lc" | grep -qE '^(atualiza|muda|ajusta|update|modifica|troca)'; then
    trigger="[Brainiac trigger: UPDATE FEATURE detected]
- Carregue feature-*.md original. Não crie novo arquivo a menos que seja
  substituição total, feature nova, ou split.
- Modificações incrementais; preserve o que não precisa mudar.
- Atualize Status e Updated no feature file."

# Refactor triggers
elif printf '%s\n' "$prompt_lc" | grep -qE '^(refatora|refactor|reorganiza)'; then
    trigger="[Brainiac trigger: REFACTOR detected]
- Crie context/intent/refactor-<slug>.md se não existe.
- Refactor ≠ mudança de comportamento. Se o comportamento muda, é Update Feature ou nova feature.
- Documente a motivação (performance, legibilidade, dívida técnica)."

# Read-only / investigação triggers
elif printf '%s\n' "$prompt_lc" | grep -qE '^(explora|investiga|analisa|analyze|como funciona|o que faz|me explica|mostra|n[óo]s usamos|nos usamos|usamos|podemos remover)'; then
    trigger="[Brainiac trigger: READ-ONLY detected]
- Não atualize context/ por default — isso é exploração/leitura, não Build.
- Se a pergunta toca infra/arquitetura/integração/decisão, leia context/intent/, context/decisions/ ou context/agents/project/ ANTES de Bash/Read/Grep no código.
- Ao fechar, declare explicitamente: 'sessão read-only, sem context update necessário'."

# Decision / ADR triggers
elif printf '%s\n' "$prompt_lc" | grep -qE '(decid|escolh|chose|choos|vamos usar|vou usar)'; then
    trigger="[Brainiac trigger: DECISION detected]
- Crie context/decisions/<NNN>-<slug>.md com rationale, alternativas consideradas, outcome esperado.
- Se é cross-cutting, referencie a partir do project-intent.md ou do feature file."
fi

if [[ -n "$trigger" ]]; then
    echo "$trigger"
fi

# --- Codex cross-review offer (auto-offer, AskUser-first) ---
# Reminder to OFFER (never auto-run) the cross-agent Codex review when the prompt involves a
# non-trivial reviewable artifact (plan/ADR/PR/diff/review). The keyword guard avoids noise on
# trivial questions ("explain X"). The skill is auto-offerable but AskUser-first: it only runs
# after explicit consent. Covers the plan case (which otherwise lands in the READ-ONLY trigger).
codex_offer=""
if printf '%s\n' "$prompt_lc" | grep -qE '(\bplano|\bplan\b|\bplanning|revis|\breview|\bdiff\b|\badr\b|\bpr\b|pull request)'; then
    codex_offer="[Brainiac: Codex cross-review available]
- Non-trivial work on a plan/ADR/PR/diff? OFFER the cross-agent Codex review via AskUser
  (skill brainiac-context-review-codex) before proceeding — for a plan it can run in parallel
  while the dev reads it.
- Auto-offer, never auto-run: ask first; only dispatch the Codex after explicit consent."
fi
if [[ -n "$codex_offer" ]]; then
    [[ -n "$trigger" ]] && echo ""
    echo "$codex_offer"
fi

# --- Orchestration ladder offers (auto-offer, AskUser-first) ---
# Auto-offer means "suggest and ask", never auto-run. Stage-specific offers
# are suppressed for explanatory/read-only prompts to avoid operational noise.
is_explain_prompt=0
if printf '%s\n' "$prompt_lc" | grep -qE '^(me explica|explica|explique|como funciona|o que [ée]|what is|explain)'; then
    is_explain_prompt=1
fi

orch_status_offer=""
orch_dispatch_offer=""
orch_integrate_offer=""
if [[ "$is_explain_prompt" -eq 0 ]]; then
    if printf '%s\n' "$prompt_lc" | grep -qE '(orchestrate-status|((status|progresso|andamento|onde est[áa]).*(orquestr|orchestr|run|packet|packets|work packet))|((orquestr|orchestr|run|packet|packets|work packet).*(status|progresso|andamento|onde est[áa])))'; then
        orch_status_offer="[Brainiac: orchestration status available]
- Existing orchestration run/progress signal detected. OFFER read-only status via AskUser
  (skill brainiac-context-orchestrate-status).
- Auto-offer, never auto-run: ask first; status remains zero-write/read-only."
    fi

    if printf '%s\n' "$prompt_lc" | grep -qE '(aprovad[oa]|pode disparar|pode rodar|executa(r)?|roda(r)? (a )?(orquestr|run|plano)|dispara|ger(ar|e).*(prompt|prompts)|dispatch|orchestrate-(dispatch|run)|colar.*prompts?)'; then
        if [[ "$has_anchor" -eq 1 ]]; then
            # DETERMINISTIC: an approved goal/MOR anchor exists → autonomous runtime.
            orch_dispatch_offer="[Brainiac: orchestration run available — approved anchor detected]
- An approved goal/MOR anchor (context/orchestration/*-envelope.md approved=true) is present.
  Post-approval you have authority to EXECUTE autonomously via brainiac-context-orchestrate-run —
  no new per-step AskUser gate.
- Real validation still blocks: contract invalid / hash drift / anchor absent / stop_conditions /
  run-wide lock contention / budget exceeded / bound write outside allowed_paths. Ask only for
  human-gated axes, a real runtime conflict, or destructive/deploy/secret outside the envelope."
        else
            # No approved anchor yet: the manual pre-anchor path stays AskUser-first/never-auto-run.
            orch_dispatch_offer="[Brainiac: orchestration dispatch available]
- Approved-plan / generate-prompts signal detected (no approved anchor yet). OFFER dispatch via AskUser
  (skill brainiac-context-orchestrate-dispatch).
- Auto-offer, never auto-run: ask before validation, envelope generation, prompt generation, or runtime-state writes.
- Still manual-plugin pre-anchor: human dispatch remains copy-paste. Once an approved envelope exists,
  brainiac-context-orchestrate-run executes it autonomously."
        fi
    fi

    if printf '%s\n' "$prompt_lc" | grep -qE '(tudo revisad[oa]|todos?.*revisad|fechar.*run|integr(ar|e).*run|integration_ready|orchestrate-integrate|pront[oa].*integr)'; then
        orch_integrate_offer="[Brainiac: orchestration integration available]
- Completed/reviewed/close-run signal detected. OFFER integration closeout via AskUser
  (skill brainiac-context-orchestrate-integrate).
- Auto-offer, never auto-run: ask before writing integration-report.md or runtime state.
- Human merge only: never merge; then hand off to Learn Gate."
    fi
fi

printed_orch_stage=0
for _orch_stage_offer in "$orch_status_offer" "$orch_dispatch_offer" "$orch_integrate_offer"; do
    if [[ -n "$_orch_stage_offer" ]]; then
        [[ -n "$trigger" || -n "$codex_offer" || "$printed_orch_stage" -eq 1 ]] && echo ""
        echo "$_orch_stage_offer"
        printed_orch_stage=1
    fi
done

# --- Orchestration planning offer (auto-offer, AskUser-first) ---
# Reminder only: offer planning, never dispatch. The skill itself enforces
# AskUser-first and zero-dispatch behavior. Suppress planning when a later
# orchestration stage matched; otherwise the hook would tell an approved run to
# plan again instead of offering status/dispatch/integrate.
orch_offer=""
if [[ "$is_explain_prompt" -eq 0 && -z "$orch_status_offer$orch_dispatch_offer$orch_integrate_offer" ]] \
   && printf '%s\n' "$prompt_lc" | grep -qE '(orquestr|orchestr|subagent|sub-agent|multi-agent|worktree|paralel|parallel|work packet|packets|m[úu]ltipl[oa]s m[óo]dulos|contrac?t matrix|matriz de contrato)'; then
    orch_offer="[Brainiac: orchestration planning available]
- Non-trivial multi-agent/parallel/worktree scope detected. OFFER orchestration planning via AskUser
  (skill brainiac-context-orchestrate-plan) before Build.
- Auto-offer, never auto-run: only prepare a Contract Matrix after explicit consent.
- Dispatch/status/integrate are stage-aware offers and still require their own AskUser-first gates."
fi
if [[ -n "$orch_offer" ]]; then
    [[ -n "$trigger" || -n "$codex_offer" || "$printed_orch_stage" -eq 1 ]] && echo ""
    echo "$orch_offer"
fi

# --- Scope-switch detection (Iron Law 7.4 — soft, non-blocking) ---
scope_switch=""
if printf '%s\n' "$prompt_lc" | grep -qE '^(agora vamos|pr[óo]xim[ao] tarefa|nova feature|outro bug|mudando de assunto|vamos come[çc]ar)' \
   || printf '%s\n' "$prompt" | grep -qE '^/brainiac-context-(feature|bugfix|update|learn|build)'; then
    scope_switch="[Brainiac context-hygiene]
Scope switch detectado. Iron Law 7.4: never start a new scope at or above 40%.

Ações:
- Rode /context pra ver uso atual.
- Se ≥40%, /clear é obrigatório antes de prosseguir (não use /compact pra scope switch).
- /compact só preserva mesma tarefa; perde history detalhada.
- Após /clear, framework spec é re-injetado via @import chain (CLAUDE.md → @AGENTS.md → @context/.brainiac-context-framework.md)."
fi

if [[ -n "$scope_switch" ]]; then
    [[ -n "$trigger" ]] && echo ""
    echo "$scope_switch"
fi

exit 0
