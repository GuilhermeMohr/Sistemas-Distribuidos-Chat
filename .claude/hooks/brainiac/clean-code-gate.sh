#!/bin/bash
# Brainiac Context — PreToolUse hook for Write|Edit
# Enforces 4 deterministic Hard gates:
#   - SEC-1 (SECURITY_STANDARDS): Known token/secret patterns in any file
#   - Banned filenames (wip-*, temp-*, old-*, unused-*, legacy-*)
#   - File >500 lines in product code (escape: brainiac-allow-large)
#   - `: any` in TypeScript without inline brainiac:any-ok justification
#
# SEC-1 runs BEFORE the allowlist because token leak applies to all files
# (including .md, .json, .yml) — a leaked token in any tracked file is a leak.
#
# Allowlist (for code gates only): out-of-scope categories from CODE_STANDARDS.md
#   - Markdown, Workflow JSON, Schema files, Generated code,
#   - Lockfiles, SQL migrations & dumps, Configs declarativos
#
# i18n: messages loaded from messages/${BRAINIAC_LANG}.sh (default: en)
#
# Exit 2 with stderr blocks the tool call; stderr is shown to Claude.

set -euo pipefail

# --- i18n ---
BRAINIAC_LANG="${BRAINIAC_LANG:-en}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MSG_FILE="$SCRIPT_DIR/messages/${BRAINIAC_LANG}.sh"
[[ -f "$MSG_FILE" ]] || MSG_FILE="$SCRIPT_DIR/messages/en.sh"
[[ -f "$MSG_FILE" ]] && source "$MSG_FILE"

# Defaults if messages file is missing entirely
: "${MSG_HEADER:=[Brainiac Clean Code Gate]}"
: "${MSG_BANNED_FILENAME:=Banned filename pattern detected.}"
: "${MSG_BANNED_FILENAME_HINT:=Rename the file with a meaningful, domain-specific name.}"
: "${MSG_FILE_TOO_LARGE:=File exceeds 500 lines in product code.}"
: "${MSG_FILE_TOO_LARGE_HINT:=Split by responsibility, or add brainiac-allow-large marker.}"
: "${MSG_ANY_FORBIDDEN:=Use of any without justification.}"
: "${MSG_ANY_FORBIDDEN_HINT:=Replace any with explicit type, or add brainiac:any-ok comment.}"
: "${MSG_SEC1_TOKEN_LEAK:=Token/secret pattern detected (SEC-1).}"
: "${MSG_SEC1_TOKEN_LEAK_HINT:=Remove the literal token. Rotate at provider immediately. Replace with env var reference. There is no exemption for SEC-1.}"

# --- Parse input ---
input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')

[[ -z "$file_path" ]] && exit 0

# Normalize path for cross-platform matching
file_path_norm=$(printf '%s\n' "$file_path" | tr '\\' '/')
file_basename=$(basename "$file_path_norm")
file_ext_lower=$(printf '%s\n' "${file_basename##*.}" | tr '[:upper:]' '[:lower:]')

# --- Read content early (shared across gates) ---
content=""
old_string=""
new_string=""

if [[ "$tool_name" == "Write" ]]; then
    content=$(printf '%s' "$input" | jq -r '.tool_input.content // ""')
elif [[ "$tool_name" == "Edit" ]]; then
    old_string=$(printf '%s' "$input" | jq -r '.tool_input.old_string // ""')
    new_string=$(printf '%s' "$input" | jq -r '.tool_input.new_string // ""')
fi

# --- Gate 0 (SEC-1): Token/Secret leak detection (applies to ALL files) ---
# Runs before allowlist because leaked tokens in .md/.json/.yml are still leaks.
# Patterns: high-confidence only (low FP rate). Reviewer agent handles the rest.
# Whitelist: test fixtures, *.example.*, mocks — context where fake tokens belong.

sec1_skip="no"
case "$file_path_norm" in
    *test*|*Test*|*/fixtures/*|*/__tests__/*|*/mocks/*|*/fakes/*|*.example.*|*/.env.example)
        sec1_skip="yes" ;;
esac

