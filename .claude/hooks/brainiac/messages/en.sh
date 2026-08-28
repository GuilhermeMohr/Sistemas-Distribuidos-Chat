# Brainiac Context — i18n messages (English)
# Sourced by hook scripts. Default language.
# To switch: set BRAINIAC_LANG=pt-BR in .claude/settings.json env block.

# --- Common ---
MSG_HEADER="[Brainiac Clean Code Gate]"

# --- Gate: Banned filenames ---
MSG_BANNED_FILENAME="Banned filename pattern detected (No Limbo Rule)."
MSG_BANNED_FILENAME_HINT="Rename the file with a meaningful, domain-specific name. Forbidden prefixes: wip-, temp-, old-, unused-, legacy-."

# --- Gate: File size ---
MSG_FILE_TOO_LARGE="File exceeds 500 lines in product code."
MSG_FILE_TOO_LARGE_HINT="Split by responsibility, or add 'brainiac-allow-large reason=\"...\"' marker in the first 10 lines if splitting would fragment the domain."

# --- Gate: any without justification ---
MSG_ANY_FORBIDDEN="Use of \`: any\` without inline justification."
MSG_ANY_FORBIDDEN_HINT="Replace 'any' with an explicit type. If genuinely needed (e.g., parsing boundary), add '// brainiac:any-ok reason=\"...\"' comment on the same line."

# --- Gate: SEC-1 token/secret leak ---
MSG_SEC1_TOKEN_LEAK="Token/secret pattern detected (SEC-1 from SECURITY_STANDARDS)."
MSG_SEC1_TOKEN_LEAK_HINT="Remove the literal token immediately. Three steps: (1) rotate at provider (revoke/regenerate), (2) replace in code with env var reference (e.g., process.env.GITHUB_TOKEN), (3) audit blast radius at provider. There is NO exemption for SEC-1 — '// security-allow' markers do not apply here."

# --- Gate: Canonical protection ---
MSG_CANONICAL_HEADER="[Brainiac Canonical Gate]"
MSG_CANONICAL_BLOCKED="Edit blocked: target is a framework canonical under context/agents/brainiac/."
MSG_CANONICAL_HINT_1="Preferred: refactor the change as a Project Extension under context/agents/project/ via /brainiac-context-agent."
MSG_CANONICAL_HINT_2="Official path: run /brainiac-context-update to evolve canonicals."
MSG_CANONICAL_HINT_3="Justified bypass: include the marker brainiac-canonical-edit reason=\"...\" inside the Edit/Write payload so the reviewer can audit later."

# --- Gate: Context Hygiene / PostCompact (Iron Law 7) ---
MSG_POST_COMPACT_HEADER="=== Brainiac post-compact reload (Iron Law 7) ==="
MSG_POST_COMPACT_LINE_TRIGGER="Compact completed, trigger"
MSG_POST_COMPACT_LINE_FRAMEWORK="Framework spec has been re-injected via @AGENTS.md -> @context/.brainiac-context-framework.md (import chain)."
MSG_POST_COMPACT_LINE_CRITICAL="Before critical work (Build / Learn / framework update / migration / refactor / complex bugfix):"
MSG_POST_COMPACT_STEP1="Confirm access to Iron Laws 1-7 (framework spec loaded)."
MSG_POST_COMPACT_STEP2="Re-read the active intent (feature-*.md / bug-*.md / refactor-*.md)."
MSG_POST_COMPACT_STEP3="Re-read ADRs referenced in the intent's Related section."
MSG_POST_COMPACT_STEP4="Check .brainiac/last-compact-state.json for handoff."
MSG_POST_COMPACT_STEP5="Run /context — if >=60%, continuing critical work without a new /compact (continuation) or /clear (genuine scope switch) is a Brainiac violation (Iron Law 7.5). The two are not interchangeable: use /compact when continuing the same workflow; /clear only between distinct cycles."
MSG_POST_COMPACT_FOOTER="If it is a simple continuation, the summary is sufficient."

