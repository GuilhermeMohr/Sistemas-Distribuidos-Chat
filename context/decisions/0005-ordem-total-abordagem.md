# ADR-0005 — Ordem total: Abordagem A (relógio vetorial + desempate) vs B (sequenciador eleito)

- **Created:** 2026-08-26 22:54 UTC-03:00
- **Last updated:** 2026-08-31 19:08 UTC-03:00
- **Status:** Accepted
- **Decision-makers:** equipe + revisão técnica externa (GPT) — Confidence 🟢 High

## Context

Esta é **a decisão de projeto mais importante do trabalho** (enunciado §5.3). O relógio vetorial sozinho garante apenas **ordem causal** (parcial): mensagens concorrentes podem ser entregues em ordens diferentes em nós diferentes. R4 exige **ordem total** — todos os nós entregam TODAS as mensagens de grupo na mesma sequência. É preciso um critério extra além do vetor. O enunciado apresenta duas abordagens e exige que a equipe escolha UMA e a justifique no relatório (§10.8), com exemplo numérico de dois nós convergindo à mesma ordem a partir de mensagens concorrentes.

## Decision

**Escolhida a Abordagem A — multicast totalmente ordenado ao estilo Lamport** (relógio vetorial + chave total determinística + **ACK de estabilidade** sobre uma **hold-back queue**). NÃO adotar sequenciador/líder (Abordagem B).

Mecanismo (correção conceitual sobre a chave sugerida no enunciado):

1. **Chave total determinística** por mensagem:
   `total_key(m) = ( sum(Vm.values()), int(origin_id), Vm[origin_id] )`
   — escalar derivado do vetor, desempatado por id numérico da origem e pela sequência da origem (`Vm[origin]`). O `sum(V)` é apresentado como **escalar derivado do vetor** (cada envio incrementa exatamente uma posição), **não** como um relógio de Lamport perfeito.
2. **Hold-back queue** ordenada por `total_key` substitui a entrega direta do `can_deliver` atual como mecanismo **final** de entrega. O relógio vetorial permanece para demonstrar causalidade e para o relatório.
3. **ACK de estabilidade:** cada `DATA` recebida gera um `ACK` (multicast ao grupo). Cada nó mantém `acks[message_id] = {ids que confirmaram}` (o próprio emissor conta como ACK). **Condição de entrega:** a mensagem só é entregue quando (a) está no **topo** da hold-back queue por `total_key` **e** (b) **todos os nós conhecidos** (`node_ids`) deram ACK para ela. Isso resolve o problema do "silêncio" sem heartbeat mágico: se todos confirmaram M, todos já a conhecem.
4. **Confiabilidade mínima sobre UDP:** cada mensagem tem `message_id = "origin:seq"` (`seq = Vm[origin]`); deduplicação via `received_ids`; detecção de lacuna (segurar `1:3` se `1:1`/`1:2` não chegaram). Recuperação/retransmissão de perdas está **fora de escopo** e será documentada como limitação.

> **Correção importante (revisão GPT, 2026-08-31):** `holdback_queue.sort(key=total_key)` e entregar o primeiro **NÃO basta** — sem a condição de estabilidade (ACK de todos), um nó pode entregar uma mensagem antes de outra menor ainda em trânsito. A estabilidade via ACK é o que garante a ordem total. Ver anti-pattern `total-order-sort-without-stability`.

> **Estado do código (commit `faf894c`):** hoje há relógio vetorial + `buffer` + `can_deliver` (ordem **causal** apenas). A entrega causal deixa de ser o mecanismo final; passa a hold-back queue + ACK. Dado o tamanho da mudança, o Build reescreve `multicast.py` separando protocolo / ordenação / snapshot / UI.

## Alternatives considered

### Alternativa A — Relógio vetorial + desempate determinístico
Mantém o relógio vetorial para causalidade e define uma função de ordenação total idêntica em todos os nós. Chave sugerida: `chave(m) = (soma(Vm), id_do_no_de_origem, contador_local_da_origem)` — compara por soma dos componentes do vetor (relógio escalar derivado), desempata por id do nó e depois por contador local. Só entrega quando tem certeza de que nenhuma mensagem com chave menor ainda pode chegar (estabilidade / mensagens de ACK/batimento).
- **Vantagem:** totalmente descentralizado, sem ponto único de falha, fiel ao espírito "via relógio vetorial".
- **Custo:** maior latência de entrega e mais mensagens de controle; risco de travar quando um nó fica em silêncio (mitigar com mensagens periódicas de batimento/ACK — ver armadilha "deadlock por silêncio" §13).

### Alternativa B — Sequenciador / super-servidor eleito
Um nó atua como sequenciador: recebe as mensagens de grupo e atribui/difunde um número de sequência global. Todos entregam na ordem do número de sequência. O sequenciador é escolhido por eleição de líder (§5.4).
- **Vantagem:** ordem total simples e eficiente; casa diretamente com estado global e eleição de líder.
- **Custo:** ponto crítico — **obrigatório** tratar a queda do sequenciador com reeleição (R8 / [[decisions]] futura de eleição, Bully ou Anel); distancia-se do "via relógio vetorial" puro. O relógio vetorial continua sendo registrado para causalidade e para o relatório.

## Consequences

### Positive

- Destrava R4 e o critério de corretude (§8: filas de delivery idênticas em todos os nós).
- Mantém a arquitetura **descentralizada** — sem eleição de líder, sem ponto único de falha; R8 torna-se opcional (não adotado).
- Reaproveita o relógio vetorial já implementado; narrativa acadêmica sólida (causalidade → chave total → ACK de estabilidade → ordem total).

### Negative

- **Mais mensagens de controle** (1 ACK por nó por mensagem → O(N²) no grupo). Aceitável para 15 nós; documentar no relatório (§10.6).
- **Latência de entrega** maior (espera ACK de todos). Mitigação: aceitável no escopo; batimento não é necessário porque o ACK já cobre o silêncio.
- Requer **lock** protegendo `holdback_queue`/`acks`/`vectorial_time` (estado compartilhado entre threads) — ver ADR-0004.
- Sensível a **perda de ACK** (um nó silencioso trava a entrega daquela mensagem). Mitigação mínima: dedup + detecção de lacuna; recuperação total fora de escopo (documentar).

## Outcomes

**Outcomes recorded:** —

## Related

- **Intent:** `context/intent/project-intent.md` (R4), `context/intent/feature-ordem-total.md`
- **ADRs:** `context/decisions/0003-envelope-mensagem-json.md`, `context/decisions/0004-concorrencia-threads.md`, `context/decisions/0006-estado-global-mecanismo.md`
- **Patterns:** `context/knowledge/patterns/causal-delivery-vector-clock-buffer.md` (base causal), `totally-ordered-multicast-ack-holdback` (a criar no Learn)
- **Anti-patterns:** `context/knowledge/anti-patterns/total-order-sort-without-stability.md`
- **Buglog:** *nenhum*

## Status history

| Timestamp | Status | Reason |
|---|---|---|
| 2026-08-26 22:54 UTC-03:00 | Proposed | Decisão central registrada em aberto; alternativas A e B documentadas para escolha no Build |
| 2026-08-31 19:08 UTC-03:00 | Accepted | Abordagem A + ACK de estabilidade + hold-back queue (multicast totalmente ordenado do Lamport); B descartada (evita eleição/ponto único). Revisão técnica externa incorporada |
