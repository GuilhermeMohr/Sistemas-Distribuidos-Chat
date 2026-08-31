# TODO — Sistemas-Distribuidos-Chat

Project backlog. Tracked items beyond active intents (research debt, follow-ups, future ADRs).

## Decisões fechadas (2026-08-31)

- [x] [[decisions/0005]] **Ordem total → Abordagem A** + ACK de estabilidade + hold-back queue (multicast totalmente ordenado do Lamport). B descartada.
- [x] [[decisions/0006]] **Estado global → Chandy-Lamport** (canais lógicos por origem sobre o grupo multicast).

## Build em andamento — ver [[intent/feature-ordem-total]] (ordem CP1→CP5)

- [ ] **CP1 — Infra (R3 + dívida técnica):** `nos.json` + `node_ids`; vetor com N posições; `message_id`=`origin:seq`; campo `type`; `recvfrom(65536)`; `state_lock`; threads `daemon=True` + shutdown; `except:`→`except Exception`; `run.ps1` parametrizado (`-Nodes`). ⬅️ **próximo**
- [ ] **CP2 — Ordem total (R4/§5.3):** `holdback_queue`, `total_key`, `ACK` (envio+recepção, emissor conta), `acks`, `try_deliver` (topo + ACK de todos), `delivery_order`, dedup + detecção de lacuna. ⚠️ NÃO entregar por sort sozinho — ver [[knowledge/anti-patterns/total-order-sort-without-stability]].
- [ ] **CP3 — Tela (R5):** menu; mostrar relógio vetorial, ordem local, ordem global, buffer.
- [ ] **CP4 — Snapshot (R6/§5.5):** `MARKER`, estado local + canais lógicos, término com MARKER de todos; comando de menu.
- [ ] **CP5 — Testes:** 3/8/15 nós; cenário concorrente (filas idênticas) + cenário causal.
- [ ] **R7** — Relatório da Entrega 1 (§10): derivar dos artefatos `context/` + `PROJECT_STATUS.md`.

### Já concluído
- [x] **R4/§5.2** — Relógio vetorial + entrega causal (`can_deliver`) (commit `faf894c`).
- [x] **R5 (unicast)** — Envio p/ nó específico via `receiver` (commit `8046d24`).
- ⚪ **R8** — eleição de líder: **fora de escopo** (Abordagem A não usa líder).

## Legacy debt (archeology pass — 2026-08-26)

- [ ] Corrigir `except:` nu em `write()` (`multicast.py:119`) — ver [[knowledge/anti-patterns/bare-except-error-swallow]].
- [ ] Threads não-daemon com `while True` sem shutdown gracioso — ver [[knowledge/anti-patterns/non-daemon-threads-no-shutdown]].
- [ ] **Estado compartilhado sem lock:** `buffer` e `vectorial_time` são lidos/escritos pelas threads de recepção e escrita sem `threading.Lock` — risco de race condition (viola Operational Rule 4 e ADR-0004). Proteger com lock.
- [ ] Envelope JSON: já tem `id/message/receiver/vectorial_time`; avaliar `seq` (sequência por origem) para detecção de lacunas UDP — ver [[decisions/0003]].
- [ ] Buffer fixo `recvfrom(1024)` — validar tamanho vs mensagens com vetor de 15+ posições; enunciado sugere 65536.
- [ ] Tratar não-confiabilidade UDP (perda/duplicação/reordenação) na camada de ordenação — Operational Rule 5.

## Infra / Segurança (não-bloqueante)

- [ ] `.gitignore` criado no bootstrap — revisar cobertura Python.
- [ ] [SEC] Documentar no relatório (§10.6) que o tráfego multicast é não-cifrado/não-autenticado (limitação inerente ao trabalho, não defeito).
- [x] Camada operacional GitHub aplicada (2026-08-28): labels canonical (8 famílias) + 5 labels `area:*` do projeto, templates `.github/` (issue/PR + branch-policy), bloco GitHub Operational Protocol no AGENTS.md.
- [ ] **GitHub Project** (Kanban Brainiac) — pulado no bootstrap (overhead p/ time acadêmico). Criar depois se o time quiser board.
- [ ] **Branch protection em `main`** — requer permissão **ADMIN** (só o dono `GuilhermeMohr` tem; sou WRITE). Guilherme deve aplicar via `/brainiac-context-github` ou nas settings do repo. Nota: hoje o time faz push direto em `main`; ativar proteção exige migrar p/ fluxo de PR.