# --- Gate: Context Hygiene / PreCompact (Iron Law 7) ---
MSG_PRE_COMPACT_HEADER="[Brainiac pre-compact]"
MSG_PRE_COMPACT_BODY="Compact starting. Iron Law 7: handoff saved to .brainiac/last-compact-state.json. post-compact.sh will inject the reload checklist. If this compact is a response to a scope-switch, consider /clear instead (Iron Law 7.4)."
MSG_PRE_COMPACT_BLOCKED_REASON="Auto-compact blocked by BRAINIAC_BLOCK_AUTOCOMPACT=1 (opt-in). Run /compact manually to confirm, or unset the env var to allow."

# --- Gate: Minimum Context Gate ---
MSG_GATE_BLOCK_HEADER="[Brainiac Minimum Context Gate]"
MSG_GATE_VERSIONED_FATAL="Bypass via .claude/settings.json (versioned) is forbidden. This is a structural anti-pattern: a versioned bypass=true becomes a silent permanent bypass commit. Use shell env (export BRAINIAC_CONTEXT_GATE_BYPASS=true) or .claude/settings.local.json (not versioned)."
MSG_GATE_BYPASS_NO_REASON="Bypass requires BRAINIAC_CONTEXT_GATE_BYPASS_REASON with at least 12 visible characters. Example: export BRAINIAC_CONTEXT_GATE_BYPASS_REASON='hotfix prod pipeline failing'"
MSG_GATE_BYPASS_NOTICE="Brainiac Minimum Context Gate bypass recorded in"
MSG_GATE_MISSING_INTENT="Active task intent missing — read context/intent/feature-*.md, bug-*.md, or refactor-*.md before editing product code."
MSG_GATE_MISSING_STANDARDS="Code/security standards not loaded — read context/code-standards.md and context/security-standards.md."
MSG_GATE_MISSING_SENSORS="context/sensors/sensors.md exists in the project but was not loaded in this session. Read it before editing product code."
MSG_GATE_UNLOCK="To unlock: Read project-intent.md + active intent + code-standards.md + security-standards.md (+ sensors.md if present). Then retry the edit."

# --- Gate: Context Research Subagent ---
MSG_RESEARCH_GATE_BLOCK_HEADER="[Brainiac Context Research Gate]"
MSG_RESEARCH_GATE_VERSIONED_FATAL="Bypass via .claude/settings.json (versioned) is forbidden. Structural anti-pattern. Use shell env (export BRAINIAC_RESEARCH_GATE_BYPASS=true) or .claude/settings.local.json."
MSG_RESEARCH_GATE_BYPASS_NO_REASON="Bypass requires BRAINIAC_RESEARCH_GATE_BYPASS_REASON with at least 12 visible characters. Example: export BRAINIAC_RESEARCH_GATE_BYPASS_REASON='exploratory spike before formal research'"
MSG_RESEARCH_GATE_BYPASS_NOTICE="Brainiac Context Research Gate bypass recorded in"
MSG_RESEARCH_GATE_MISSING="Research report missing for the active intent. Run /brainiac-context-research to generate context/research/<intent-slug>.md mapping referenced ADRs/knowledge transitively."
MSG_RESEARCH_GATE_STALE="Research report is stale (intent modified, dependency updated, TTL expired, or refs incomplete). Run /brainiac-context-research to regenerate."
MSG_RESEARCH_GATE_UNLOCK="To unlock: run /brainiac-context-research (auto-invoked or manual) to (re)generate context/research/<intent-slug>.md. Hook enforces report existence + freshness + completeness — main agent still MUST re-read critical artifacts directly. Discovery evidence != execution clearance."

