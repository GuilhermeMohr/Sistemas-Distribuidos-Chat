# ADR-0006 — Estado global: Chandy-Lamport vs variante centralizada

- **Created:** 2026-08-26 22:54 UTC-03:00
- **Last updated:** 2026-08-31 19:08 UTC-03:00
- **Status:** Accepted
- **Decision-makers:** equipe + revisão técnica externa (GPT) — Confidence 🟢 High

## Context

R6 exige capturar uma "fotografia" coerente de todos os nós (estado global consistente) disparável por comando. O enunciado (§5.5) recomenda o algoritmo de snapshot de **Chandy-Lamport**, mas permite variante centralizada, exigindo justificativa da escolha no relatório (§10.9). A regra "somente mensagens de rede" (§2) deve ser respeitada — o snapshot não pode usar memória/arquivo compartilhado.

## Decision

**Escolhido o snapshot de Chandy-Lamport** (descentralizado). NÃO adotar variante centralizada — combina naturalmente com a arquitetura sem líder da [[decisions/0005]] e respeita "somente rede".

Modelagem sobre multicast UDP (ponto crítico):

- **Canais lógicos direcionados sobre um único grupo multicast:** fisicamente todos os nós usam o mesmo grupo `239.0.0.1:50000`, mas o snapshot modela logicamente um canal `j → i` por par de processos. O **canal lógico é identificado pela origem da mensagem** (`message['id']`) — não se cria socket por canal. Registrar isso no relatório como abstração deliberada.
- **MARKER** é uma mensagem de protocolo (`{"type":"MARKER","snapshot_id":...,"origin":...}`) difundida ao grupo.
- Ao **iniciar**: o nó registra seu estado local e difunde MARKER.
- Ao receber o **primeiro** MARKER: registra estado local, marca o canal de origem como vazio, começa a gravar os demais canais e difunde MARKER.
- Ao receber MARKER **subsequente** de um canal: encerra a gravação daquele canal (estado do canal = mensagens recebidas entre o registro local e a chegada do MARKER daquele canal).
- **Termina** quando MARKERs de todos os `node_ids` foram recebidos.
- **Estado capturado por nó:** `vectorial_time`, `delivery_order`, `holdback_queue`, e `channel_state[j]` (mensagens por canal lógico). Simplificação aceita: "estado do canal" = mensagens recebidas após o registro local e antes do MARKER daquele canal.

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

- Chandy-Lamport aumenta a complexidade (gravação de estado de canais, contagem de MARKERs).
- Sobre UDP não confiável, perda de um MARKER trava o término do snapshot daquele canal — documentar como limitação (mesma dedup/`message_id` da [[decisions/0005]] ajuda).

## Outcomes

**Outcomes recorded:** —

## Related

- **Intent:** `context/intent/project-intent.md` (R6), `context/intent/feature-ordem-total.md`
- **ADRs:** `context/decisions/0005-ordem-total-abordagem.md`
- **Patterns:** *a criar no Learn (chandy-lamport-sobre-multicast)*
- **Anti-patterns:** *nenhum*
- **Buglog:** *nenhum*

## Status history

| Timestamp | Status | Reason |
|---|---|---|
| 2026-08-26 22:54 UTC-03:00 | Proposed | Decisão registrada em aberto; alternativas Chandy-Lamport e centralizada documentadas para escolha no Build |
| 2026-08-31 19:08 UTC-03:00 | Accepted | Chandy-Lamport (descentralizado); canais lógicos modelados por origem sobre o grupo multicast único. Variante centralizada descartada |