if [[ "$sec1_skip" == "no" ]]; then
    sec1_check_content=""
    if [[ "$tool_name" == "Write" ]] && [[ -n "$content" ]]; then
        sec1_check_content="$content"
    elif [[ "$tool_name" == "Edit" ]] && [[ -n "$new_string" ]]; then
        sec1_check_content="$new_string"
    fi

    if [[ -n "$sec1_check_content" ]]; then
        # High-confidence token patterns (regex alternation)
        SEC1_PATTERN='ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{82}|gho_[A-Za-z0-9]{36}|ghs_[A-Za-z0-9]{36}|ghr_[A-Za-z0-9]{36}|AKIA[0-9A-Z]{16}|sk_live_[A-Za-z0-9]{24,}|xox[baprs]-[A-Za-z0-9-]{10,48}'

        sec1_match=$(printf '%s' "$sec1_check_content" | grep -oE "$SEC1_PATTERN" | head -1 || true)
        if [[ -n "$sec1_match" ]]; then
            # Placeholder heuristic: extract body after the known prefix.
            # If the body has <=3 distinct characters across 20+ chars, treat
            # as documented placeholder (e.g., ghp_xxxxxxxxxxxx, AKIAXXXXXXXXXXXX).
            # Real tokens have high entropy (8+ distinct chars across the body).
            sec1_body=$(printf '%s' "$sec1_match" | sed -E 's/^(ghp_|github_pat_|gho_|ghs_|ghr_|AKIA|sk_live_|xox[baprs]-)//')
            sec1_is_placeholder="no"
            if [[ ${#sec1_body} -ge 20 ]]; then
                sec1_distinct=$(printf '%s' "$sec1_body" | fold -w1 | sort -u | wc -l | tr -d ' \n\t')
                if [[ "$sec1_distinct" =~ ^[0-9]+$ ]] && [[ $sec1_distinct -le 3 ]]; then
                    sec1_is_placeholder="yes"
                fi
            fi

            if [[ "$sec1_is_placeholder" == "no" ]]; then
                # Real-looking token — mask the match (never echo full token to stderr)
                sec1_prefix="${sec1_match:0:8}"
                echo "$MSG_HEADER" >&2
                echo "$MSG_SEC1_TOKEN_LEAK" >&2
                echo "  → $file_path" >&2
                echo "  Pattern detected starting with: ${sec1_prefix}*** (masked)" >&2
                echo "$MSG_SEC1_TOKEN_LEAK_HINT" >&2
                exit 2
            fi
        fi
    fi
fi

# --- Allowlist: out-of-scope categories (CODE_STANDARDS.md §Out of Scope) ---

# Markdown
[[ "$file_basename" == *.md ]] && exit 0
[[ "$file_basename" == *.mdx ]] && exit 0

# Generated code
[[ "$file_basename" == *.gen.* ]] && exit 0

# Lockfiles
case "$file_basename" in
    *-lock.*|package-lock.json|pnpm-lock.yaml|yarn.lock|Cargo.lock|poetry.lock|Gemfile.lock|composer.lock)
        exit 0 ;;
esac

# Workflow JSON (n8n, Make, Zapier, Temporal)
case "$file_basename" in
    *workflow*.json|*flow*.json) exit 0 ;;
esac

# Schema files
case "$file_basename" in
    *schema*.json|openapi*.json|openapi*.yaml|openapi*.yml|*.graphql|*.gql)
        exit 0 ;;
esac