# --- Workflow-aware gates: native Dynamic Workflow subagent ---
MSG_WORKFLOW_CONTEXT_REQUIRED="BRAINIAC_WORKFLOW_CONTEXT_REQUIRED — this edit is running inside a native Dynamic Workflow subagent, which inherits the parent session's transcript. The active intent therefore cannot be trusted from the transcript, and no valid workflow binding was found. A product-code write requires an explicit, validated binding (.brainiac/workflow-bindings/index.json) anchored to an approved approval envelope (ENVELOPE_APPROVAL by hash). Generate the workflow via /brainiac-context-orchestrate-workflow-export so each subagent carries its binding. To allow unbound exploratory writes, set BRAINIAC_WORKFLOW_UNBOUND=advisory (the write-block degrades to a warning)."
MSG_WORKFLOW_UNBOUND_ADVISORY="Brainiac workflow gate: unbound workflow subagent write allowed in advisory mode (BRAINIAC_WORKFLOW_UNBOUND=advisory). The active intent was NOT inherited from the parent session; no intent context is being enforced for this write."
# Bash gate: unbound workflow subagent may run ONLY the registrar Step-0.
MSG_WORKFLOW_BASH_HEADER="[Brainiac Workflow Bash Gate]"

# --- Gate: Scope-switch (Iron Law 7.4) ---
MSG_SCOPE_SWITCH_HEADER="[Brainiac context-hygiene]"
MSG_SCOPE_SWITCH_BODY="Scope switch detected. Iron Law 7.4: never start a new scope at or above 40%.

Actions:
- Run /context to see current usage.
- If >=40%, /clear is required before proceeding (do not use /compact for scope switch).
- /compact only preserves the same task; detailed history is lost.
- After /clear, framework spec is re-injected via @import chain (CLAUDE.md -> @AGENTS.md -> @context/.brainiac-context-framework.md)."

# --- Gate: Secret-Read ---
MSG_SECRET_GATE_HEADER="[Brainiac Secret-Read Gate]"
MSG_SECRET_GATE_BLOCKED="Read blocked: target is in the secret-file class (.env*, secrets/, *.key, *.pem, credentials.json, service-account*.json, *-secret.yaml). CLAUDE.md global (Security and scope): \"Do not read or request secrets\"."
MSG_SECRET_GATE_HINT="To know WHICH env vars exist, read code that does process.env.X / Deno.env.get(). To know VALUES, ask the user. Permission denied is not an invitation to switch file or tool. If this was a jq filter accessing a key literally named env (e.g. jq '.env.FOO'), use bracket notation .[\"env\"] instead — it is not a secret file."
MSG_SECRET_GATE_RETRY_HEADER="[Brainiac Secret-Read Gate — RETRY DETECTED]"
MSG_SECRET_GATE_RETRY_BODY="This is attempt N at accessing a secret in this session. STOP. You are in bypass-via-retry pattern. Acknowledge openly to the user that the evidence you want is not available without explicit authorization."
MSG_SECRET_GATE_EXAMPLE_NOTICE="Read allowed on .env.example (template/example file). REMINDER: this file must NOT contain real values. If you notice real secret/credential during reading, alert the user immediately."
MSG_SECRET_GATE_ENV_BLOCKED="Command blocked: it would expose environment variable values or parse a secret file at runtime (.env/process.env/env/printenv)."
MSG_SECRET_GATE_ENV_HINT="Safe alternatives: search code for variable NAMES (e.g. rg 'process.env.NAME'), or ask the user for VALUES. Do not print process.env, env dumps, printenv secret variables, or parse .env files inside runtime scripts."
MSG_SECRET_GATE_COPY_NOTICE="Opaque same-class copy allowed: source and destination are both secret-class, so no value is exposed to the model (file → file, never stdout). The secret stays labeled at the destination — future reads of it remain blocked. Logged (reason=copy_safe)."
MSG_SECRET_GATE_COPY_LAUNDER_BLOCKED="Copy blocked (laundering vector): the destination is NOT secret-class (a plain file, /dev/stdout, or a device). Copying a secret to a non-secret destination would strip its protection and let a later read expose the value."
MSG_SECRET_GATE_COPY_LAUNDER_HINT="To copy a secret into a worktree, the destination must also be secret-class (e.g. cp .env.local <worktree>/.env.local). To inspect VALUES, ask the user. Never copy a secret to /dev/stdout, '-', or a plain non-secret file."
MSG_SECRET_GATE_SHELLVAR_BLOCKED="Command blocked: an output command would print the VALUE of a sensitive environment variable through shell parameter expansion."
MSG_SECRET_GATE_SHELLVAR_HINT="BEWARE: \${VAR:-default} PRINTS THE VALUE whenever the variable IS set — it is not the inverse of \${VAR:+word}. To test EXISTENCE without revealing: [ -n \"\$VAR\" ] && echo SET || echo UNSET, or \${VAR:+SET}. For size only: \${#VAR}. To hand a credential to a child process, assign it inline (VAR=\"\$SECRET\" cmd) — that never reaches stdout. To learn the VALUE, ask the user."

