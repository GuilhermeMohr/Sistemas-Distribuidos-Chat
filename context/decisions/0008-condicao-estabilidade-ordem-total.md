# ADR-0008 — Condição de estabilidade correta da ordem total (heard-larger-from-all + heartbeats)

- **Created:** 2026-09-01 01:56 UTC-03:00
- **Last updated:** 2026-09-01 01:56 UTC-03:00
- **Status:** Accepted
- **Decision-makers:** equipe + revisão técnica externa — Confidence 🟢 High

## Context

A [[decisions/0005]] escolheu a Abordagem A (ordem total via relógio vetorial + chave total + estabilidade). A **implementação inicial** usou como condição de estabilidade *"todos os nós deram ACK na mensagem m"*. Um teste com 50% de perda (`orchestrate_loss.py`) revelou **divergência da ordem de entrega** (bug L2, ver buglog 2026-09-01): um nó entregava `2:1` antes de `1:1` em ~1/3 das execuções.

**Causa raiz:** "todos ACKaram m" **não** garante que nenhuma mensagem com chave **menor** ainda pode chegar. O ACK de `m` só diz que o remetente viu `m`; não diz que o receptor já recebeu todas as mensagens menores. Sob perda/reordenação, um nó estabilizava `2:1` e o entregava antes de `1:1` chegar.

## Decision

Adotar a **condição de estabilidade canônica** da Abordagem A (multicast totalmente ordenado do Lamport):

> Entrega-se a mensagem `m` (a de **menor** chave no holdback) somente quando, de **todo** nó `o ≠ origem(m)`, já se **processou em ordem FIFO** uma mensagem (DATA ou HEARTBEAT) com **chave > chave(m)**. Isso garante que nenhuma mensagem menor pode mais chegar (nem em trânsito, nem futura).

Peças que tornam isso correto sobre UDP:

1. **`latest_key[o]`** = maior chave já processada **em ordem contígua** de cada nó `o`. Só avança via processamento FIFO.
2. **FIFO por origem** (`next_expected` + `reorder_buf` + dedup + NACK): uma mensagem fora de ordem é **bufferizada** e **não** avança `latest_key` até a lacuna ser preenchida. Isto fecha o buraco do UDP não-FIFO — um batimento posterior não "fura" a ordem.
3. **HEARTBEAT** periódico: cada nó difunde batimentos (que avançam seu próprio progresso), para que nós silenciosos não travem a fila. Ao receber um DATA, o nó também emite um batimento imediato (convergência rápida).
4. **ACKs removidos:** o papel de "algo posterior de todos" passa a ser cumprido por DATA/HEARTBEAT no fluxo FIFO. Um único mecanismo (fluxo FIFO + batimento) substitui os ACKs.

Esta ADR **corrige a condição de entrega** de [[decisions/0005]] (a escolha A permanece) e ajusta [[decisions/0007]] (confiabilidade agora sem ACKs).

## Alternatives considered

### Alternativa A — heard-larger-from-all + heartbeats + FIFO (escolhida)
Condição canônica e correta. **Pró:** ordem total de fato correta (validada sob perda). **Contra:** latência de entrega ligada ao intervalo de batimento; mais tráfego de batimentos.

### Alternativa B — manter "todos ACKaram m"
**Contra:** incorreta (o bug). Rejeitada.

### Alternativa C — sequenciador/líder (Abordagem B)
Daria ordem total simples, mas exige eleição de líder + tratamento de queda. Rejeitada por já termos a infra descentralizada; ver [[decisions/0005]].

## Consequences

### Positive

- Ordem total **correta** sob perda/reordenação (50% de perda: 8/8 convergem; 30%: 3/3).
- Remove ACKs; modelo mais simples e alinhado ao algoritmo clássico.

### Negative

- Latência de entrega ≈ intervalo de batimento (1 s) no pior caso; mitigada pelo batimento imediato ao receber DATA.
- Batimentos periódicos incrementam o relógio/seq continuamente (crescimento do contador e do `message_store`) — aceitável no escopo; documentado como limitação.

## Outcomes

**Outcomes recorded:** 2026-09-01

Uma **revisão adversarial externa** apontou um suposto P0 de *safety*: recepção fora de ordem contaminaria o `vectorial_time`, e um heartbeat próprio com chave inflada seria usado por outro nó como falsa evidência de progresso → entrega prematura.

**Investigação empírica** (fuzzer `test_fuzz_ordem_total.py`: perda 20–50% + reordenação aleatória, 3–6 nós, centenas de execuções pseudo-aleatórias + o cenário exato do veredito):

- **Safety NÃO viola** (nenhuma divergência de ordem em nenhuma execução). O suposto P0 é **falso-positivo**. **Razão:** a chave de cada stream é **monotônica na seq** — a contaminação infla uniformemente as chaves das mensagens do próprio nó, e `latest_key[o]` (fronteira FIFO) continua honesto (chave menor ⇒ seq menor ⇒ já processada FIFO). Não há como `latest_key[o] > K` sem ter processado FIFO tudo de `o` com chave ≤ K.
- **Liveness (P1) confirmado:** a recuperação por NACK é de **uma lacuna por rodada**; sob perda severa é **gradual** (o próprio revisor classificou como "não-P0"). Tentou-se NACK de faixa, mas causa **tempestade de reenvios** — revertido; mantém-se NACK unitário (correto e limitado). Recuperação eventual confirmada (dreno suficiente → completude total). **Safety é sempre preservada**, independente da velocidade de recuperação.

Limitação P1 registrada em `context/evolution/todo.md`.

## Related

- **Intent:** `context/intent/feature-ordem-total.md` (R4)
- **ADRs:** `context/decisions/0005-ordem-total-abordagem.md` (corrigida), `context/decisions/0007-confiabilidade-udp-nack.md` (ajustada)
- **Patterns:** `context/knowledge/patterns/totally-ordered-multicast-ack-holdback.md`, `context/knowledge/patterns/reliable-multicast-nack-retransmission.md`
- **Anti-patterns:** `context/knowledge/anti-patterns/total-order-sort-without-stability.md`
- **Buglog:** `context/evolution/buglog.md#2026-09-01`

## Status history

| Timestamp | Status | Reason |
|---|---|---|
| 2026-09-01 01:56 UTC-03:00 | Accepted | Corrige a condição de estabilidade da ordem total; validado sob perda (50%/30%) |
