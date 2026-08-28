# Sistemas-Distribuidos-Chat — CODE_STANDARDS

- **Version:** v0.2
- **Status:** Adopted
- **Standards-Version:** 1.1
- **Updated:** 2026-08-26

> H1 above follows Canonical Markdown Schema Rule 1 (`<Project> — CODE_STANDARDS`, Hard). Metadata block follows Rule 2 (Standards class: `Version`, `Status`, `Standards-Version`, `Updated` — Hard).
>
> **Project:** Sistemas-Distribuidos-Chat
> **Base canonical:** [`Brainiac-Context/CODE_STANDARDS.md`](https://github.com/kaleldias/Brainiac-Context/blob/main/CODE_STANDARDS.md) (Standards-Version 1.1)

This is the project's **local snapshot** of the Brainiac Context Code Standards. It is a **material copy** of the universal rules at the time of bootstrap, plus project-specific overrides at the end.

To update when the framework versions: run `/brainiac-context-update`.

---

## Standards are loaded automatically

> **Design principle:** a human should never need to remember to load this document. If you are typing "follow the code standards", the framework is broken.

Loading happens at 7 framework mechanisms, without human invocation:

| Point | Mechanism | When |
|---|---|---|
| **Bootstrap** | `brainiac-context-init` copies `templates/code-standards.md.template` → `context/code-standards.md` | When creating a new project |
| **Build (Step 2)** | `agent-developer.md` loads `context/code-standards.md` automatically | Whenever the AI generates code |
| **Real-time hook** | `brainiac-clean-code-gate.sh` enforces deterministic subset of Hard gates: banned filenames (`wip-*`/`temp-*`/etc.), files >500 lines, `: any` without justification | On every `Write`/`Edit` |
| **QA Gate hook** | `brainiac-qa-gate.sh` enforces bugfix without referenced regression test | At end of every `Stop` |
| **Sensors** | `tsc --noEmit` / `eslint` / `ruff` enforce broken lint/typecheck | At end of Build |
| **Quality Gate** | `brainiac-context-learn` Phase 1 invokes `agent-reviewer.md` with CODE_STANDARDS as checklist (remaining Hard gates + 25 Soft + 3 Info) | At end of every Build phase |
| **Update** | `brainiac-context-update` propagates new framework standards versions | When framework versions |

> **Distribution of the 5 Hard gates by mechanism:**
> - 3 enforced in real-time by `brainiac-clean-code-gate.sh` hook (filename, file size, `: any`)
> - 1 enforced on Stop by `brainiac-qa-gate.sh` hook (bugfix without regression)
> - 1 enforced at end of Build via Sensors (lint/typecheck)
>
> A single hook does NOT enforce all 5 — these are 3 complementary mechanisms, each placed where it makes technical sense.

You never run `/follow-code-standards`. The standards are part of the **substrate** the framework operates on.

---

## TL;DR — Quick checklist

30-second read. Each item links to the section that goes deeper.

1. Functions **4–20 lines** (Soft); files **<500 lines in code** (Hard, with [`brainiac-allow-large`](#exception-mechanism-brainiac-allow-large)) ([§1](#1-code-style))
2. **SRP** per function and per module ([§1](#1-code-style))
3. Names **specific, unique, <5 grep hits** — ban `data`, `handler`, `Manager`, `Service`/`Util`/`Helper` when standalone ([§1](#1-code-style))
4. **Explicit types**; **`: any` forbidden** without explicit justification (Hard) ([§1](#1-code-style))
5. **Early returns**; max **2 indentation levels** ([§1](#1-code-style))
6. Comments **WHY, not WHAT**; preserve human comments, agent may remove its own ([§2](#2-comments))
7. `Implements: context/intent/...` header in **critical modules** (auth, payments, external integrations, security boundaries) ([§2](#2-comments))
8. **Public behavior / domain rule / boundary** gets a test; bugfix without regression test blocks (Hard) ([§3](#3-tests))
9. **Inject deps** via parameter/constructor; **wrap third-party** only for I/O / DB / payments / auth / storage / external APIs ([§4](#4-dependencies))
10. Structure follows **framework convention**; predictable paths ([§5](#5-structure))
11. **No `wip-*`, `temp-*`, `old-*`, `unused-*`, `legacy-*` filenames** (Hard) ([§5](#5-structure))
12. **Structured logs** (JSON) for debug; plain text only for user-facing CLI ([§7](#7-logging))
13. **Boundary hygiene**: I/O separated from pure logic; **schemas at external boundaries** ([§8.1](#81-boundary--purity))
14. **No silent fallback**; **idempotency** in side-effects ([§8.3](#83-failure-modes))
15. **Rule of Three**: don't abstract before the third repetition ([§8.4](#84-maintenance--evolution))

**Only 5 Hard gates** — the rest is Soft (reviewer agent) or Info. Details in [Enforcement Summary](#enforcement-summary).

---

## 1. Code Style

### Size

- **Functions: 4–20 lines.** Small functions because the AI refactors **subgraphs**, not monoliths — small function = local re-generation without regressing the surroundings. The minimum of 4 lines avoids trivial wrappers that pollute retrieval.
  - **Severity**: 🟡 Soft (heuristic — reviewer agent)
  - **Exception**: declarative tables (mappers, large switches where "1 line = 1 case") — don't fragment.
- **Files: under 500 lines in product code.** Fits in a single `Read` without `offset/limit`. Above 500, the AI starts losing invariants that fall outside the window.
  - **Severity**: 🔴 Hard
  - **Application**: code extensions (`.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.go`, `.rs`, `.rb`, `.java`, `.kt`, `.swift`, `.cs`, `.php`, `.sh`)
  - **Escape**: inline marker [`brainiac-allow-large`](#exception-mechanism-brainiac-allow-large) with justification
  - **Out**: see [Out of Scope](#out-of-scope)
  - **Legacy adoption (grace protocol)**: a pre-existing file with >500 lines in a project that just adopted Brainiac may receive `brainiac-allow-large` with a **traceable link** to a planned refactor:
    - `reason="legacy; split tracked in context/evolution/todo.md#<entry>"`
    - `reason="legacy; refactor planned in context/intent/refactor-*.md"`
    - `reason="legacy; ADR pending in context/decisions/NNN-*.md"`
    - **Without a traceable link the hook blocks.** "Legacy" alone is not a justification — requires a versioned exit plan.

### Responsibility

- **One thing per function, one responsibility per module (SRP).** Small blast radius: when the agent refactors a cohesive module, the change stays contained. A "god" module amplifies risk on every edit.
  - **Severity**: 🟡 Soft (reviewer agent)

### Names

- **Specific, unique, with <5 grep hits in the codebase.** Banned: `data`, `handler`, `Manager`, `Service`, `Util`, `Helper` when standalone (ok as a suffix when accompanied by a domain: `PaymentService`, `EmailHandler`).
  - **Severity**: 🟡 Soft (heuristic — reviewer agent)
- **Rename the file when responsibility changes.** A stable name with shifting responsibility is what most sabotages AI retrieval.

### Types

- **Explicit. No `any` (without justification), no bare `Dict`, no untyped functions.** Types become **carry-over context** between sessions.
  - **`any` severity**: 🔴 Hard. `: any` without an immediate justification comment is a block.
  - **Exact exception syntax (same-line marker)**: the comment `// brainiac:any-ok reason="..."` MUST be **on the same line** as `: any`. Reason is **mandatory** — without `reason="..."`, the hook blocks.

    ```ts
    // ✅ Accepted — same-line + reason
    function parseRaw(input: any) {  // brainiac:any-ok reason="boundary; runtime parsing before schema"
      return CheckoutSchema.parse(input);
    }

    // ❌ Blocked — comment on a different line
    function parseRaw(input: any) {
      // brainiac:any-ok reason="..."  // doesn't count — wrong line
      return CheckoutSchema.parse(input);
    }

    // ❌ Blocked — no reason
    function parseRaw(input: any) {  // brainiac:any-ok
      return CheckoutSchema.parse(input);
    }
    ```
- **Avoid `unknown` except at I/O boundaries.**
- **Schemas (Zod, Pydantic, Valibot) > manual types at external boundaries.**

### Control flow

- **Early returns.** Guard clauses are the most readable way to encode invariants.
- **Max 2 indentation levels.** Above 2, extract a function or invert the condition.

### Errors

- **Exception messages must include the offending value + expected shape.** E.g.: `Expected ISO date, got "2026/05/05" (use YYYY-MM-DD)`.

---

## 2. Comments

### Authorship

- **Distinguish human comments from agent comments.**
  - **Human** comments = invariant, irreproducible context. **Preserve** in refactor.
  - **Agent** comments (usually WHAT) = explanatory. **May be removed** in refactor if they became noise.
- Optional convention: `// AI:` or `# AI:` prefix on agent-generated comments. Without prefix, assume human.

### WHY, not WHAT

- **Skip `// increment counter` above `i++`.** The AI generates WHAT correctly.
- **WHY** = business constraint, architectural decision, workaround for a specific bug, behavior that would surprise the reader.

### Docstrings

- **On public functions: intent + 1 usage example.**

### References to Brainiac artifacts (scope: critical modules)

In **critical modules**, a header with references to framework artifacts is **expected** (Soft, reviewer agent insists).

**Definition of "critical module":**
- Auth and identity (login, session, RLS, permissions)
- Payments and billing
- Security boundaries (external input validation, sanitization, SSO)
- External integrations (Stripe, payment gateway, third-party APIs)
- Workarounds documented in an ADR
- Non-obvious decisions

Header pattern:

```ts
/**
 * Implements: context/intent/feature-checkout.md
 * Decision: context/decisions/003-payment-provider.md (Outcomes)
 * Pattern: context/knowledge/patterns/optimistic-update.md
 */
```

---

## 3. Tests

### Command

- **Tests run with a single command.** The exact command (project-specific) lives in the project's `AGENTS.md`.

### Coverage

- **Every new public behavior, domain rule, or boundary gets a test.**
- **Private helpers are covered by the behavior that uses them**, except for independent logic.
- **Every bugfix gets a regression test.**
  - **Severity**: 🔴 Hard via [`brainiac-qa-gate.sh`](https://github.com/kaleldias/Brainiac-Context/blob/main/integrations/claude-code/hooks/brainiac-qa-gate.sh).

### Mocks

- **Mock external I/O with named fake classes, not inline stubs.** A named fake is reusable context.

### F.I.R.S.T + R

| Letter | Meaning |
|---|---|
| **F**ast | Suite runs in seconds, not minutes |
| **I**ndependent | Each test runs isolated, no implicit ordering |
| **R**epeatable | Same input → same result, no flakes |
| **S**elf-validating | Pass/fail is obvious, no manual inspection |
| **T**imely | Written together with / before the code, not after |
| **R**eadable (by both humans and agents) | Name describes the scenario; explicit AAA layout |

### Test names = behavioral spec

The test name answers *"what is true when this test passes?"*. E.g.: `it('rejects checkout when cart total exceeds card limit')`, not `it('works')`.

---

## 4. Dependencies

- **Inject deps via constructor/parameter, not global/import.**
- **Wrap third-party libs behind a thin interface — explicit scope.** Not every lib needs a wrapper; over-wrapping becomes ceremonial architecture.

| Lib category | Wrap required? | Reason |
|---|---|---|
| **DB / ORM** (Drizzle, Prisma, raw SQL clients) | ✅ Yes | Critical I/O, provider switches happen |
| **Payments** (Stripe, Pagar.me, Mercado Pago) | ✅ Yes | External boundary, sensitive business logic |
| **Auth** (Supabase Auth, Auth0, Clerk) | ✅ Yes | Security boundary |
| **Storage** (S3, Supabase Storage, GCS) | ✅ Yes | I/O, provider switch possible |
| **External APIs** (third-parties, webhooks) | ✅ Yes | External boundary |
| **Queues / message brokers** (Redis, BullMQ, RabbitMQ) | ✅ Yes | Async I/O |
| **File processing** (pdf, image, audio) | ✅ Yes | I/O, lib switching common |
| **UI primitives** (shadcn, Radix, Headless UI) | ❌ No | No I/O |
| **Utility libs** (lodash, date-fns, zod) | ❌ No | Small, stable, idiomatic |
| **Type libs** (zod schemas as types) | ❌ No | Already thin interfaces |

- **Pin versions. Document the upgrade rationale in an ADR.**

---

## 5. Structure

- **Follow the framework convention** (Rails, Django, Next.js, Phoenix, etc.). Custom structure pays a **retrieval tax** indefinitely.
- **Predictable paths** reflect the **shape of `context/intent/`**: `feature-checkout.md` → `src/features/checkout/`.
- **No Limbo in code.** **Forbidden** `wip-*.ts`, `temp-*.ts`, `old-*.ts`, `unused-*.ts`, `legacy-*.ts`.
  - **Severity**: 🔴 Hard via hook (regex on filename)
- **One-Intent-per-folder when possible** (guideline, not dogma).

---

## 6. Formatting

- **Use the language default formatter**: `prettier`, `black`, `gofmt`, `cargo fmt`, `rubocop -A`, `ruff format`.
- **Pre-commit hook** runs the formatter automatically.
- **Broken lint/typecheck blocks phase completion.** Sensor (`tsc --noEmit`, `ruff check`, `eslint`) runs automatically at end of Build.
  - **Severity**: 🔴 Hard via sensor

---

## 7. Logging

- **Structured JSON** for debug/observability logs.
- **Plain text** only for user-facing CLI output.
- **Log levels with fixed semantics**:
  - `error` = invariant violated, page someone
  - `warn` = recoverable but worth looking at
  - `info` = flow milestone
  - `debug` = trace
- **Correlation ID in every request log.** Allows the AI to reconstruct flow via simple grep (`rg "req_abc123"`) instead of depending on an external trace tool.
  - **Propagate to external service calls** (`X-Request-ID` header in HTTP, `idempotencyKey` in Stripe, etc.) — enables `rg` cross-system when logs from multiple providers are accessible.

---

## 8. AI-First Specifics

Rules that **don't exist** in classical Clean Code because they only make sense when the reader/writer of the code is an agent.

### 8.1 Boundary & Purity

#### Boundary hygiene

Separate **I/O** (DB, API, filesystem, network) from **pure logic**. Pattern: pure core / imperative shell.

#### Pure functions preferred when applicable

#### Schemas at I/O boundaries

Zod/Pydantic/Valibot at **every** external entry point.

```ts
const CheckoutInput = z.object({
  cartId: z.string().uuid(),
  total: z.number().positive(),
});

export async function POST(req: Request) {
  const input = CheckoutInput.parse(await req.json());
  return checkoutPure(input);
}
```

#### Determinism in randomness/time

Every function that uses `Date.now()`, `Math.random()`, `crypto.randomUUID()` receives them via **injection** (parameter with default).

```ts
// Good
function makeOrder(now = Date.now, uuid = crypto.randomUUID) {
  return { id: uuid(), createdAt: now() };
}
```

### 8.2 Determinism

#### Determinism > cleverness

Prefer an explicit `for` loop to a chain of nested `reduce/map/filter` **when both solve the problem**. Hierarchy: clarity > concision.

### 8.3 Failure Modes

#### No silent fallback

Forbidden:

```ts
try { foo(); } catch { /* ignore */ }      // 🔴
const x = maybe ?? defaultValue;            // 🔴 in error path
async function load() {
  try { return await fetch(...); }
  catch { return []; }                       // 🔴 hides network error
}
```

If the fallback is semantically legitimate, a **WHY** comment is mandatory.

#### Idempotency in side-effects

Migrations, scripts, jobs, shell commands — all idempotent by default. Pattern: check-before-doing.

### 8.4 Maintenance & Evolution

#### Rule of Three

**Don't abstract before the third repetition.** Duplicate up to 3x; extract only on the 3rd.

#### Single source of truth for constants

Magic numbers and configuration strings live in **one** place.

---

## Out of Scope

Categories **explicitly out** because they have different invariants and a different cognitive unit:

| Category | Examples |
|---|---|
| **Markdown** | `*.md`, `*.mdx` (docs, specs, ADRs, intent files) |
| **SQL Migrations and dumps** | `*.sql` in `migrations/`, `*migration*.sql`, schema dumps |
| **Workflow JSON** | n8n, Make, Zapier, Temporal exports |
| **Schema files** | OpenAPI, GraphQL SDL, JSON Schema |
| **Generated types/code** | `*.gen.{ts,py,go,rs}`, drizzle output, codegen |
| **Lockfiles** | `package-lock.json`, `pnpm-lock.yaml`, `Cargo.lock` |
| **Declarative configs** | `tsconfig.json`, `*.yaml`, `*.toml`, `*.ini` |

### SQL — important distinction

| SQL type | Status |
|---|---|
| Migrations (`migrations/*.sql`) | ❌ Out of scope |
| Schema dumps (`*schema*.sql`) | ❌ Out of scope |
| **Stored procedures, functions, triggers** | ✅ **In scope** |
| Complex views with business logic | ✅ In scope |

---

## Exception Mechanism: `brainiac-allow-large`

When a rule **objectively applies** but the case is genuinely legitimate, declare an inline exemption with justification.

### Syntax

```ts
// brainiac-allow-large reason="<one-sentence justification>"
```

```python
# brainiac-allow-large reason="<one-sentence justification>"
```

```sql
-- brainiac-allow-large reason="<one-sentence justification>"
```

The hook reads the first occurrence (top-of-file marker, in the first 10 lines) and releases the file. **Reason is mandatory** — without `reason="..."`, the hook blocks.

### When to use

- Large declarative tables (mappers, switch-tables, constant lookups)
- Declarative schemas (inline OpenAPI, embedded GraphQL SDL)
- Tabular state machines
- Legitimate stored procedures
- Cohesive UI components

### When NOT to use

- ❌ "I didn't have time to split"
- ❌ "The AI generated it this way"
- ❌ "It works, leave it alone"

`agent-reviewer.md` in Learn Phase 1 checks **all** exemptions and questions weak reasons.

---

## 9. Canonical Markdown Schema

> **Added in Standards-Version 1.1** (2026-05-21). Full specification in the canonical [`CODE_STANDARDS.md` §9](https://github.com/kaleldias/Brainiac-Context/blob/main/CODE_STANDARDS.md#9-canonical-markdown-schema). Enforcement implementation is **F2** of the F1–F4 refactor.

The Brainiac framework operates over `context/**` markdown artefacts (ADRs, Patterns, Anti-patterns, Intents, Standards). The brainiac-nav UI and the lint Plane C rely on a **stable structural contract** to render and audit these docs. Standards-Version 1.1 formalizes that contract as 9 conventions.

### TL;DR — 9 conventions

1. **H1 format** (Hard) — `# ADR-NNN — <Title>` / `# Pattern: <Title>` / `# Anti-pattern: <Title>` / `# <Tipo> Intent — <Title>` / `# <Project> — <CODE|SECURITY>_STANDARDS`.
2. **Metadata block** (Hard) — bullets `- **Key:** value` immediately after H1; field set fixed per class. Optional YAML frontmatter allowed in addition.
3. **Thematic break `---`** (Hard) — never inside an H2 section; permitted between H2s and after metadata block.
4. **H2 ordering** (Hard) — fixed canonical order per artefact class.
5. **H3 inside H2 first-class** (Soft) — permitted for sub-cards.
6. **Status history schema** (Hard) — table columns fixed: `[Timestamp, Status, Reason]`.
7. **Related sub-bullets** (Soft) — canonical sub-bullets: Intent, ADRs, Patterns, Anti-patterns, Buglog.
8. **Slug → variant table** (Soft) — single-source-of-truth mapping H2 slugs to Lucide icons + variants.
9. **Timestamp format** (Hard) — `YYYY-MM-DD HH:mm UTC±HH:MM` (reaffirms ADR-004).

### Hardness distribution

- **5 Hard rules**: enforced via templates + skills + reviewer agent + `brainiac-context-lint` schema checks (F2).
- **4 Soft rules**: reviewer agent flags; F3 implementation references for slug→variant.

Preserves the "5 Hard gates philosophy" of CODE_STANDARDS — universal contract stays lean; richness lives in the canonical reference + reviewer agent.

---

## Enforcement Summary

### 🔴 Hard gates (5 rules — blocking)

| Rule | Mechanism | Current Status |
|---|---|---|
| `: any` in TS without justification (with `reason="..."`) | `brainiac-clean-code-gate.sh` (regex validates marker + reason) | ✅ Implemented in v1.11 |
| Filenames `wip-*`, `temp-*`, `old-*`, `unused-*`, `legacy-*` | `brainiac-clean-code-gate.sh` (regex on path) | ✅ Implemented in v1.11 |
| Bugfix without referenced regression test | `brainiac-qa-gate.sh` | ✅ Implemented (advisory v1.4.0+; Hard via Learn Phase 1) |
| File >500 lines in product code | `brainiac-clean-code-gate.sh` (`wc -l` + extension) with `brainiac-allow-large reason="..."` | ✅ Implemented in v1.11 |
| Broken lint/typecheck on touched files | Sensor (`tsc --noEmit` / `eslint` / `ruff`) listed in `context/sensors/sensors.md` | 📋 Manual today (run by Build skill); automatic sensor in v1.12+ |

> **Runtime prerequisite**: Hard gates 1, 2, 4 depend on Claude Code hooks installed via `integrations/claude-code/install.sh`. Without those, the rules apply as Soft (reviewer agent enforces).

### 🟡 Soft (reviewer agent in Learn Phase 1)

Functions 4–20 lines; SRP; names <5 grep hits; specific names (banned standalone); `unknown` only at boundary; schemas at I/O boundaries; early returns; rich error messages; WHY-not-WHAT comments; Brainiac refs in critical modules; public behavior / domain / boundary has a test; named fakes; F.I.R.S.T + R; inject deps; wrap third-party (listed categories); pin versions; framework convention; predictable paths; structured logs; log levels; correlation ID; boundary hygiene; schemas at boundaries; determinism in time/randomness; no silent fallback; idempotency; Rule of Three; single source of truth.

### 🔵 Info (suggestion for Learn step)

Pure functions preferred; determinism > cleverness; co-location of Intent ref (non-critical modules).

---

## Project-Specific Overrides

> Preenchido no bootstrap via archeology pass (Confidence: 🟢 High salvo indicado). Projeto acadêmico stdlib-only.

### Stack

| Aspect | Project convention |
|---|---|
| Language | Python 3 |
| Framework | Nenhum — stdlib pura (`socket`, `threading`, `json`, `struct`, `sys`, `time`) |
| Database | Nenhum (proibido estado compartilhado — Operational Rule 1) |
| Auth | N/A |
| UI primitives | Terminal (CLI) |
| Styling | N/A |
| Tests | Nenhum ainda (🟡 considerar `pytest` conforme matura) |
| Formatter | Nenhum configurado (🟡 sugerir `black` se adotado) |
| Linter | Nenhum configurado (🟡 sugerir `ruff`/`flake8` — pegaria o `E722` já existente) |

### Code Style — local overrides

- **Quotes:** predominância de aspas duplas no código atual — manter consistência.
- **Imports:** somente stdlib, no topo do arquivo.
- **Naming:** `snake_case` para funções/variáveis, `UPPER_CASE` para constantes de módulo (`MULTICAST_GROUP`, `MULTICAST_PORT`).
- **Files:** `snake_case.py`.
- **Idioma:** strings de UI e mensagens ao usuário em **pt-BR** (convenção do projeto).

### Additional Hard gates (project-specific)

| Rule | Severity | Reason |
|---|---|---|
| Proibido estado compartilhado entre nós (memória/BD/arquivo comum) como canal de coordenação | 🔴 Hard | Regra §2 do enunciado — viola o trabalho. Só `nos.json` estático é permitido |
| Nº de nós NÃO pode ser hardcoded | 🔴 Hard | R3 exige configurável ≥15 sem alterar código |

### Additional Soft gates (reviewer enforces)

- Sem `except:` nu — capturar tipo específico ou `except Exception as e` (ver anti-pattern `bare-except-error-swallow`).
- Estruturas compartilhadas internas (buffer de delivery, relógio vetorial) protegidas por lock.
- Tratar não-confiabilidade UDP na camada de ordenação (perda/duplicação/reordenação).

### Tests

- **Run:** sem suíte automatizada ainda. Sensor mínimo: `python -m py_compile multicast.py`.
- **Smoke:** `pwsh ./run.ps1` ou 3+ terminais `python multicast.py <id>` — ver `context/sensors/sensors.md`.
- **Mock pattern:** N/A.

### Logging

- **Structured:** N/A — saída via `print` para terminal (aceitável no escopo acadêmico).
- **Correlation ID:** `process_id` já identifica a origem nas mensagens.

### Wrap third-party — this project's scope

| Lib | Wrap required? | Where |
|---|---|---|
| — (nenhuma dependência externa) | N/A | N/A |

---

## Standards Version Compatibility

Pinned to **Standards-Version 1.1** of the framework (adds Canonical Markdown Schema as §9 — see [ADR-016](./decisions/016-standards-version-bump-canonical-markdown-schema.md) when available locally).

To update when the framework versions: run `/brainiac-context-update` — the reviewer agent will diff and propose changes, recorded in an ADR in `context/decisions/`.

## Last Audit

- **Date:** pending first reviewer agent run
- **Reviewer agent verdict:** pending
