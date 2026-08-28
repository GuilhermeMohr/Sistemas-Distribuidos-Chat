# ADR-0003 — Envelope de mensagem em JSON

- **Created:** 2026-08-26 22:54 UTC-03:00
- **Last updated:** 2026-08-28 00:00 UTC-03:00
- **Status:** Accepted
- **Decision-makers:** equipe (inferido via archeology pass — Confidence 🟢 High)

## Context

Os nós precisam serializar mensagens para trafegar por UDP e identificar o remetente (para filtrar o próprio eco e, futuramente, aplicar ordenação). O enunciado (§6) sugere JSON com campos como `tipo`, `origem`, `destino`, `vetor`, `seq`, `payload`.

**Source of inference:** `multicast.py:59-62` monta `{"id": process_id, "message": input()}`; `broadcast()` faz `json.dumps(...).encode("utf-8")` (`multicast.py:70`); recepção faz `json.loads(data.decode("utf-8"))` (`multicast.py:47`).

## Decision

Usar **JSON** como formato de envelope das mensagens, serializado em UTF-8. Envelope atual (após commit `faf894c`): `{"id": <process_id>, "message": <texto>, "receiver": <0=grupo | id do destino>, "vectorial_time": {<id>: <contador>}}`.

> **Evolução (2026-08-28):** o envelope foi estendido além do mínimo — ganhou `receiver` (endereçamento unicast/grupo, R5) e `vectorial_time` (relógio vetorial, R4/§5.2). Dívida restante: avaliar campo `seq` (sequência por origem) para detecção de lacunas sob perda UDP. Rastreado em `context/evolution/todo.md`.

## Alternatives considered

### Alternativa A — JSON (escolhida)
**Pró:** legível, nativo na stdlib (`json`), extensível para novos campos, sugerido pelo enunciado. **Contra:** overhead de texto vs binário (irrelevante nesta escala).

### Alternativa B — Serialização binária (`struct`/`pickle`)
**Pró:** compacto. **Contra:** `pickle` é inseguro e frágil entre versões; `struct` manual é trabalhoso e pouco extensível. Rejeitada.

## Consequences

### Positive

- Fácil depuração (mensagens legíveis) e extensão para campos de ordenação.

### Negative

- Envelope atual insuficiente para ordenação total — precisa evoluir. Mitigação: estender no Build de R4 (ver todo).

## Outcomes

**Outcomes recorded:** —

## Related

- **Intent:** `context/intent/project-intent.md` (R4, R5)
- **ADRs:** `context/decisions/0001-comunicacao-grupo-multicast-udp.md`, `context/decisions/0005-ordem-total-abordagem.md`
- **Patterns:** `context/knowledge/patterns/own-echo-filter.md`
- **Anti-patterns:** *nenhum*
- **Buglog:** *nenhum*

## Status history

| Timestamp | Status | Reason |
|---|---|---|
| 2026-08-26 22:54 UTC-03:00 | Accepted | Decisão já implementada (envelope mínimo); extensão pendente registrada em todo |
| 2026-08-28 00:00 UTC-03:00 | Accepted | Envelope estendido com `receiver` (R5) e `vectorial_time` (R4/§5.2) no commit `faf894c` |
