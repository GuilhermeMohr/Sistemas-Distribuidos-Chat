#!/bin/bash
# Brainiac Context — Stop hook (Learn Gate enforcer)
# Blocks session stop when EITHER verdict fails:
#   (1) Learn: product edits happened, context/ was not updated, and no explicit
#       skip declaration was made; OR
#   (2) Worktree cleanup: the ACTIVE CYCLE's worktree became residue (branch
#       already absorbed into origin/<integration> AND clean tree) and neither a
#       removal nor an explicit worktree-skip declaration was made.
#
# The two checks are ORTHOGONAL and computed WITHOUT early exits: a permissive
# early return for one verdict must never short-circuit the other (anti-pattern
# permissive-early-exit-precedes-authoritative-confinement-verdict). We compute
# both, then decide once at the end.
#
# The worktree path is FAIL-OPEN by design: any failure (engine missing, git
# error, timeout, ambiguity) is silence (does not block). Blocking a stop
# wrongly traps the user; staying silent wrongly just leaves residue — which the
# read-only sweep measures and a later authorized batch removal collects.
#
# Exit 2 with stderr blocks the stop; stderr is shown to Claude.

set -euo pipefail

input=$(cat)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // ""')

# `stop_hook_active` = the Stop was already blocked once and Claude is trying to
# stop again. Read here, applied ONLY to the worktree verdict below (not to the
# Learn verdict on purpose): the worktree charge can hit a real dead end — when
# the transcript is absent, `recent_text` is empty and the "Explicit worktree
# skip" declaration can never be read, so Case A residue would otherwise block
# forever with no escape route. The Learn verdict never has that dead end (the
# agent can always update context/ or declare a skip), so it must keep blocking
# on successive Stops — extending this guard to Learn would weaken the framework's
# central gate (an agent could escape it by simply stopping twice).
stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')

# Derive project_dir for scope guard.
# Stop hook input does not always include `.cwd`; fall back to CLAUDE_PROJECT_DIR
# or pwd. Normalized (`\→/`) for cross-platform string-prefix compare.
project_dir=$(printf '%s' "$input" | jq -r '.cwd // empty')
[[ -z "$project_dir" ]] && project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
project_dir_norm=$(printf '%s\n' "$project_dir" | tr '\\' '/')

# Source shared helpers lib (is_outside_project, active_intent_path,
# bc_normalize_path) — fatal if missing, consistent with the other gates.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/hooks-common.sh" ]]; then
    # shellcheck source=lib/hooks-common.sh
    source "$SCRIPT_DIR/lib/hooks-common.sh"
else
    echo "[Brainiac Learn Gate] FATAL: lib/hooks-common.sh missing" >&2
    exit 2
fi

