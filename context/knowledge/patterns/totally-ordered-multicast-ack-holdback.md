# Pattern: Multicast totalmente ordenado (chave total + estabilidade "ouvi-maior-de-todos")

- **Validado em:** 2026-09-01 01:56 UTC-03:00
- **Origem:** feature ordem total + correção da estabilidade (PR #1/#2, corrigido em #5); `multicast.py`
- **Maturidade:** consolidado — validado com 3/8/15 nós e perda de 30%/50% (converge)
- **Last updated:** 2026-09-01 01:56 UTC-03:00

> **Nota histórica:** a 1ª versão usava ACKs ("todos ACKaram m") como estabilidade e **divergia** sob perda (ver [[anti-patterns/total-order-sort-without-stability]] e [[decisions/0008]]). Os ACKs foram substituídos por **batimentos + condição "ouvi-maior-de-todos"**. O nome do arquivo é mantido por compatibilidade de links.

## O que é

Transforma a ordem **causal** (relógio vetorial) em ordem **total** (mesma sequência de entrega em todos os nós) sem sequenciador/líder.

- Problema: mensagens concorrentes podem ser entregues em ordens diferentes.
- Mecanismo: **chave total determinística** + **hold-back queue** + condição de estabilidade correta: entregar `m` (menor chave) só quando, de **todo** nó ≠ origem, já se processou **em ordem FIFO** algo com chave **> m**.
- Por que formalizar: a estabilidade correta é sutil — "ordenar e entregar o topo" e "todos ACKaram m" são ambos **insuficientes**.

## Quando usar

- Use quando: ordem total descentralizada sobre difusão de grupo com conjunto de membros conhecido.
- **Não use quando:** membros dinâmicos, ou quando um sequenciador eleito (Abordagem B) for preferível.

## Implementação

```python
@staticmethod
def total_key(message):
    v = message["vectorial_time"]
    return (sum(v.values()), int(message["id"]), v[message["id"]])

def _try_deliver(self):                     # com o lock
    delivered = []
    while self.holdback:
        m = min(self.holdback, key=self.total_key)
        k = self.total_key(m); origin = m["id"]
        # estabilidade: de TODO nó != origem, já processei (FIFO) algo com chave > k
        if not all(self.latest_key[o] > k for o in self.node_ids if o != origin):
            break
        self.holdback.remove(m)
        self.delivery_order.append(m["message_id"]); delivered.append(m)
    return delivered
```

Pontos-chave:

- `latest_key[o]` avança **só** via processamento **FIFO** por origem (`next_expected` + `reorder_buf`); um datagrama fora de ordem é bufferizado e não avança nada até a lacuna ser preenchida (NACK). Isso fecha o buraco do UDP não-FIFO.
- **HEARTBEAT** periódico dá liveness (nós silenciosos não travam); ao receber DATA, envia-se um batimento imediato (convergência rápida).
- A chave `(sum(V), id, seq)` é a mesma do enunciado; apenas a condição de entrega é a correta.

## Trade-offs

| Aspecto | Custo | Benefício |
|---|---|---|
| Latência | ≈ intervalo de batimento no pior caso | ordem total correta sob perda/reordenação |
| Tráfego | batimentos O(N²) por difusão | sem líder/ponto único |

## Como detectar uso correto (opcional)

- Sinal: entrega condicionada a `all(latest_key[o] > k for o != origin)` com `latest_key` avançando só em ordem FIFO.
- Falha comum: usar "todos ACKaram m" ou `sort`+topo sem FIFO — ver anti-pattern relacionado.

## Related

- **Intent:** `context/intent/feature-ordem-total.md` (R4)
- **ADRs:** `context/decisions/0005-ordem-total-abordagem.md`, `context/decisions/0008-condicao-estabilidade-ordem-total.md`
- **Patterns:** `context/knowledge/patterns/causal-delivery-vector-clock-buffer.md`, `context/knowledge/patterns/reliable-multicast-nack-retransmission.md`
- **Anti-patterns:** `context/knowledge/anti-patterns/total-order-sort-without-stability.md`
- **Buglog:** `context/evolution/buglog.md#2026-09-01`
- **Standard relacionado:** `context/code-standards.md`
