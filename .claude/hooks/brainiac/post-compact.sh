#!/bin/bash
# Brainiac Context — PostCompact hook
# Fires AFTER /compact (manual or auto) completes.
#
# Critical: plain stdout from PostCompact goes to debug log only, NOT to Claude.
# To inject a reload checklist that Claude sees, we MUST emit JSON output with
# top-level "systemMessage" — Claude Code's hook schema only accepts
# hookSpecificOutput.hookEventName in
# {PreToolUse,UserPromptSubmit,PostToolUse,PostToolBatch}, so PostCompact must
# use systemMessage (universal field) to reach the agent's context.
#
# Iron Law 7 — Context Hygiene Between Cycles:
#   - Framework spec is always-on via @import chain (CLAUDE.md → AGENTS.md → framework spec).
#   - The chain is re-injected automatically after compact.
#   - For critical work (Build, Learn, framework update, migration, refactor,
#     complex bugfix), the agent must reload active intent + relevant ADRs from disk.
#
# i18n: messages loaded from messages/${BRAINIAC_LANG}.sh (default: en).
#
# Exit 0 (advisory only — compact already happened, cannot be blocked).

set -euo pipefail

# --- i18n ---
BRAINIAC_LANG="${BRAINIAC_LANG:-en}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MSG_FILE="$SCRIPT_DIR/messages/${BRAINIAC_LANG}.sh"
[[ -f "$MSG_FILE" ]] && source "$MSG_FILE" || source "$SCRIPT_DIR/messages/en.sh"

# --- Parse stdin (best effort) ---
TRIGGER="unknown"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
if command -v jq >/dev/null 2>&1; then
    INPUT=$(cat)
    TRIGGER=$(printf '%s' "$INPUT" | jq -r '.compaction_trigger // "unknown"' 2>/dev/null || echo "unknown")
    _cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
    [[ -n "$_cwd" ]] && PROJECT_DIR="$_cwd"
fi

# --- Build advisory message (i18n) ---
ADVISORY="${MSG_POST_COMPACT_HEADER:-=== Brainiac post-compact reload (Iron Law 7) ===}
${MSG_POST_COMPACT_LINE_TRIGGER:-Compact concluído}: ${TRIGGER}.

${MSG_POST_COMPACT_LINE_FRAMEWORK:-Framework spec foi re-injetado via @AGENTS.md → @context/.brainiac-context-framework.md (import chain).}

${MSG_POST_COMPACT_LINE_CRITICAL:-Antes de trabalho crítico (Build / Learn / update / migração / refactor / bugfix complexo):}
1. ${MSG_POST_COMPACT_STEP1:-Confirme acesso a Iron Laws 1-7 (framework spec carregado).}
2. ${MSG_POST_COMPACT_STEP2:-Releia intent ativo (feature-*.md / bug-*.md / refactor-*.md).}
3. ${MSG_POST_COMPACT_STEP3:-Releia ADRs referenciados na seção Related do intent.}
4. ${MSG_POST_COMPACT_STEP4:-Verifique .brainiac/last-compact-state.json para handoff.}
5. ${MSG_POST_COMPACT_STEP5:-Rode /context — se ≥60%, continuar trabalho crítico sem novo /compact (continuação) ou /clear (troca real de escopo) é Brainiac violation (Iron Law 7.5). Os dois não são intercambiáveis: use /compact quando continuando o mesmo workflow; /clear apenas entre ciclos distintos.}

${MSG_POST_COMPACT_FOOTER:-Se tarefa simples em continuação, summary é suficiente.}"

# --- Append Knowledge INDEX ---
# /compact descarta o contexto carregado, então o catálogo leve de
# patterns + anti-patterns é re-injetado aqui também (Iron Law 7). Conteúdo
# completo de cada artefato permanece on-demand via Read. Condicional: ausente → não anexa.
KNOWLEDGE_INDEX="$PROJECT_DIR/context/knowledge/INDEX.md"
if [[ -f "$KNOWLEDGE_INDEX" ]]; then
    ADVISORY="${ADVISORY}

--- Knowledge INDEX (context/knowledge/INDEX.md, reloaded post-compact) ---

$(cat "$KNOWLEDGE_INDEX")"
fi

# --- Emit JSON output (REQUIRED for PostCompact — plain stdout does not reach Claude) ---
# Build JSON safely: use jq if available, fallback to manual escape for portability.
if command -v jq >/dev/null 2>&1; then
    # Payload via stdin (jq -Rs), NÃO via --arg: $ADVISORY carrega o Knowledge
    # INDEX inteiro (~33KB) e passá-lo na linha de comando estoura o limite de
    # argv do CreateProcess no Windows (~32KB) → "Argument list too long" (E2BIG).
    # -R = raw input (não parseia como JSON); -s = slurp (lê todo o stdin como
    # uma string). printf '%s' não adiciona newline final, então -s captura
    # exatamente $ADVISORY. stdin não tem limite de argv.
    printf '%s' "$ADVISORY" | jq -Rs '{ systemMessage: . }'
else
    # Fallback: escape newlines + quotes manually. Less robust but functional.
    ESCAPED=$(printf '%s' "$ADVISORY" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')
    cat <<EOF
{
  "systemMessage": "$ESCAPED"
}
EOF
fi

exit 0
