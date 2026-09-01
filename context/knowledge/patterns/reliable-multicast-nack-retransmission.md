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
    mid = message["message_id"]
    if mid.split(":")[0] == self.process_id and mid in self.message_store:
        return [self.message_store[mid]]   # sou a origem: reenvio DATA/HEARTBEAT
    return []

def retransmit_tick(self):           # chamada a cada ~1s por uma thread daemon
    out = [self._build("HEARTBEAT")]         # liveness (avança meu progresso)
    self._register_own(out[0], is_data=False)
    for o in self.node_ids:                  # NACK das lacunas por origem
        if o != self.process_id and self.reorder_buf[o]:
            out.append({"type":"NACK","id":self.process_id,
                        "message_id": f"{o}:{self.next_expected[o]}"})
    for m in self.holdback:                   # reenvia meu DATA pendente
        if m["id"] == self.process_id:
            out.append(m)
    return out
```

Pontos-chave:

- **Sem ACKs** (removidos na correção da ordem total, [[decisions/0008]]): o fluxo FIFO por origem (DATA/HEARTBEAT) + NACK cobre perda de DATA e a liveness.
- NACK da **lacuna** (`reorder_buf` não vazio) pede a mensagem faltante à origem.
- Reenviar o **próprio DATA pendente** cobre a 1ª mensagem perdida (destino sem lacuna para NACKear).
- Idempotente e limitado ao pendente → converge e para quando tudo é entregue.
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
