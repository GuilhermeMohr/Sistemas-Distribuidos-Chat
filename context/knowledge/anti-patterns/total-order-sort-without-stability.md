# Anti-pattern: Ordem total por sort sem condição de estabilidade

- **Detectado em:** 2026-08-31 19:08 UTC-03:00
- **Origem:** revisão técnica da ADR-0005 (antes de implementar §5.3)
- **Severidade típica:** alta — quebra a corretude da ordem total (R4), o item mais avaliado
- **Last updated:** 2026-08-31 19:08 UTC-03:00

## O problema

Tentar obter ordem total apenas ordenando o buffer pela chave total e entregando o primeiro elemento — sem verificar se aquela mensagem é **estável** (isto é, se nenhuma mensagem com chave menor ainda pode chegar).

- O que aconteceu (manifestação técnica): `holdback_queue.sort(key=total_key)` seguido de entregar `queue[0]`.
- Por que é ruim: sob rede assíncrona/UDP, uma mensagem com chave **menor** ainda pode estar em trânsito. Se um nó entrega `queue[0]` cedo, outro nó que já recebeu a mensagem menor entrega em ordem diferente → **as filas de delivery divergem entre nós**, violando o critério de corretude do enunciado (§8).
- Em qual condição reproduz: duas mensagens concorrentes onde a de chave menor chega depois em um dos nós.

## Manifestação histórica

- **2026-08-31** — Identificado na revisão da ADR-0005 antes de codar. O `can_deliver` garante ordem **causal**, não total; sort+entrega do topo seria regressão silenciosa. Referência: [[decisions/0005]].
- **2026-09-01** — **Incidente real:** a estabilidade *"todos os nós deram ACK em m"* (que parecia corrigir o item acima) **também é insuficiente**. Sob 50% de perda, ~1/3 das execuções entregou `2:1` antes de `1:1` em alguns nós → filas divergentes (R4 quebrado). Custo: bug latente que passou por vários testes de baixa perda. Correção em [[decisions/0008]]. Referência: `context/evolution/buglog.md#2026-09-01`.

> **Lição:** nenhuma das duas condições fracas serve — nem `sort`+topo, nem "todos ACKaram m". A correta é *"de todo nó ≠ origem, já processei em ordem FIFO algo com chave > m"* (+ heartbeats + FIFO por origem).

## O que evitar

- ❌ `queue.sort(key=total_key); deliver(queue.pop(0))` sem checar estabilidade.
- ❌ Usar `sum(V)` (ou qualquer chave) como se, sozinho, garantisse que nada menor virá.
- ❌ "Heartbeat mágico" ad-hoc para adivinhar se há mensagem menor escondida.

## Alternativa correta

- ✅ **Condição de estabilidade via ACK** (multicast totalmente ordenado do Lamport): só entregar `queue[0]` quando **todos os nós conhecidos** (`node_ids`) deram ACK para ela **e** ela é o topo por `total_key`.
- ✅ Cada `DATA` gera um `ACK` multicast; o próprio emissor conta como ACK; `acks[message_id]` acumula os ids. Se todos confirmaram M, todos já a conhecem → seguro entregar.
- ✅ Ver [[decisions/0005]] e o pattern `totally-ordered-multicast-ack-holdback` (a criar no Learn).

## Como detectar (opcional)

- Regex sugerida: `\.sort\(key=.*\)` próximo de `pop(0)`/`deliver` sem checagem de `acks`/`len(node_ids)`.
- Palavras-chave para grep: `total_key`, `holdback`, `sort`, `pop(0)`
- Revisão: garantir que toda entrega verifica `len(acks.get(mid)) == len(node_ids)`.

## Related

- **Intent:** `context/intent/feature-ordem-total.md` (R4)
- **ADRs:** `context/decisions/0005-ordem-total-abordagem.md`
- **Patterns:** `context/knowledge/patterns/causal-delivery-vector-clock-buffer.md`
- **Anti-patterns:** *nenhum (este é um anti-pattern)*
- **Buglog:** *nenhum*
- **Standard relacionado:** `context/code-standards.md`
