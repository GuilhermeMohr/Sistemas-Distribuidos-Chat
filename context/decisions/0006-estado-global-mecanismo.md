# ADR-0006 — Estado global: Chandy-Lamport vs variante centralizada

- **Created:** 2026-08-26 22:54 UTC-03:00
- **Last updated:** 2026-08-26 22:54 UTC-03:00
- **Status:** Proposed
- **Decision-makers:** equipe (decisão em aberto — a fechar no Build)

## Context

R6 exige capturar uma "fotografia" coerente de todos os nós (estado global consistente) disparável por comando. O enunciado (§5.5) recomenda o algoritmo de snapshot de **Chandy-Lamport**, mas permite variante centralizada, exigindo justificativa da escolha no relatório (§10.9). A regra "somente mensagens de rede" (§2) deve ser respeitada — o snapshot não pode usar memória/arquivo compartilhado.

## Decision

**EM ABERTO.** A ser decidida durante o Build de R6. Escolher o mecanismo, registrar a justificativa aqui e atualizar o status para Accepted.

## Alternatives considered

### Alternativa A — Chandy-Lamport (recomendada pelo enunciado)
Um nó iniciador registra seu próprio estado e envia um MARCADOR por todos os canais de saída. Ao receber o primeiro MARCADOR, um nó registra seu estado, marca como vazio o canal por onde o marcador chegou e propaga o MARCADOR pelos seus canais de saída. Para os demais canais, grava as mensagens recebidas entre o registro do seu estado e a chegada do marcador daquele canal (estado do canal). Termina quando todos registraram estado e todos os canais foram contabilizados.
- **Vantagem:** não exige parar o sistema nem relógio sincronizado; produz um estado **consistente**; é a solução canônica vista em aula e respeita "somente mensagens de rede".
- **Custo:** mais complexo de implementar (registro de estado de canais, MARCADORes por canal). Sobre multicast/UDP, exige atenção à noção de "canais" e à confiabilidade dos marcadores.

### Alternativa B — Variante centralizada
O líder/coordenador consulta todos os nós e agrega as respostas.
- **Vantagem:** mais simples de implementar.
- **Custo:** ponto único de falha; risco de estado inconsistente se não coordenado com a ordenação; trade-off simplicidade × ponto único a justificar no relatório.

## Consequences

### Positive

- Fechar esta decisão destrava R6 e conecta ao relatório (§10.9).

### Negative

- Chandy-Lamport aumenta a complexidade; a variante centralizada acopla ao líder (relação com [[decisions/0005]] Abordagem B).

## Outcomes

**Outcomes recorded:** —

## Related

- **Intent:** `context/intent/project-intent.md` (R6)
- **ADRs:** `context/decisions/0005-ordem-total-abordagem.md`
- **Patterns:** *nenhum ainda*
- **Anti-patterns:** *nenhum*
- **Buglog:** *nenhum*

## Status history

| Timestamp | Status | Reason |
|---|---|---|
| 2026-08-26 22:54 UTC-03:00 | Proposed | Decisão registrada em aberto; alternativas Chandy-Lamport e centralizada documentadas para escolha no Build |
