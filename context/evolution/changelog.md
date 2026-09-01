# Changelog — Sistemas-Distribuidos-Chat

All notable changes are documented here. Follows milestones only (L3 policy).

## [Unreleased]

### Added
- **2026-08-26** — Brainiac Context adotado no projeto (via `/brainiac-context-existing`). Estrutura `context/` criada por inferência retroativa (archeology pass) sobre o código existente: 4 ADRs Accepted (multicast, Python stdlib, envelope JSON, threading), 2 ADRs Proposed (ordem total, estado global), 2 patterns, 2 anti-patterns, intent com requisitos R1–R8, code/security standards e harness de agents (Core + Extended).

### Added
- **2026-08-28** — Camada operacional GitHub (Brainiac Protocol) aplicada: labels canonical (8 famílias) + 5 labels `area:*` (networking/ordering/global-state/concurrency/report), templates `.github/` (issue templates, PR template, workflow branch-policy + scripts) e bloco "GitHub Operational Protocol" no AGENTS.md. Pulados (registrados em todo): GitHub Project e branch protection (este requer ADMIN — só o dono do repo).

### Added
- **2026-08-31** — **Rascunho do relatório técnico (R7)** gerado em `RELATORIO.md` seguindo a estrutura §10 (problema, papéis, arquitetura+diagrama, endereços, simulações, limitações, tecnologia, passo a passo da ordem total com exemplo numérico, justificativa do estado global). Pendente: nomes/papéis da equipe (§10.2), prints das simulações e revisão final.
- **2026-08-31** — **Estado global (R6/§5.5)** implementado (CP4, PR #2): snapshot de Chandy-Lamport com `MARKER` e canais lógicos por origem sobre o grupo multicast; menu opções 6 (iniciar) e 7 (mostrar). Validado com 3 e 8 nós reais (todos concluem, estado consistente). Patterns capturados: `totally-ordered-multicast-ack-holdback` e `chandy-lamport-snapshot-multicast`.
- **2026-08-31** — **Ordem total (R4/§5.3) + infra de nós (R3) + tela (R5)** implementados (branch `feat/1-ordem-total`, PR #1). Reescrita de `multicast.py` com classe `Node` (protocolo/ordenação/UI separados): relógio vetorial + `total_key` + ACK de estabilidade + hold-back queue; `nos.json` + `run.ps1 -Nodes`; menu com ordem local/global; lock único, threads daemon, shutdown, `SO_REUSEPORT`, `recvfrom(65536)`. Validado: `test_ordem_total.py` (concorrente/causal/duplicata) + teste real de multicast com **3 e 15 nós** — ordem global idêntica em todos. Dívida técnica do archeology pass resolvida.

### Decided
- **2026-08-31** — Fechadas as 2 decisões centrais (com revisão técnica externa): [[decisions/0005]] **ordem total = Abordagem A + ACK de estabilidade + hold-back queue** (multicast totalmente ordenado do Lamport; B descartada, sem líder); [[decisions/0006]] **estado global = Chandy-Lamport** (canais lógicos por origem). Criados: intent `feature-ordem-total.md` (plano CP1→CP5) e anti-pattern `total-order-sort-without-stability`.

### Changed
- **2026-08-28** — Sincronizado com o trabalho do Guilherme (commits `8046d24` unicast por `receiver`, `faf894c` relógio vetorial + entrega causal). Context reconciliado: R5 unicast e R4/§5.2 (ordem causal) marcados como parciais-concluídos; ADR-0003 (envelope estendido com `receiver`+`vectorial_time`) e ADR-0005 atualizadas; novo pattern `causal-delivery-vector-clock-buffer`; dívida de lock em estado compartilhado registrada. Pendências confirmadas com a equipe: §5.3 ordem total e §5.5 estado global.
