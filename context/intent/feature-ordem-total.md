# Feature Intent — Ordem total, infraestrutura de nós e estado global

- **Status:** Ready for Build
- **Criado:** 2026-08-31 19:08 UTC-03:00
- **Requisitos cobertos:** R3, R4, R5, R6 (R8 fora de escopo — sem líder)
- **Decisões:** [[decisions/0005]] (ordem total — Abordagem A + ACK), [[decisions/0006]] (estado global — Chandy-Lamport)

## Objetivo

Levar o projeto de "ordem causal" para **ordem total** demonstrável e **estado global** (snapshot Chandy-Lamport), com nº de nós configurável ≥15, reescrevendo `multicast.py` para separar **protocolo / ordenação / snapshot / UI**.

## Por que reescrever (em vez de patch)

O `multicast.py` atual (140 linhas) mistura recepção, ordenação causal e UI, com estado compartilhado sem lock. A ordem total (hold-back + ACK) e o snapshot precisam de uma infra comum (configuração de membros, `message_id`, tipos de mensagem, lock, estado local separado da entrega). Reescrever reduz retrabalho e deixa o relatório defensável. Ver [[decisions/0004]].

## Arquitetura alvo

```
recvfrom(65536) → parse JSON → dispatch por type
   ├─ DATA   → process_data()  → holdback_queue → try_deliver()
   ├─ ACK    → process_ack()   → acks           → try_deliver()
   └─ MARKER → process_marker() → snapshot (Chandy-Lamport)
try_deliver(): entrega quando topo(total_key) E ACK de todos node_ids
```

Estruturas (protegidas por um único `state_lock`, exceto I/O e `print`):
`node_ids`, `vectorial_time`, `holdback_queue`, `received_ids`, `acks`, `delivered_ids`, `delivery_order`, e estado de snapshot.

Envelope: `type` (DATA|ACK|MARKER), `id` (origem), `message_id` = `"origin:seq"` (`seq = V[origin]`), `message`, `receiver` (0=grupo), `vectorial_time`.

Chave total: `total_key(m) = (sum(V.values()), int(origin), V[origin])`. **Estabilidade obrigatória via ACK** — ver anti-pattern [[knowledge/anti-patterns/total-order-sort-without-stability]].

## Plano de implementação (checkpoints)

- **CP1 — Infra de transporte/estado:** `nos.json` (grupo/porta/lista de nós) + `node_ids`; `vectorial_time` nasce com todas as N posições; `message_id`; campo `type`; `recvfrom(65536)`; `state_lock`; threads `daemon=True` + shutdown básico; `except:` nu → `except Exception`; `process_id` string, `int()` só para ordenar.
- **CP2 — Ordem total:** `holdback_queue`, `total_key()`, `ACK` (envio + recepção, emissor conta como ACK), `acks`, `try_deliver()` (topo + ACK de todos), `delivered_ids`, `delivery_order`. Dedup via `received_ids`; detecção de lacuna (segurar `origin:seq` fora de ordem).
- **CP3 — Tela (R5):** menu com enviar unicast/grupo, mostrar relógio vetorial, **ordem local**, **ordem global** (delivery_order), buffer.
- **CP4 — Snapshot (R6):** `MARKER`, estado local + estado de canais lógicos (por origem), término quando MARKER de todos; comando de menu p/ iniciar e exibir.
- **CP5 — Testes:** cenários com 3, 8 e 15 nós; caso de mensagens concorrentes provando filas de delivery idênticas; caso de dependência causal.

## Critério de aceitação (corretude — §8)

Ao final de uma simulação, **as filas de delivery ordenadas (ordem global) devem ser idênticas em todos os nós**. Exemplo numérico (2–3 nós, mensagens concorrentes convergindo à mesma ordem) documentado no relatório (§10.8).

## Fora de escopo

- Eleição de líder / sequenciador (R8) — não adotado (Abordagem A).
- Recuperação/retransmissão de mensagens perdidas em UDP — documentado como limitação (§10.6); há apenas dedup + detecção de lacuna.

## Dívida técnica endereçada

Lock em estado compartilhado, `except:` nu, threads não-daemon, `recvfrom(1024)→65536`, id string vs numérico — ver `context/evolution/todo.md`.