# SQL migrations & dumps
if [[ "$file_path_norm" == */migrations/* ]]; then exit 0; fi
case "$file_basename" in
    *migration*.sql|*dump*.sql|*schema*.sql) exit 0 ;;
esac

# Configs declarativos (catch-all by extension)
case "$file_ext_lower" in
    json|yaml|yml|toml|ini) exit 0 ;;
esac

# --- Gate 1: Banned filenames ---
case "$file_basename" in
    wip-*|temp-*|old-*|unused-*|legacy-*)
        echo "$MSG_HEADER" >&2
        echo "$MSG_BANNED_FILENAME" >&2
        echo "  → $file_path" >&2
        echo "$MSG_BANNED_FILENAME_HINT" >&2
        exit 2
        ;;
esac

# --- Determine if file is product code (extensions covered by CODE_STANDARDS) ---
is_product_code="no"
case "$file_ext_lower" in
    ts|tsx|js|jsx|py|go|rs|rb|java|kt|swift|cs|php|sh|sql)
        is_product_code="yes" ;;
esac

# (Content already read above for SEC-1 — variables: content, old_string, new_string)

# --- Gate 2: File >500 lines in product code ---
count_lines() {
    # Count lines robustly. Returns 0 for empty input.
    local input="$1"
    [[ -z "$input" ]] && { echo 0; return; }
    printf '%s\n' "$input" | wc -l | tr -d ' \n\t'
}

if [[ "$is_product_code" == "yes" ]]; then
    line_count=0

    if [[ "$tool_name" == "Write" ]]; then
        line_count=$(count_lines "$content")
    elif [[ "$tool_name" == "Edit" ]] && [[ -f "$file_path" ]]; then
        # Estimate post-edit line count
        current_lines=$(wc -l < "$file_path" 2>/dev/null | tr -d ' \n\t')
        [[ -z "$current_lines" ]] && current_lines=0
        old_lines=$(count_lines "$old_string")
        new_lines=$(count_lines "$new_string")
        line_count=$((current_lines - old_lines + new_lines))
    fi

    # Sanity check
    [[ ! "$line_count" =~ ^[0-9]+$ ]] && line_count=0

    if [[ $line_count -gt 500 ]]; then
        # Check for brainiac-allow-large escape WITH reason="..." in first 10 lines.
        # Pattern: marker + whitespace + reason="<non-empty>"
        # Marker without reason is invalid — bloqueia.
        has_escape="no"
        ESCAPE_PATTERN='brainiac-allow-large[[:space:]]+reason="[^"]+"'

        if [[ "$tool_name" == "Write" ]] && [[ -n "$content" ]]; then
            if printf '%s' "$content" | head -10 | grep -qE "$ESCAPE_PATTERN"; then
                has_escape="yes"
            fi
        elif [[ -f "$file_path" ]]; then
            if head -10 "$file_path" 2>/dev/null | grep -qE "$ESCAPE_PATTERN"; then
                has_escape="yes"
            fi
        fi

        if [[ "$has_escape" == "no" ]]; then
            echo "$MSG_HEADER" >&2
            echo "$MSG_FILE_TOO_LARGE" >&2
            echo "  → $file_path ($line_count lines, limit 500)" >&2
            echo "$MSG_FILE_TOO_LARGE_HINT" >&2
            echo "  Marker requires non-empty reason. Format: brainiac-allow-large reason=\"<justificativa>\"" >&2
            exit 2
        fi
    fi
fi

# --- Gate 3: ': any' in TypeScript without inline justification ---
if [[ "$file_ext_lower" == "ts" ]] || [[ "$file_ext_lower" == "tsx" ]]; then
    # Check the relevant content (full content for Write, new_string for Edit)
    check_content=""
    if [[ "$tool_name" == "Write" ]]; then
        check_content="$content"
    elif [[ "$tool_name" == "Edit" ]]; then
        check_content="$new_string"
    fi

    if [[ -n "$check_content" ]]; then
        # Find lines with ': any' that:
        #   - don't start with comment markers (* or //)
        #   - don't have brainiac:any-ok WITH reason="..." on the same line
        # Pattern: marker + whitespace + reason="<non-empty>"
        # Marker without reason is invalid — bloqueia (line surfaces as violation).
        violations=$(printf '%s' "$check_content" \
            | grep -nE ':[[:space:]]*any\b' \
            | grep -vE '^[0-9]+:[[:space:]]*[*/]' \
            | grep -vE 'brainiac:any-ok[[:space:]]+reason="[^"]+"' \
            || true)

        if [[ -n "$violations" ]]; then
            echo "$MSG_HEADER" >&2
            echo "$MSG_ANY_FORBIDDEN" >&2
            echo "  → $file_path" >&2
            printf '%s\n' "$violations" | head -3 | sed 's/^/    line /' >&2
            echo "$MSG_ANY_FORBIDDEN_HINT" >&2
            echo "  Marker requires non-empty reason. Format: // brainiac:any-ok reason=\"<justificativa>\"" >&2
            exit 2
        fi
    fi
fi

exit 0
