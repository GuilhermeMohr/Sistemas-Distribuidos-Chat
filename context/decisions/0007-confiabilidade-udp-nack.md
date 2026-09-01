# ADR-0007 — Confiabilidade sobre UDP via retransmissão por NACK

- **Created:** 2026-08-31 22:00 UTC-03:00
- **Last updated:** 2026-08-31 22:00 UTC-03:00
- **Status:** Accepted
- **Decision-makers:** equipe + revisão técnica externa — Confidence 🟢 High

## Context

O transporte é multicast UDP (ver [[decisions/0001]]), que não garante entrega — pode **perder**, **duplicar** e **reordenar** datagramas. A ordem total (ADR-0005) já tratava **duplicação** (dedup por `message_id`) e **reordenação** (hold-back + FIFO por origem), mas a **perda** de um `DATA`, `ACK` ou `MARKER` estagnava a entrega/snapshot — antes documentada como limitação fora de escopo. O enunciado (§13, "UDP perdendo pacotes") sugere tratar lacunas com números de sequência e retransmissão. A equipe optou por fechar essa lacuna.

## Decision

Adicionar uma **camada de confiabilidade por retransmissão sob demanda (NACK)** + reenvio periódico do que está pendente, sem timers por-mensagem nem números de sequência novos (reaproveita `message_id = origin:seq`).

Mecanismo:
1. **Cache de mensagens** (`message_store`): cada nó guarda os `DATA` que enviou/recebeu, para poder retransmitir.
2. **NACK** (novo tipo de mensagem): pedido de re-sincronização de um `message_id`. Ao receber um NACK, um nó responde com: o `DATA` (se for a origem e o tiver) e/ou o seu `ACK` (se conhece a mensagem). Assim um único NACK recupera **tanto perda de DATA quanto de ACK**.
3. **Thread de retransmissão** (`retransmit_tick`, a cada 1s), que difunde:
   - o meu próprio `DATA` ainda não entregue (cobre perda do envio original, inclusive da 1ª mensagem, cuja ausência não gera lacuna detectável no destino);
   - se a entrega está travada no **topo** da hold-back queue: `NACK` da mensagem que falta (lacuna) ou `NACK` do próprio topo (falta de ACK).
4. Tudo **idempotente** e limitado ao que está pendente (holdback) → converge e para quando tudo é entregue.

**Fora de escopo:** garantia de entrega sob partição permanente ou queda de nó (se a origem cai antes de retransmitir uma mensagem que ninguém mais tem, ela se perde). Recuperação de MARKER perdido no snapshot também não é tratada (documentada como limitação).

## Alternatives considered

### Alternativa A — NACK + reenvio periódico (escolhida)
Reativa (só age quando há pendência) e sem estado por-par. **Pró:** simples, converge, cobre DATA e ACK. **Contra:** um NACK pode gerar O(N) respostas de ACK; latência de recuperação ligada ao intervalo (1s).

### Alternativa B — ACK positivo com timeout e retransmissão por remetente
Cada remetente reenvia até receber ACK de todos, com timers por mensagem/destino. **Contra:** mais estado e timers; o emissor precisaria rastrear ACKs individuais por destino. Rejeitada por complexidade.

### Alternativa C — Deixar como limitação documentada
Era o estado anterior. Rejeitada: o enunciado sugere explicitamente tratar perdas, e o custo de implementar foi baixo.

## Consequences

### Positive

- Sistema converge sob perda real (validado com 30% e 50% de perda injetada — ordem global idêntica em todos os nós).
- Reaproveita `message_id`; nenhum campo novo no envelope de `DATA`/`ACK`.

### Negative

- Mais tráfego de controle sob perda (NACKs + reenvios). Mitigação: só ocorre quando há pendência; para quando tudo é entregue.
- Latência de recuperação ≈ intervalo de retransmissão (1s). Mitigação: ajustável.
- Não cobre queda da origem nem MARKER perdido — documentado.

## Outcomes

**Outcomes recorded:** —

## Related

- **Intent:** `context/intent/feature-ordem-total.md` (R4), `context/intent/project-intent.md`
- **ADRs:** `context/decisions/0001-comunicacao-grupo-multicast-udp.md`, `context/decisions/0005-ordem-total-abordagem.md`
- **Patterns:** `context/knowledge/patterns/reliable-multicast-nack-retransmission.md`
- **Anti-patterns:** *nenhum*
- **Buglog:** *nenhum*

## Status history

| Timestamp | Status | Reason |
|---|---|---|
| 2026-08-31 22:00 UTC-03:00 | Accepted | Camada de confiabilidade por NACK implementada e validada com perda de 30% e 50% |
