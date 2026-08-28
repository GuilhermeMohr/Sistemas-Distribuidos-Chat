# ADR-0005 — Ordem total: Abordagem A (relógio vetorial + desempate) vs B (sequenciador eleito)

- **Created:** 2026-08-26 22:54 UTC-03:00
- **Last updated:** 2026-08-26 22:54 UTC-03:00
- **Status:** Proposed
- **Decision-makers:** equipe (decisão em aberto — a fechar no Build)

## Context

Esta é **a decisão de projeto mais importante do trabalho** (enunciado §5.3). O relógio vetorial sozinho garante apenas **ordem causal** (parcial): mensagens concorrentes podem ser entregues em ordens diferentes em nós diferentes. R4 exige **ordem total** — todos os nós entregam TODAS as mensagens de grupo na mesma sequência. É preciso um critério extra além do vetor. O enunciado apresenta duas abordagens e exige que a equipe escolha UMA e a justifique no relatório (§10.8), com exemplo numérico de dois nós convergindo à mesma ordem a partir de mensagens concorrentes.

## Decision

**EM ABERTO.** A ser decidida durante o Build de R4. Escolher A ou B, registrar a justificativa aqui e atualizar o status para Accepted.

> **Estado (2026-08-28):** a entrega **causal** já existe (`multicast.py` — relógio vetorial + `buffer` + `can_deliver`, §5.2, commit `faf894c`). Isso garante ordem causal (parcial), **não** ordem total. Falta exatamente o critério de desempate/estabilidade (Abordagem A) OU o sequenciador (Abordagem B) para transformar a ordem causal em ordem total (§5.3). A escolha desta ADR é o próximo passo do Build.

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

- Fechar esta decisão destrava a implementação central de R4 e o critério de corretude (§8: filas de delivery idênticas em todos os nós).

### Negative

- Escolher B implica trabalho adicional obrigatório de eleição de líder + tratamento de queda (R8). Escolher A implica cuidado com estabilidade/deadlock por silêncio.

## Outcomes

**Outcomes recorded:** —

## Related

- **Intent:** `context/intent/project-intent.md` (R4, R8)
- **ADRs:** `context/decisions/0003-envelope-mensagem-json.md`, `context/decisions/0006-estado-global-mecanismo.md`
- **Patterns:** *nenhum ainda*
- **Anti-patterns:** *nenhum*
- **Buglog:** *nenhum*

## Status history

| Timestamp | Status | Reason |
|---|---|---|
| 2026-08-26 22:54 UTC-03:00 | Proposed | Decisão central registrada em aberto; alternativas A e B documentadas para escolha no Build |