# --- Gate: Knowledge Consultation ---
MSG_KNOWLEDGE_GATE_HEADER="[Brainiac Knowledge Gate]"
MSG_KNOWLEDGE_GATE_BLOCKED="Consult the required knowledge before this Write/Edit (policy declared in context/knowledge/INDEX.md)."
MSG_KNOWLEDGE_GATE_UNLOCK="To unlock: Read (or @ref) the knowledge file named above, apply its checklist, then retry the edit. Discovery != clearance."
MSG_KNOWLEDGE_GATE_BAD_JSON="Invalid policy: a non-empty line in the BRAINIAC:KNOWLEDGE-GATE-RULES block is not a JSON object. Fix context/knowledge/INDEX.md (fail-closed: a broken policy is not a silent bypass)."
MSG_KNOWLEDGE_GATE_INVALID_RULE="Invalid rule: knowledge_path must point to context/knowledge/{patterns,anti-patterns}/*.md (no secrets, no path traversal)."
MSG_KNOWLEDGE_GATE_MISSING_KNOWLEDGE="Invalid rule: the knowledge_path declared by the matched rule does not exist on disk."
MSG_KNOWLEDGE_GATE_BAD_MODE="Invalid rule: mode must be 'block' or 'advisory'."
MSG_KNOWLEDGE_GATE_BAD_REGEX="Invalid rule: path_regex is missing or not a valid regex. Fix context/knowledge/INDEX.md (fail-closed: an unevaluable matching predicate is not a silent bypass)."
MSG_KNOWLEDGE_GATE_BYPASS_NO_REASON="Bypass requires BRAINIAC_KNOWLEDGE_GATE_BYPASS_REASON with at least 12 visible characters. Example: export BRAINIAC_KNOWLEDGE_GATE_BYPASS_REASON='hotfix, knowledge already internalized'"
MSG_KNOWLEDGE_GATE_SETTINGS_GUARD="Bypass via .claude/settings.json (versioned) is forbidden. Structural anti-pattern: a versioned bypass=true becomes a silent permanent bypass. Use shell env (export BRAINIAC_KNOWLEDGE_GATE_BYPASS=true) or .claude/settings.local.json (not versioned)."

# --- Gate: No Auto-Merge ---
MSG_NOMERGE_HEADER="[Brainiac No Auto-Merge Gate]"
MSG_NOMERGE_FORCE="Blocked: destructive force-push to main."
MSG_NOMERGE_ACTIVE="Blocked: merge during an ACTIVE orchestration run (false-green risk — let the integrate closeout attest first)."
MSG_NOMERGE_STALE="Warning: an open orchestration run exists but is stale (no recent activity) — merge allowed; consider closing the run."
MSG_NOMERGE_HINT="Human merge only after the integrate closeout attests the run. Allowed mid-run: git merge --abort/--continue/--quit, git merge-base. Close/clean stale runs under .brainiac/runs/."