# A transcript ausente NÃO curto-circuita o hook. Só a extração de edits/skip do
# Learn depende dele; o veredito de worktree (Caso A, dentro da worktree) resolve
# a branch por `git rev-parse`, não pelo transcript. Sair aqui violaria o próprio
# invariante "sem early exit" e deixaria o resíduo do Caso A sem cobrança sempre
# que o transcript não resolvesse (campo ausente, path stale, race de rotação).
product_edits=""
recent_text=""
if [[ -f "$transcript_path" ]]; then
    # All Write/Edit target paths this session (normalized). Shared by both checks.
    product_edits=$(jq -r '
        select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use" and (.name == "Write" or .name == "Edit"))
        | .input.file_path // empty
    ' "$transcript_path" 2>/dev/null | tr '\\' '/' || true)

    # Recent assistant text (for both skip declarations). Guarded with `|| true`
    # so a jq/grep miss under `set -e` never aborts the hook.
    recent_text=$(jq -r '
        select(.type == "assistant")
        | .message.content[]?
        | select(.type == "text")
        | .text // empty
    ' "$transcript_path" 2>/dev/null | tail -c 5000 || true)
fi

# ===========================================================================
# Verdict 1 — Learn (context/ update).  Sets learn_block, no early exit.
# ===========================================================================
learn_block="no"

# Check 1: were there Write/Edit calls on product code?
# (edits within context/ are framework meta-editing, don't trigger by themselves)
had_product_edit="no"
while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    is_outside_project "$path" "$project_dir_norm" && continue
    if [[ "$path" != *"/context/"* ]]; then
        had_product_edit="yes"
        break
    fi
done <<< "$product_edits"

if [[ "$had_product_edit" == "yes" ]]; then
    # Check 2: was context/ updated this session?
    context_updated="no"
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        is_outside_project "$path" "$project_dir_norm" && continue
        if [[ "$path" == *"/context/evolution/"* ]] \
           || [[ "$path" == *"/context/intent/"* ]] \
           || [[ "$path" == *"/context/decisions/"* ]] \
           || [[ "$path" == *"/context/knowledge/"* ]] \
           || [[ "$path" == *"/context/agents/"* ]] \
           || [[ "$path" == *"/context/qa/"* ]]; then
            context_updated="yes"
            break
        fi
    done <<< "$product_edits"

    if [[ "$context_updated" == "no" ]]; then
        # Check 3: explicit Learn skip declaration?
        skip_learn="no"
        if printf '%s' "$recent_text" \
           | grep -qiE '(explicit skip declaration|no limbo|sem update de context|skip declarado|read-only session|sessão read-only)'; then
            skip_learn="yes"
        fi
        [[ "$skip_learn" == "no" ]] && learn_block="yes"
    fi
fi

# ===========================================================================
# Verdict 2 — Worktree cleanup (residue of the ACTIVE CYCLE).  Fail-open.
# Sets wt_block + wt_msg.  Every risky command guards to `return 0` (= no block).
# ===========================================================================
wt_block="no"
wt_advisory=""   # maybe-absorbed: mensagem non-blocking entregue via systemMessage (exit 0)
wt_msg=""

compute_wt_verdict() {
    # Already blocked once (stop_hook_active): do not charge the worktree again —
    # the first Stop delivered the message; a second block would loop with no
    # escape when the transcript is absent (skip declaration unreadable). Scoped
    # to the worktree verdict only (the Learn verdict keeps blocking, above).
    [[ "$stop_hook_active" == "true" ]] && return 0

    # Resolve the main checkout (first porcelain entry). git run from any worktree
    # lists them all; failure → fail-open.
    local main_root
    # `project_dir` vem do runtime e pode conter metacaracteres válidos em paths
    # (`;`, por exemplo). No Git Bash/Windows, passá-lo a `git.exe -C` atravessa
    # a conversão automática MSYS de argumentos e `;` pode ser tratado como
    # separador de path-list. O `cd` builtin recebe o valor literalmente e evita
    # esse boundary antes de chamar o binário nativo.
    main_root="$(cd "$project_dir" 2>/dev/null \
                 && git worktree list --porcelain 2>/dev/null \
                 | awk '/^worktree /{print substr($0,10); exit}')" || return 0
    [[ -n "$main_root" ]] || return 0

    # Resolve the Git layer engine from the main checkout (adopter or canonical
    # layout). Absent → fail-open (adopters without the Git layer get no charge).
    local engine="" cand
    for cand in "$main_root/.brainiac/git/scripts/worktree-lifecycle.sh" \
                "$main_root/integrations/git/scripts/worktree-lifecycle.sh"; do
        [[ -f "$cand" ]] && { engine="$cand"; break; }
    done
    [[ -n "$engine" ]] || return 0

    # Case A vs B by repository IDENTITY, never by string-comparing paths: on
    # Windows the cwd may arrive MSYS-form (/tmp/...) while git returns native
    # form (C:/.../Temp/...), and bc_normalize_path cannot resolve arbitrary
    # mounts like /tmp. In the MAIN checkout git-dir == git-common-dir; in a
    # linked worktree they differ (the same repository-identity technique the
    # knowledge-gate uses to scope edits to the right repo).
    local gd gcd case_a="no"
    gd="$(cd "$project_dir" 2>/dev/null && git rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 0
    gcd="$(cd "$project_dir" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
    [[ -n "$gd" && -n "$gcd" ]] || return 0
    [[ "$gd" != "$gcd" ]] && case_a="yes"

    # Resolve the cycle branch. Always by branch name (robust to path form).
    local cyc_branch=""
    if [[ "$case_a" == "yes" ]]; then
        # Session INSIDE a worktree → the cycle branch is the current one.
        cyc_branch="$(cd "$project_dir" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 0
        [[ -n "$cyc_branch" && "$cyc_branch" != "HEAD" ]] || return 0
    else
        # Session in the MAIN checkout → bind cycle→worktree by the active intent
        # slug. Only that worktree is in scope; never the backlog.
        local intent slug
        intent="$(active_intent_path "$transcript_path" 2>/dev/null || true)"
        [[ -n "$intent" ]] || return 0
        slug="$(basename "$intent" .md 2>/dev/null | sed -E 's/^(feature|bug|refactor)-//' || true)"
        [[ -n "$slug" ]] || return 0
        # Escape regex metacharacters: an intent like `feature-api-v1.2.md` would
        # otherwise inject `.` into the pattern (widening the match). The slug is
        # usually [A-Za-z0-9_-], but do not trust the convention — escape.
        local slug_re
        slug_re="$(printf '%s' "$slug" | sed 's/[.[\*^$()+?{|]/\\&/g')"
        # Match the slug ANCHORED to the END of the branch, after a `/` or `-`
        # separator — the branch convention is `type/[NNN-]slug`, so the slug is
        # the tail. An UNANCHORED substring (`grep -F "$slug"`) would bind the
        # wrong worktree when slugs collide as substrings (slug `auth` matching
        # `feat/322-oauth-sso`) — a real hazard under parallel orchestration.
        # AMBIGUITY is fail-open: if more than one branch matches (two cycles with
        # the same slug), we cannot tell which is this cycle's, and charging the
        # wrong one is worse than not charging — so we bail rather than head -1.
        local matches match_count
        matches="$(git -C "$main_root" worktree list --porcelain 2>/dev/null \
                   | awk '/^branch /{b=substr($0,8); sub("refs/heads/","",b); print b}' \
                   | grep -E "(^|/|-)${slug_re}$" || true)"
        match_count="$(printf '%s' "$matches" | grep -c . || true)"
        [[ "$match_count" == "1" ]] || return 0
        cyc_branch="$matches"
    fi

    # The engine resolves the worktree via `git` relative to ITS cwd, so it must
    # run inside the repo — the hook's own cwd is arbitrary (the runtime does not
    # cd into the project). Without this the engine would inspect the wrong repo.
    # timeout 7 (not 5): cycle-status --branch measures ~1-2s, but each `git -C`
    # is a fork and forks are slow on Windows/MSYS under load (AV, network disk);
    # 7s keeps margin without risking the Stop hook's ~10s budget. On timeout the
    # verdict is silently dropped (fail-open by design), never a spurious block.
    local out verdict head
    out="$( cd "$main_root" 2>/dev/null && timeout 7 bash "$engine" cycle-status --branch "$cyc_branch" 2>/dev/null || true )"
    verdict="$(printf '%s' "$out" | tr ' ' '\n' | sed -n 's/^verdict=//p' | head -1 || true)"
    # residue (absorção confirmada por ancestralidade) OU maybe-absorbed (árvore
    # limpa, não-ancestral, squash/rebase provável — cobra CONFIRMAÇÃO, não afirma
    # que entrou). Ambos cobram; a mensagem abaixo distingue.
    [[ "$verdict" == "residue" || "$verdict" == "maybe-absorbed" ]] || return 0

    # residue/maybe → block/advise, unless an explicit worktree-skip was declared.
    if printf '%s' "$recent_text" \
       | grep -qiE '(explicit worktree skip|worktree skip declaration|skip de worktree|resíduo de worktree|manter a worktree residual)'; then
        return 0
    fi

    head="$(printf '%s' "$out" | tr ' ' '\n' | sed -n 's/^head=//p' | head -1 || true)"
    # residue/maybe sempre carrega head pelo contrato. Se um engine parcial ou
    # adulterado omitir a âncora, não inventa uma substituição executável dentro
    # da mensagem: silencia a cobrança/advisory e fecha para o lado seguro.
    [[ -n "$head" ]] || return 0

    # Toda linha abaixo é oferecida ao humano para copy/paste. Branch é dado do
    # repositório e Git aceita metacaracteres de shell em refs (`;`, `$()`, crase).
    # `%q` (Bash 4+) transforma cada valor dinâmico em exatamente UM argumento;
    # sem isso, uma branch maliciosa converteria orientação textual em command
    # injection quando colada. Paths também são cotados para portabilidade POSIX.
    local engine_q main_root_q branch_q head_q
    printf -v engine_q '%q' "$engine"
    printf -v main_root_q '%q' "$main_root"
    printf -v branch_q '%q' "$cyc_branch"
    printf -v head_q '%q' "$head"

    # maybe-absorbed é ADVISORY — NÃO bloqueia. O sinal (não-ancestral + integração
    # avançou) é conservador e dispara com frequência para branches de vida longa
    # num repo ativo, onde a integração avança por OUTRAS branches (não a sua):
    # bloquear o Stop repetidamente viraria ritual esvaziado / fadiga de alerta.
    # Avisa e libera; só residue (absorção CONFIRMADA por ancestralidade) bloqueia.
    # A branch nunca é removida em nenhum caso.
    if [[ "$verdict" == "maybe-absorbed" ]]; then
        # advisory NÃO-bloqueante: entregue via systemMessage (JSON stdout, exit 0)
        # no fim do script — o mesmo canal de qa-gate/post-compact. stderr em exit 0
        # é DESCARTADO por hooks Stop (não chega a ninguém), então não serve aqui.
        # DELIBERADO usar systemMessage (visível ao HUMANO na UI) em vez de
        # hookSpecificOutput.additionalContext (que o Claude processa como contexto):
        # quem CONFIRMA a squash e autoriza o cleanup deve ser o humano, não o agente
        # — que, lendo "se confirmado, rode cleanup --apply", poderia auto-executar
        # uma remoção sem confirmação humana genuína. A mensagem fala em 2ª pessoa.
        wt_advisory="[Brainiac Learn Gate — worktree POSSIVELMENTE absorvida (advisory)]

A worktree deste ciclo tem árvore limpa e NÃO é ancestral da integração, mas a
integração avançou — a branch $cyc_branch PODE ter sido squash/rebase-mergeada
(a integração também pode ter avançado por outras branches; não é decidível por
ancestralidade). Isto NÃO afirma que entrou, e NÃO bloqueia o Stop.

Se você CONFIRMA que a branch foi mergeada, remova pelo checkout principal:
  bash $engine_q cycle-status --branch $branch_q
  bash $engine_q cleanup --apply --branch $branch_q --expect-branch $branch_q --expect-head $head_q
Se é trabalho vivo (WIP), ignore este aviso."
        return 0
    fi

    if [[ "$case_a" == "yes" ]]; then
        wt_msg="$(cat <<EOF
[Brainiac Learn Gate — worktree cleanup]

Você está DENTRO da worktree deste ciclo, que virou resíduo (absorvida + limpa):
  branch: $cyc_branch

O git recusa remover a worktree corrente. Vá ao checkout principal e rode:
  cd $main_root_q
  bash $engine_q cleanup --check  --branch $branch_q
  bash $engine_q cleanup --apply  --branch $branch_q \\
      --expect-branch $branch_q --expect-head $head_q

Ou declare, se escolher deixá-la:
  "Explicit worktree skip: <razão específica>."
EOF
)"
    else
        wt_msg="$(cat <<EOF
[Brainiac Learn Gate — worktree cleanup]

A worktree deste ciclo virou resíduo (branch já absorvida em origin + árvore limpa):
  branch: $cyc_branch

Remova-a a partir deste checkout principal:
  bash $engine_q cycle-status --branch $branch_q
  bash $engine_q cleanup --apply --branch $branch_q \\
      --expect-branch $branch_q --expect-head $head_q

Ou declare, se escolher deixá-la:
  "Explicit worktree skip: <razão específica>."
EOF
)"
    fi
    wt_block="yes"
    return 0
}

