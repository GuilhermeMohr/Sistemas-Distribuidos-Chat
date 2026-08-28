#!/bin/bash
# Brainiac Context — PreToolUse hook for Write|Edit
# Blocks edits to framework canonicals under context/agents/brainiac/.
#
# This is layer 2 of canonical defense in depth.
#   Layer 1 = git pre-commit (integrations/git-hooks/brainiac-canonical-protection.sh)
#   Layer 2 = this hook (Claude Code tool boundary)
#   Layer 3 = agent-reviewer.md Phase 1 [BRAINIAC-CANONICAL] finding
#
# Canonicals evolve only via /brainiac-context-update. Project customizations go
# in context/agents/project/ via /brainiac-context-agent.
#
# Bypass mechanisms (in order of preference):
#   1. Refactor as Project Extension under context/agents/project/
#   2. Run /brainiac-context-update (official path for canonical evolution)
#   3. Add inline comment <!-- brainiac-canonical-edit: <reason> --> in the
#      Edit/Write content (justified bypass; recorded in code, audited later
#      by reviewer)
#
# Exit 2 with stderr blocks the tool call; stderr is shown to Claude.

set -euo pipefail

# --- i18n ---
BRAINIAC_LANG="${BRAINIAC_LANG:-en}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MSG_FILE="$SCRIPT_DIR/messages/${BRAINIAC_LANG}.sh"
[[ -f "$MSG_FILE" ]] || MSG_FILE="$SCRIPT_DIR/messages/en.sh"
[[ -f "$MSG_FILE" ]] && source "$MSG_FILE"

: "${MSG_CANONICAL_HEADER:=[Brainiac Canonical Gate]}"
: "${MSG_CANONICAL_BLOCKED:=Edit blocked: target is a framework canonical under context/agents/brainiac/.}"
: "${MSG_CANONICAL_HINT_1:=Preferred: refactor the change as a Project Extension under context/agents/project/ via /brainiac-context-agent.}"
: "${MSG_CANONICAL_HINT_2:=Official path: run /brainiac-context-update to evolve canonicals.}"
: "${MSG_CANONICAL_HINT_3:=Justified bypass: include the marker brainiac-canonical-edit reason=\"...\" inside the Edit/Write payload so the reviewer can audit later.}"

# --- Parse input ---
input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')

[[ -z "$file_path" ]] && exit 0
[[ "$tool_name" != "Write" && "$tool_name" != "Edit" ]] && exit 0

# Normalize path for cross-platform matching
file_path_norm=$(printf '%s\n' "$file_path" | tr '\\' '/')

# --- Detect canonical path ---
# Match context/agents/brainiac/<anything>.md anywhere in the path
case "$file_path_norm" in
    */context/agents/brainiac/*.md|context/agents/brainiac/*.md)
        :  # Falls through to checks below
        ;;
    *)
        exit 0
        ;;
esac

# --- Read content/payload to look for bypass marker ---
payload=""
if [[ "$tool_name" == "Write" ]]; then
    payload=$(printf '%s' "$input" | jq -r '.tool_input.content // ""')
elif [[ "$tool_name" == "Edit" ]]; then
    new_string=$(printf '%s' "$input" | jq -r '.tool_input.new_string // ""')
    old_string=$(printf '%s' "$input" | jq -r '.tool_input.old_string // ""')
    payload="${new_string}"$'\n'"${old_string}"
fi

# Match marker pattern: brainiac-canonical-edit reason="..."
# Accepted forms:
#   <!-- brainiac-canonical-edit reason="bugfix urgent; upstream PR opened" -->
#   // brainiac-canonical-edit reason="..."
#   # brainiac-canonical-edit reason="..."
if printf '%s\n' "$payload" | grep -qE 'brainiac-canonical-edit[[:space:]]+reason="[^"]+"'; then
    # Emit a soft warning (does NOT block) so the user sees the audit trail
    reason=$(printf '%s\n' "$payload" | grep -oE 'brainiac-canonical-edit[[:space:]]+reason="[^"]+"' | head -1 | sed -E 's/.*reason="([^"]+)".*/\1/')
    echo "${MSG_CANONICAL_HEADER}" >&2
    if [[ "$BRAINIAC_LANG" == "pt-BR" ]]; then
        echo "Edição de canonical permitida via marker inline." >&2
        echo "  Arquivo: ${file_path_norm}" >&2
        echo "  Razão: ${reason}" >&2
        echo "Reviewer auditará na Fase 1 do Learn." >&2
    else
        echo "Canonical edit allowed via inline marker." >&2
        echo "  File: ${file_path_norm}" >&2
        echo "  Reason: ${reason}" >&2
        echo "Reviewer will audit during Learn Phase 1." >&2
    fi
    exit 0
fi

# --- Block: no bypass marker ---
cat >&2 <<EOF
${MSG_CANONICAL_HEADER}
${MSG_CANONICAL_BLOCKED}

  → ${file_path_norm}

${MSG_CANONICAL_HINT_1}

${MSG_CANONICAL_HINT_2}

${MSG_CANONICAL_HINT_3}
EOF

exit 2
