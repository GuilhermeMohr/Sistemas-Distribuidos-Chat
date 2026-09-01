# TODO — Sistemas-Distribuidos-Chat

Project backlog. Tracked items beyond active intents (research debt, follow-ups, future ADRs).

## Decisões fechadas (2026-08-31)

- [x] [[decisions/0005]] **Ordem total → Abordagem A** + ACK de estabilidade + hold-back queue (multicast totalmente ordenado do Lamport). B descartada.
- [x] [[decisions/0006]] **Estado global → Chandy-Lamport** (canais lógicos por origem sobre o grupo multicast).

## Build em andamento — ver [[intent/feature-ordem-total]] (ordem CP1→CP5)

- [x] **CP1 — Infra (R3 + dívida técnica):** `nos.json` + `node_ids`; vetor com N posições; `message_id`=`origin:seq`; campo `type`; `recvfrom(65536)`; `state_lock` + `SO_REUSEPORT`; threads `daemon=True` + shutdown (`Event`); `except Exception`; `run.ps1 -Nodes`. (PR #1)
- [x] **CP2 — Ordem total (R4/§5.3):** `total_key` + hold-back + condição de estabilidade **corrigida** (ADR-0008: "ouvi-maior-de-todos" em FIFO + heartbeats; ACKs removidos). Validado com 3/8/15 nós e perda 30%/50%. (PR #1, corrigido em issue #5)
- [x] **CP3 — Tela (R5):** menu com envio unicast/grupo, relógio vetorial, ordem local, ordem global. (PR #1)
- [x] **CP4 — Snapshot (R6/§5.5):** `MARKER`, estado local + canais lógicos por origem, término com MARKER de todos; menu 6 (iniciar) e 7 (mostrar). Validado com 3 e 8 nós reais. (PR #2)
- [x] **CP5 — Testes:** `test_ordem_total.py` (concorrente/causal/duplicata/**snapshot**) + orquestradores reais 3/8/15 nós.
- [~] **R7** — Relatório da Entrega 1 (§10): **rascunho gerado** em `RELATORIO.md` (e `~/Downloads`). Falta a equipe: (a) confirmar nomes/papéis §10.2; (b) inserir prints das filas de delivery; (c) revisão final antes de submeter no AVA (09/09).

### Já concluído
- [x] **R4/§5.2** — Relógio vetorial + entrega causal (`can_deliver`) (commit `faf894c`).
- [x] **R5 (unicast)** — Envio p/ nó específico via `receiver` (commit `8046d24`).
- ⚪ **R8** — eleição de líder: **fora de escopo** (Abordagem A não usa líder).

## Legacy debt (archeology pass — 2026-08-26) — resolvido no Build CP1/CP2 (PR #1)

- [x] `except:` nu → `except Exception`/`except OSError` (ver [[knowledge/anti-patterns/bare-except-error-swallow]]).
- [x] Threads não-daemon sem shutdown → `daemon=True` + `stop_event` + `socket.close()` (ver [[knowledge/anti-patterns/non-daemon-threads-no-shutdown]]).
- [x] Estado compartilhado sem lock → `Node` com `threading.Lock` único (ver [[decisions/0004]]).
- [x] `seq` por origem no envelope (`message_id=origin:seq`) + dedup + FIFO por origem.
- [x] `recvfrom(1024)` → `recvfrom(65536)`.
- [x] Não-confiabilidade UDP: dedup + hold-back + **retransmissão por NACK** (perda de DATA e ACK) — [[decisions/0007]] / [[knowledge/patterns/reliable-multicast-nack-retransmission]]. Validado com 30% e 50% de perda. Limites restantes: queda da origem e MARKER perdido no snapshot (documentar §10.6).

## Infra / Segurança (não-bloqueante)

- [ ] `.gitignore` criado no bootstrap — revisar cobertura Python.
- [ ] [SEC] Documentar no relatório (§10.6) que o tráfego multicast é não-cifrado/não-autenticado (limitação inerente ao trabalho, não defeito).
- [x] Camada operacional GitHub aplicada (2026-08-28): labels canonical (8 famílias) + 5 labels `area:*` do projeto, templates `.github/` (issue/PR + branch-policy), bloco GitHub Operational Protocol no AGENTS.md.
- [ ] **GitHub Project** (Kanban Brainiac) — pulado no bootstrap (overhead p/ time acadêmico). Criar depois se o time quiser board.
- [ ] **Branch protection em `main`** — requer permissão **ADMIN** (só o dono `GuilhermeMohr` tem; sou WRITE). Guilherme deve aplicar via `/brainiac-context-github` ou nas settings do repo. Nota: hoje o time faz push direto em `main`; ativar proteção exige migrar p/ fluxo de PR.
