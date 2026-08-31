# Pattern: Multicast totalmente ordenado (chave total + ACK + hold-back)

- **Validado em:** 2026-08-31 19:08 UTC-03:00
- **Origem:** Build da feature ordem total (PR #1/#2); `multicast.py` classe `Node`
- **Maturidade:** consolidado — validado com 3 e 15 nós reais + `test_ordem_total.py`
- **Last updated:** 2026-08-31 19:08 UTC-03:00

## O que é

Transforma a ordem **causal** (que o relógio vetorial garante) em ordem **total** (mesma sequência de entrega em todos os nós) sem sequenciador/líder.

- Problema que resolve: mensagens concorrentes podem ser entregues em ordens diferentes em nós diferentes.
- Mecanismo central: **chave total determinística** + **ACK de estabilidade** sobre uma **hold-back queue**. Entrega só quando a mensagem é o topo por chave E todos os nós conhecidos confirmaram.
- Por que vale formalizar: é a diferença entre "quase funciona" (sort) e "correto" (estabilidade). Ver anti-pattern [[knowledge/anti-patterns/total-order-sort-without-stability]].

## Quando usar

- Use quando: precisa de ordem total descentralizada sobre difusão de grupo e já tem relógio vetorial.
- Use quando: o nº de nós é conhecido e estável (`node_ids` do catálogo `nos.json`).
- **Não use quando:** os membros mudam dinamicamente, ou perdas frequentes tornam O(N²) ACKs caro — aí um sequenciador eleito (Abordagem B) pode ser melhor.

## Implementação

```python
@staticmethod
def total_key(message):
    v = message["vectorial_time"]
    return (sum(v.values()), int(message["id"]), v[message["id"]])

def _try_deliver(self):            # chamar com o lock
    delivered = []
    while self.holdback_queue:
        self.holdback_queue.sort(key=self.total_key)
        m = self.holdback_queue[0]
        mid, origin = m["message_id"], m["id"]
        seq = m["vectorial_time"][origin]
        if len(self.acks.get(mid, set())) < len(self.node_ids):
            break                  # estabilidade: falta ACK de alguém
        if seq != self.delivered_seq[origin] + 1:
            break                  # FIFO por origem (sem lacuna)
        self.holdback_queue.pop(0); self.delivered_seq[origin] = seq
        self.delivery_order.append(mid); delivered.append(m)
    return delivered
```

Pontos-chave:

- Cada `DATA` recebida gera um `ACK` multicast; o **emissor conta como ACK** da própria mensagem; a origem é adicionada por todos ao ver o `DATA`.
- `message_id = origin:seq` (com `seq = V[origin]`) dá dedup e FIFO por origem.
- Fazer entrega/`print` **fora** do lock (retornar a lista e imprimir no chamador).

## Trade-offs

| Aspecto | Custo | Benefício |
|---|---|---|
| Mensagens | O(N²) ACKs no grupo | Ordem total sem líder/ponto único |
| Latência | Espera ACK de todos | Estabilidade correta (não diverge) |
| Perdas UDP | ACK/DATA perdido estagna a mensagem | Simples; recuperação fica fora de escopo |

## Como detectar uso correto (opcional)

- Sinal de uso: entrega condicionada a `len(acks[mid]) == len(node_ids)` E topo por `total_key`.
- Falha comum: entregar por `sort`+`pop(0)` sem checar ACKs — ver anti-pattern relacionado.

## Related

- **Intent:** `context/intent/feature-ordem-total.md` (R4)
- **ADRs:** `context/decisions/0005-ordem-total-abordagem.md`
- **Patterns:** `context/knowledge/patterns/causal-delivery-vector-clock-buffer.md`
- **Anti-patterns:** `context/knowledge/anti-patterns/total-order-sort-without-stability.md`
- **Buglog:** *nenhum*
- **Standard relacionado:** `context/code-standards.md`
