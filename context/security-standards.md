# Sistemas-Distribuidos-Chat — SECURITY_STANDARDS

- **Version:** v0.1
- **Status:** Adopted
- **Standards-Version:** 1.0
- **Updated:** 2026-08-26

> H1 above follows Canonical Markdown Schema Rule 1 (`<Project> — SECURITY_STANDARDS`, Hard). Metadata block follows Rule 2 (Standards class: `Version`, `Status`, `Standards-Version`, `Updated` — Hard).
>
> **Project:** Sistemas-Distribuidos-Chat
> **Base canonical:** [`Brainiac-Context/SECURITY_STANDARDS.md`](https://github.com/kaleldias/Brainiac-Context/blob/main/SECURITY_STANDARDS.md) (Standards-Version 1.0)

This is the project's **local snapshot** of the Brainiac Context Security Standards. It is a **material copy** of the universal rules at the time of bootstrap, plus project-specific overrides at the end.

To update when the framework versions: run `/brainiac-context-update`.

---

## Standards are loaded automatically

> **Design principle:** a human should never need to remember to load this document. If you are typing "check security", the framework is broken.

Loading happens at 3 framework mechanisms, without human invocation:

| Point | Mechanism | When |
|---|---|---|
| **Bootstrap** | `brainiac-context-init` copies `templates/security-standards.md.template` → `context/security-standards.md` | When creating a new project |
| **Real-time hook** | `brainiac-clean-code-gate.sh` enforces deterministic subset of SEC-1: known token patterns (`ghp_*`, AWS `AKIA*`, etc.) blocked at write time | On every `Write`/`Edit` |
| **Quality Gate** | `brainiac-context-learn` Phase 1 invokes `agent-reviewer.md` with SECURITY_STANDARDS as checklist (SEC-1 full + SEC-2 + SEC-3) | At end of every Build phase |

> **Distribution of the 3 Security Hard Gates by mechanism:**
> - SEC-1 partial enforcement at write time (hook detects known token patterns)
> - SEC-1 full + SEC-2 + SEC-3 enforced at Phase 1 Quality Gate (reviewer agent)
> - SEC-1 optionally enforced in CI via `gitleaks` or `trufflehog` sensor (recommended, not required)

You never run `/check-security`. Security checks are part of the **substrate** the framework operates on.

---

## TL;DR — Quick checklist

15-second read. 3 Security Hard Gates, all 🔴 Block when violated.

| Gate | What it detects | Enforcement |
|---|---|---|
| **SEC-1** Token/secret leak in versioned files | `ghp_*`, `github_pat_*`, `ghs_*`, `gho_*`, AWS `AKIA*`, generic high-entropy strings | Hook (pre-edit) + Reviewer (Phase 1) + Sensor (optional) |
| **SEC-2** Hardcoded credentials in product code | `password = "..."`, `apiKey = "..."`, `Bearer <token>` outside tests/mocks | Reviewer (Phase 1) |
| **SEC-3** Disabled security primitives without justification | `DISABLE ROW LEVEL SECURITY`, `cors: { origin: '*' }`, `eval(...)`, `dangerouslySetInnerHTML` without `// security-allow reason="..."` | Reviewer (Phase 1) |

All three are **Block findings** when detected without explicit, traceable exemption. There is **no Soft tier** for Security Hard Gates — security violations are binary.

---

## 1. SEC-1 — Token / Secret Leak Detection

**Rule**: No literal tokens, API keys, or secrets in any versioned file, in any PR body, in any GitHub issue body, in any code comment.

### Patterns detected

| Pattern | Origin | Confidence |
|---|---|---|
| `ghp_[A-Za-z0-9]{36}` | GitHub Personal Access Token (classic) | 🟢 High |
| `github_pat_[A-Za-z0-9_]{82}` | GitHub Fine-grained PAT | 🟢 High |
| `gho_[A-Za-z0-9]{36}` | GitHub OAuth token | 🟢 High |
| `ghs_[A-Za-z0-9]{36}` | GitHub Server token | 🟢 High |
| `ghr_[A-Za-z0-9]{36}` | GitHub Refresh token | 🟢 High |
| `AKIA[0-9A-Z]{16}` | AWS Access Key ID | 🟢 High |
| `sk_live_[A-Za-z0-9]{24,}` | Stripe live secret key | 🟢 High |
| `sk_test_[A-Za-z0-9]{24,}` | Stripe test secret key | 🟡 Medium |
| `xox[baprs]-[A-Za-z0-9-]{10,48}` | Slack token | 🟢 High |
| `eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}` | JWT | 🟡 Medium |
| 40+ char generic high-entropy strings (mixed case + digits) | Possible unknown token | 🔴 Low |

### Where this applies

- Versioned files (`.md`, `.yml`, `.json`, source code, etc.)
- GitHub issue bodies and comments
- GitHub PR descriptions and review comments
- Brainiac context files (`context/intent/*.md`, `context/decisions/*.md`)
- Code comments

### Where this does NOT apply

- `.env`, `.env.local`, `.env.*.local` — if gitignored (verify with `git check-ignore`)
- Test fixtures matching `*test*` / `**/fixtures/**` / `**/__tests__/**` AND value matches fake pattern (`ghp_test_*`, `AKIATEST*`)
- Documented placeholders showing token format: `ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`

### Exemption

❌ **None.** There is no valid reason to keep a literal token in a versioned file. The reviewer rejects any `// security-allow` marker attached to SEC-1.

### Fix when detected

1. Rotate immediately at the provider (revoke + regenerate)
2. Remove from history if already committed: `git filter-repo` or BFG Repo-Cleaner
3. Replace with env var reference: `process.env.GITHUB_TOKEN`
4. Audit blast radius at provider (check usage during exposure window)

---

## 2. SEC-2 — Hardcoded Credentials in Product Code

**Rule**: Credentials must not appear as string literals in product code. Load from environment variables, secret managers, or platform-provided injection.

### Patterns detected (outside whitelist paths)

| Pattern | Example flagged |
|---|---|
| `password\s*[:=]\s*["'][^"']+["']` | `const password = "admin123"` |
| `apiKey\s*[:=]\s*["'][^"']+["']` | `apiKey: "1a2b3c..."` |
| `secret\s*[:=]\s*["'][^"']+["']` | `secret: "supersecret"` |
| `Bearer\s+[A-Za-z0-9_-]{20,}` | `Authorization: "Bearer eyJ..."` |
| `(postgres\|mongodb(\+srv)?\|mysql)://[^@]+:[^@]+@` | `postgres://user:pass@host/db` |

### Whitelist (not findings)

- Paths: `**/test/**`, `**/tests/**`, `**/__tests__/**`, `**/*.test.*`, `**/*.spec.*`
- Paths: `**/fixtures/**`, `**/mocks/**`, `**/fakes/**`
- Files: `*.example.*`, `*.stories.*`
- Values: `"changeme"`, `"placeholder"`, `"xxxx"`, `"foo"`, `"test"`, repeated character sequences

### Exemption

❌ **None.** Move to env var, always.

### Fix when detected

1. Move value to `.env` (must be gitignored)
2. Reference via `process.env.VAR_NAME`
3. Document var name in `.env.example` (without real value)

---

## 3. SEC-3 — Disabled Security Primitives Without Justification

**Rule**: Code that disables, weakens, or bypasses a security primitive must carry an explicit, traceable exemption marker. Otherwise it's a 🔴 Block finding.

### Patterns detected

| Pattern | Why it matters |
|---|---|
| `DISABLE ROW LEVEL SECURITY` in SQL | RLS bypass |
| `cors: { origin: '*' }` or `Access-Control-Allow-Origin: *` | Cross-origin attacks |
| `eval(...)`, `new Function(...)`, `exec(...)` with user input | Arbitrary code execution |
| `dangerouslySetInnerHTML={{__html: ...}}` (React) | XSS vector |
| `v-html="..."` (Vue) | XSS vector |
| `helmet.contentSecurityPolicy(false)` or `csp: false` | Disabled CSP |
| `csrfProtection: false` | Disabled CSRF protection |
| `verifySSL: false`, `rejectUnauthorized: false`, `--insecure`, `-k` in curl | MITM exposure |

### Exemption marker

When genuinely needed, add inline marker directly above the offending line:

```ts
// security-allow reason="Public RSS feed endpoint; CSP would block legitimate
// 3rd-party reader compatibility; tracked in ADR-007"
res.setHeader('Content-Security-Policy', '');
```

Rules:
1. Directly above the offending line (no blank lines, no intervening comments)
2. `reason="..."` non-empty
3. Reason is **specific** (reviewer questions vague reasons)
4. For permanent exemptions, link to ADR: `reason="...; see context/decisions/NNN-<topic>.md"`

### Fix when detected without marker

1. Re-enable the primitive if possible
2. If genuinely needed: add `// security-allow reason="..."` with real reason + ADR reference
3. Document threat model and mitigation in `context/decisions/NNN-<topic>.md`

---

## Enforcement Summary

| Gate | Real-time hook | Phase 1 Quality Gate | Optional sensor | Severity |
|---|---|---|---|---|
| **SEC-1** (token leak) | ✅ Known patterns blocked | ✅ Full pattern set + entropy | ✅ `gitleaks` / `trufflehog` | 🔴 Block, no exemption |
| **SEC-2** (hardcoded credentials) | ❌ | ✅ Full pattern set with whitelist | ⚠️ Optional custom | 🔴 Block, no exemption |
| **SEC-3** (disabled primitives) | ❌ | ✅ Full pattern set + marker validation | ⚠️ Project-specific custom | 🔴 Block unless `security-allow reason="..."` |

---

## Project-Specific Overrides

> Preenchido no bootstrap via security archeology pass. **Zero violações SEC-1/2/3 detectadas** (só networking stdlib, nenhum segredo hardcoded).

### Legacy security debt (não-bloqueante)

| Item | Confidence | Ação |
|---|---|---|
| Tráfego multicast não-cifrado / não-autenticado | 🟢 High | **Não é defeito** — inerente ao trabalho. Documentar como limitação no relatório §10.6 |
| Ausência de `.gitignore` no repo | 🟢 High | ✅ Resolvido no bootstrap (`.gitignore` criado) |

### Additional token patterns (project-specific providers)

- Nenhum — projeto stdlib-only sem provedores/segredos.

### Test/mock whitelist (project-specific paths)

- Nenhum path adicional (sem suíte de testes ainda).

### Additional SEC-3 patterns (project-specific disabled primitives)

- Nenhum — não há primitivas de segurança sendo desabilitadas no código.

### Optional SEC sensors (CI)

- [ ] `gitleaks` — não configurado; baixa prioridade (sem segredos no projeto).
- [ ] `pip-audit` — N/A (sem dependências externas).

### Project security ADRs

- Nenhuma decisão de segurança dedicada até o momento.

---

## Standards Version Compatibility

| Snapshot Standards-Version | Framework canonical version | Notes |
|---|---|---|
| 1.0 | SECURITY_STANDARDS.md v0.1+ | Initial release; SEC-1, SEC-2, SEC-3 |

When the framework upgrades to a higher Standards-Version (e.g., 1.1 adds SEC-4 SQL injection), the project decides whether to update via `/brainiac-context-update`.

---

## Last Audit

> **Update after each `/brainiac-context-update` execution or manual review.**

- Date: 2026-08-26
- Reviewer: <name or "bootstrap (no audit yet)">
- Result: <pass | issues found> — <link to QA gate if applicable>
- Notes: Initial bootstrap. No findings yet.
