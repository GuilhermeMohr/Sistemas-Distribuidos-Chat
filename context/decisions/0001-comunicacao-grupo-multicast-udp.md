# ADR-0001 — Comunicação de grupo por IP Multicast (UDP)

- **Created:** 2026-08-26 22:54 UTC-03:00
- **Last updated:** 2026-08-26 22:54 UTC-03:00
- **Status:** Accepted
- **Decision-makers:** equipe (inferido via archeology pass — Confidence 🟢 High)

## Context

O enunciado (§2) exige comunicação de grupo e permite escolher entre **multicast** ou **unicast**, exigindo justificativa da escolha no relatório (§10.4). É necessário que uma mensagem de grupo enviada por um nó chegue a todos os demais (R1).

**Source of inference:** `multicast.py:9-41` — socket UDP com `IP_ADD_MEMBERSHIP` no grupo `239.0.0.1` porta `50000`; `broadcast()` em `multicast.py:69-70` envia via `sendto` para o grupo.

## Decision

Usar **IP Multicast sobre UDP** como primitiva de comunicação de grupo. Grupo `239.0.0.1`, porta `50000`. Cada nó ingressa no grupo (`IP_ADD_MEMBERSHIP` em `0.0.0.0` — todas as interfaces) e difunde mensagens ao grupo.

## Alternatives considered

### Alternativa A — Multicast UDP (escolhida)
Difusão nativa de grupo: uma única mensagem alcança todos os inscritos. **Pró:** eficiente para difusão, código simples, é a "comunicação de grupo nativa" (§6.2). **Contra:** UDP não é confiável (perda/duplicação/reordenação) — precisa ser tratado na camada de ordenação; multicast entre máquinas depende da rede/roteador.

### Alternativa B — Unicast com TCP
Iterar sobre a lista de nós e enviar ponto-a-ponto. **Pró:** entrega confiável e ordem FIFO por canal (§6.1); base natural para ACKs individuais. **Contra:** N conexões por difusão, mais código de gerência; menos alinhado a "comunicação de grupo nativa". Rejeitada por ora — multicast é mais direto para R1.

## Consequences

### Positive

- Difusão de grupo eficiente com uma chamada `sendto`.
- Código de rede enxuto (já implementado e funcional).

### Negative

- UDP não confiável → é obrigatório tratar perda/duplicação/reordenação na camada de ordenação (números de sequência por origem, detecção de lacunas). Mitigação: implementar em conjunto com R4. Ver `context/evolution/todo.md`.
- Multicast pode não atravessar todas as redes/roteadores. Mitigação: testes em `localhost` com `SO_REUSEADDR` e TTL baixo; documentar ambiente no relatório (§10.4).

## Outcomes

**Outcomes recorded:** —

(A preencher após validação com 15 nós e cenários de perda.)

## Related

- **Intent:** `context/intent/project-intent.md` (R1)
- **ADRs:** `context/decisions/0003-envelope-mensagem-json.md`
- **Patterns:** `context/knowledge/patterns/multicast-membership-all-interfaces.md`, `context/knowledge/patterns/own-echo-filter.md`
- **Anti-patterns:** *nenhum*
- **Buglog:** *nenhum*

## Status history

| Timestamp | Status | Reason |
|---|---|---|
| 2026-08-26 22:54 UTC-03:00 | Accepted | Decisão já implementada; registrada retroativamente via archeology pass |
