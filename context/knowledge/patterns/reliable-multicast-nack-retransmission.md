# Pattern: Confiabilidade sobre multicast UDP por NACK + reenvio de pendentes

- **Validado em:** 2026-08-31 22:00 UTC-03:00
- **Origem:** feature ordem total, camada de confiabilidade (PR #3); `multicast.py`
- **Maturidade:** consolidado — validado com 30% e 50% de perda injetada (converge)
- **Last updated:** 2026-08-31 22:00 UTC-03:00

## O que é

Recupera de **perdas** de datagramas UDP sem timers por-mensagem nem números de sequência novos, complementando dedup (duplicação) e hold-back (reordenação).

- Problema que resolve: um `DATA`/`ACK` perdido estagna a entrega ordenada.
- Mecanismo central: **NACK** (pedido de re-sincronização por `message_id`) + thread periódica que reenvia o que está pendente e pede o que falta.
- Por que vale formalizar: um único mecanismo (NACK) cobre perda de DATA **e** de ACK.

## Quando usar

- Use quando: transporte não confiável (UDP) sob entrega ordenada com conjunto de membros conhecido.
- Use quando: já existe `message_id = origem:seq` (dá dedup e detecção de lacuna de graça).
- **Não use quando:** precisa de garantia sob queda de nós/partição — aí é preciso replicação/persistência (fora do escopo deste pattern).

## Implementação

```python
def on_nack(self, message):          # resposta a um pedido de re-sincronização
    mid = message["message_id"]; out = []
    if mid.split(":")[0] == self.process_id and mid in self.message_store:
        out.append(self.message_store[mid])            # sou a origem: reenvio DATA
    if mid in self.received_ids:
        out.append({"type": "ACK", "id": self.process_id, "message_id": mid})
    return out                                          # reenvio meu ACK

def retransmit_tick(self):           # chamada a cada ~1s por uma thread daemon
    out = []
    for m in self.holdback_queue:
        if m["id"] == self.process_id:
            out.append(m)                               # reenvia meu DATA pendente
    if self.holdback_queue:
        top = min(self.holdback_queue, key=self.total_key)
        origin = top["id"]; prox = self.delivered_seq[origin] + 1
        if top["vectorial_time"][origin] > prox:
            out.append({"type":"NACK","id":self.process_id,"message_id":f"{origin}:{prox}"})
        elif len(self.acks.get(top["message_id"], set())) < len(self.node_ids):
            out.append({"type":"NACK","id":self.process_id,"message_id":top["message_id"]})
    return out
```

Pontos-chave:

- Reenviar o **próprio DATA pendente** cobre o caso da 1ª mensagem perdida (o destino não tem lacuna para NACKear).
- NACK do **topo** cobre falta de ACK; NACK da **lacuna** cobre DATA faltante.
- Idempotente e limitado ao `holdback` → converge e para quando tudo é entregue.
- Testar injetando perda (`DROP_PROB` no `receive_loop`).

## Trade-offs

| Aspecto | Custo | Benefício |
|---|---|---|
| Tráfego | NACK pode gerar O(N) ACKs de resposta | Recupera perda de DATA e de ACK |
| Latência | recuperação ≈ intervalo (1s) | Sem timers por-mensagem/estado por-par |
| Robustez | não cobre queda da origem / MARKER perdido | Simples e suficiente p/ o escopo |

## Como detectar uso correto (opcional)

- Sinal de uso: existe tipo `NACK`, `message_store` e uma thread de retransmissão periódica.
- Falha comum: só NACKear lacunas (perde recuperação de ACK) ou responder DATA de qualquer nó (storms) em vez de só a origem.

## Related

- **Intent:** `context/intent/feature-ordem-total.md`
- **ADRs:** `context/decisions/0007-confiabilidade-udp-nack.md`, `context/decisions/0005-ordem-total-abordagem.md`
- **Patterns:** `context/knowledge/patterns/totally-ordered-multicast-ack-holdback.md`
- **Anti-patterns:** *nenhum*
- **Buglog:** *nenhum*
- **Standard relacionado:** *nenhum*