compute_wt_verdict || true

# ===========================================================================
# Combined decision — either verdict blocks; no early exit reached this point.
# ===========================================================================
if [[ "$learn_block" == "no" && "$wt_block" == "no" ]]; then
    # maybe-absorbed advisory (não-bloqueante): systemMessage via JSON stdout — o
    # canal que hooks Stop entregam ao agente (stderr em exit 0 é descartado).
    if [[ -n "$wt_advisory" ]] && command -v jq >/dev/null 2>&1; then
        printf '%s' "$wt_advisory" | jq -Rs '{ systemMessage: . }'
    fi
    exit 0
fi

if [[ "$learn_block" == "yes" ]]; then
    cat >&2 <<'EOF'
[Brainiac Learn Gate — Stop block]

A sessão teve edits em código de produto, mas context/ não foi atualizado
e não houve explicit skip declaration. A task não está completa pelo framework.

Antes de encerrar, escolha UM:

1. **Atualize context/** com o que foi feito:
   - bugfix simples → entrada em context/evolution/buglog.md
   - bug L2/arquitetural → atualize bug-*.md + possivelmente ADR
   - feature completa → atualize Status e Updated no feature-*.md
   - decisão arquitetural → crie ou atualize context/decisions/NNN-*.md
   - aprendizado reutilizável → crie context/knowledge/patterns/<slug>.md
   - aprendizado a evitar → crie context/knowledge/anti-patterns/<slug>.md
   - marco/release/incidente → entrada em context/evolution/changelog.md

2. **Declare explicit skip** (se genuinamente não há nada a atualizar):
   Diga claramente em resposta ao usuário:
   "Explicit skip declaration: [razão específica, não genérica]."

   Exemplos válidos:
   - "Explicit skip declaration: sessão foi read-only (investigação), código não foi alterado."
   - "Explicit skip declaration: edição emergencial de typo em comment, sem valor de knowledge."

Framework spec: context/.brainiac-context-framework.md (Step 3 Learn, Learn Gate, No Limbo Rule).
EOF
fi

if [[ "$wt_block" == "yes" ]]; then
    printf '%s\n' "$wt_msg" >&2
fi

exit 2
