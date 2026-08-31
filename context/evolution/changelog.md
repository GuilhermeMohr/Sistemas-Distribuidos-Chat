# Changelog — Sistemas-Distribuidos-Chat

All notable changes are documented here. Follows milestones only (L3 policy).

## [Unreleased]

### Added
- **2026-08-26** — Brainiac Context adotado no projeto (via `/brainiac-context-existing`). Estrutura `context/` criada por inferência retroativa (archeology pass) sobre o código existente: 4 ADRs Accepted (multicast, Python stdlib, envelope JSON, threading), 2 ADRs Proposed (ordem total, estado global), 2 patterns, 2 anti-patterns, intent com requisitos R1–R8, code/security standards e harness de agents (Core + Extended).

### Added
- **2026-08-28** — Camada operacional GitHub (Brainiac Protocol) aplicada: labels canonical (8 famílias) + 5 labels `area:*` (networking/ordering/global-state/concurrency/report), templates `.github/` (issue templates, PR template, workflow branch-policy + scripts) e bloco "GitHub Operational Protocol" no AGENTS.md. Pulados (registrados em todo): GitHub Project e branch protection (este requer ADMIN — só o dono do repo).

### Decided
- **2026-08-31** — Fechadas as 2 decisões centrais (com revisão técnica externa): [[decisions/0005]] **ordem total = Abordagem A + ACK de estabilidade + hold-back queue** (multicast totalmente ordenado do Lamport; B descartada, sem líder); [[decisions/0006]] **estado global = Chandy-Lamport** (canais lógicos por origem). Criados: intent `feature-ordem-total.md` (plano CP1→CP5) e anti-pattern `total-order-sort-without-stability`.

### Changed
- **2026-08-28** — Sincronizado com o trabalho do Guilherme (commits `8046d24` unicast por `receiver`, `faf894c` relógio vetorial + entrega causal). Context reconciliado: R5 unicast e R4/§5.2 (ordem causal) marcados como parciais-concluídos; ADR-0003 (envelope estendido com `receiver`+`vectorial_time`) e ADR-0005 atualizadas; novo pattern `causal-delivery-vector-clock-buffer`; dívida de lock em estado compartilhado registrada. Pendências confirmadas com a equipe: §5.3 ordem total e §5.5 estado global.
