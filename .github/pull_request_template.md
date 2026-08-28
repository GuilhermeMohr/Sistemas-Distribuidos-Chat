<!--
Brainiac PR template — DO NOT remove the structured sections.
Customize content; keep the structure so agent-reviewer.md and human reviewers
can locate evidence consistently.
-->

## Summary

Direct summary of the change.

## Linked Issues

Closes #<issue-number>

## Brainiac Context

- Intent: `context/intent/<feature|bug|refactor>-*.md`
- ADR: `context/decisions/NNN-*.md` (if applicable)
- Pattern: `context/knowledge/patterns/*.md` (if applicable)
- QA Gate: `context/qa/<run-id>.md` (if applicable)
- Buglog: `context/evolution/buglog.md` (if bugfix)
- Code Standards: `context/code-standards.md` (Standards-Version: <X.Y>)

## Context

Why does this change exist?

## Changes

-
-
-

## Out of scope

-
-

## Validation

- [ ] Sensors executed (`tsc --noEmit` / `eslint` / `ruff` / etc.)
- [ ] Local tests executed
- [ ] Smoke test executed
- [ ] Lint/typecheck clean (Hard gate 5)
- [ ] Regression/eval executed, if applicable
- [ ] Evidence attached

## Phase 1 Quality Gate (agent-reviewer.md output)

- 🔴 Block findings: <count> (must be 0 to merge)
- 🟡 Soft findings: <count> (human-decided)
- 🔵 Info findings: <count> (feed Phase 2 Learn)
- Exemptions reviewed:
  - `brainiac-allow-large` markers: <count>, all with `reason="..."`
  - `brainiac:any-ok` markers: <count>, all with `reason="..."`

## Evidence

- Logs:
- Run ID:
- Batch ID:
- Workflow execution:
- DB evidence:
- Screenshots:

## Phase 2 Learn Gate

- [ ] Intent updated (Status, Acceptance Criteria checked)
- [ ] Buglog updated, if bugfix
- [ ] ADR updated with Outcomes, if decision changed during Build
- [ ] Pattern/anti-pattern updated, if reusable learning emerged
- [ ] QA gate created/updated, if relevant validation
- [ ] Skip declared with reason, if nothing required updating

## Risks

-

## Follow-ups

(Create new issues for any follow-up — do not leave only as a comment.)

-

## Checklist

- [ ] Issue linked with `Closes #<issue-number>`
- [ ] Branch follows pattern `<type>/<issue-number>-<short-scope>`
- [ ] Small, conventional commits (Conventional Commits format)
- [ ] No hardcoded secrets, tokens, or credentials
- [ ] No out-of-scope changes
- [ ] PR is small and reviewable
- [ ] Ready for review only after validation (sensors + Phase 1 Quality Gate)

## Worktree accounting

<!-- Preencher ao marcar Ready for Review. Worktree e o isolamento padrao;
     opt-out em mudanca trivial e legitimo mas deve ser declarado aqui. -->

- Worktree usada: `<path>` (ou: opt-out declarado, motivo: `<...>`)
- [ ] `cleanup --check` aprovado, ou trabalho pendente justificado acima
- [ ] Destino da branch definido (merge ou descarte autorizado explicitamente)

> Remover a worktree NAO remove a branch: sao operacoes distintas.
