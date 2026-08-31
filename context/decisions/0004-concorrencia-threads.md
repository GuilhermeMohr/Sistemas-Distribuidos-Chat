# ADR-0004 — Modelo de concorrência com threads (rede / entrega / UI)

- **Created:** 2026-08-26 22:54 UTC-03:00
- **Last updated:** 2026-08-31 19:08 UTC-03:00
- **Status:** Accepted
- **Decision-makers:** equipe (inferido via archeology; consolidado no Build CP1)

## Context

Cada nó precisa, simultaneamente, escutar a rede e permitir que o usuário envie mensagens. O enunciado (§7) recomenda usar threads (ou asyncio) para separar (a) escuta de rede, (b) processamento/entrega ordenada e (c) interface de usuário, protegendo estruturas internas com locks.

**Source of inference:** `multicast.py:75-79` cria uma thread para `receive_multicast` e outra para `write`, sobre o mesmo socket. Confidence Medium porque o modelo atual tem apenas 2 threads (rede + UI), **sem** a camada dedicada de entrega ordenada nem locks — que serão necessários para R4.

## Decision

Adotar **concorrência baseada em `threading`** dentro de cada processo-nó, com threads separadas por responsabilidade.

> **Consolidado no Build (CP1, 2026-08-31):** duas threads — recepção (`receive_loop`, `daemon=True`) e UI/menu (thread principal). Todo o estado compartilhado (`holdback_queue`, `acks`, `vectorial_time`, `delivery_order`, ...) vive na classe `Node` e é protegido por um único `threading.Lock` interno; I/O (`recvfrom`, `sendto`) e `input()`/`print` ficam **fora** do lock. Encerramento gracioso via `threading.Event` (`stop_event`) + `socket.close()`. Isto resolve a dívida de "estado compartilhado sem lock" e "threads não-daemon sem shutdown".

## Alternatives considered

### Alternativa A — threading (escolhida)
**Pró:** modelo simples e direto para I/O bloqueante de socket; recomendado pelo enunciado. **Contra:** exige locks para estado compartilhado interno (GIL não protege invariantes compostas).

### Alternativa B — asyncio
**Pró:** concorrência cooperativa sem locks explícitos. **Contra:** reescrita do I/O em corrotinas; curva maior para a equipe. Rejeitada por ora.

## Consequences

### Positive

- I/O de rede não bloqueia a UI e vice-versa.

### Negative

- Ao introduzir buffer de delivery e relógio vetorial (R4), o acesso concorrente precisa de locks — risco de race conditions se ignorado. Mitigação: proteger estruturas compartilhadas; ver Operational Rule 4 em `AGENTS.md`.
- Threads atuais são não-daemon e sem shutdown gracioso. Ver `context/knowledge/anti-patterns/non-daemon-threads-no-shutdown.md`.

## Outcomes

**Outcomes recorded:** —

## Related

- **Intent:** `context/intent/project-intent.md` (R4, R6)
- **ADRs:** *nenhuma*
- **Patterns:** *nenhum*
- **Anti-patterns:** `context/knowledge/anti-patterns/non-daemon-threads-no-shutdown.md`
- **Buglog:** *nenhum*

## Status history

| Timestamp | Status | Reason |
|---|---|---|
| 2026-08-26 22:54 UTC-03:00 | Provisional | Modelo parcialmente implementado (rede+UI); camada de entrega ordenada + locks ainda pendentes |
| 2026-08-31 19:08 UTC-03:00 | Accepted | Build CP1: `Node` com lock único, threads daemon, shutdown via Event; dívida de concorrência resolvida |
