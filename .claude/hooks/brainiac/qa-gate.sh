#!/bin/bash
# Brainiac Context — QA Gate hook (Stop, soft/warning)
# If context/evolution/buglog.md was Edit/Write in this session AND the new
# entry appears to lack a test reference, surface a warning (non-blocking).
#
# This is a SOFT hook. It outputs a systemMessage via JSON on stdout with
# exit 0 — Claude sees it as a user-visible warning but is NOT blocked.
#
# Rule enforced (from agent-qa.md): Rule 1 — every bugfix L1+ must produce a
# regression test OR include an explicit test-infeasibility note.
#
# Detection heuristic: the buglog entry must mention at least one of:
#   Validation, test, spec, Playwright, Vitest, Jest, pytest, e2e, unit,
#   regression, infeasibility
#
# False positives are possible (e.g., the word "test" in an unrelated
# sentence). This hook is advisory — the human decides whether to act.

set -euo pipefail

input=$(cat)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // ""')

if [[ ! -f "$transcript_path" ]]; then
    exit 0
fi

# Was buglog.md edited in this session?
buglog_edits=$(jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and (.name == "Write" or .name == "Edit"))
    | .input.file_path // empty
' "$transcript_path" 2>/dev/null | tr '\\' '/' | grep -c 'context/evolution/buglog\.md$' || true)

if [[ "$buglog_edits" -eq 0 ]]; then
    # No buglog edits → nothing to validate
    exit 0
fi

# Extract the content actually written/edited to the buglog in this session
# (last Write or Edit's new_string / content payload)
last_buglog_payload=$(jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and (.name == "Write" or .name == "Edit"))
    | select((.input.file_path // "") | test("context/evolution/buglog\\.md$"))
    | (.input.content // .input.new_string // "")
' "$transcript_path" 2>/dev/null | tail -c 4000)

# Heuristic regex for test/validation references
if printf '%s\n' "$last_buglog_payload" | grep -qiE '(validation:|test[[:space:]s]*|spec|playwright|vitest|jest|pytest|e2e|unit|regression|infeasibility|test-infeasibility)'; then
    # Test reference found — good
    exit 0
fi

# No test reference detected — emit soft warning
cat <<'EOF'
{
  "systemMessage": "[Brainiac QA Gate — advisory] A buglog entry was edited in this session without a detectable test reference. Per agent-qa.md Rule 1, every bugfix L1+ must either (a) produce a regression test that would have caught the bug, OR (b) include an explicit test-infeasibility note explaining why a test is impractical. This is a soft warning — not a block. Review the buglog entry and add a Validation/test reference or an infeasibility note before closing the task."
}
EOF

exit 0
