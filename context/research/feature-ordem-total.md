# Research Report — feature-ordem-total

- **Intent:** `context/intent/feature-ordem-total.md`
- **Gerado em:** 2026-09-02
- **Escopo desta sessão:** limpeza de referências internas em comentários do código e no relatório (sem mudança de comportamento) + preparação do pacote de entrega.

## Artefatos mapeados (transitivamente referenciados pelo intent)

| Artefato | Relevância |
|---|---|
| [[decisions/0005]] Ordem total — Abordagem A | Define chave total + hold-back; corrigida por 0008 |
| [[decisions/0008]] Condição de estabilidade | Condição vigente: "ouvi-maior-de-todos" em FIFO + heartbeats; Outcomes registram auditoria adversarial (P0 refutado, P1 confirmado) |
| [[decisions/0006]] Chandy-Lamport | Snapshot implementado (CP4) |
| [[decisions/0007]] Confiabilidade UDP | NACK unitário (faixa revertida por storm) |
| [[decisions/0004]] Concorrência | Lock único, threads daemon, shutdown |
| [[knowledge/patterns/totally-ordered-multicast-ack-holdback]] | Pattern vigente da entrega |
| [[knowledge/patterns/chandy-lamport-snapshot-multicast]] | Pattern do snapshot |
| [[knowledge/patterns/reliable-multicast-nack-retransmission]] | Pattern da retransmissão |
| [[knowledge/anti-patterns/total-order-sort-without-stability]] | Guarda da condição de entrega |
| `context/evolution/buglog.md#2026-09-01` | Bug de estabilidade (corrigido) |

## Estado do código vs. docs

`multicast.py` (classe `Node`) implementa a condição da ADR-0008; testes `test_ordem_total.py` + `test_fuzz_ordem_total.py` cobrem regressões. E2E completo desta sessão: unit ✅, fuzz ✅, 3/8/15 nós ✅, unicast ✅, snapshot 8 nós ✅, perda 30/50% ✅.

## Mudança planejada (esta sessão)

Somente **comentários/docstrings** (código) e **texto** (relatório): remover referências a artefatos de processo interno (números de ADR, buglog, "veredito", "P1") — o deliverable acadêmico deve ser autocontido. Nenhuma linha executável muda; sensores devem permanecer verdes.
