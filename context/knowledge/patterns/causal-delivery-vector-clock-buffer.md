# Pattern: Entrega causal com relógio vetorial e buffer de espera

- **Validado em:** 2026-08-28 00:00 UTC-03:00
- **Origem:** commit `faf894c` "Implementação vectorial lock" (Guilherme) — `multicast.py`
- **Maturidade:** experimental — implementa ordem causal (§5.2); ordem total (§5.3) ainda pendente
- **Last updated:** 2026-08-28 00:00 UTC-03:00

## O que é

Garante que cada nó entregue mensagens de grupo respeitando a **causalidade**: uma mensagem só é entregue quando é a próxima esperada da origem (FIFO por origem) e todas as mensagens que a precedem causalmente já foram entregues. Mensagens fora de ordem ficam num buffer de espera e são reavaliadas a cada entrega.

- Problema que resolve: sob multicast/UDP, mensagens chegam fora de ordem; entregar direto viola a causalidade.
- Mecanismo central: relógio vetorial por nó + condição de entrega (`can_deliver`) + buffer + laço de reavaliação.
- Por que vale formalizar: é a base sobre a qual a **ordem total** (§5.3, [[decisions/0005]]) será construída — não confundir uma com a outra.

## Quando usar

- Use quando: precisa de ordem causal em difusão de grupo antes de aplicar ordem total.
- Use quando: cada mensagem carrega o vetor da origem (`vectorial_time` no envelope — ver [[decisions/0003]]).
- **Não use quando:** basta ordem total simples via sequenciador (Abordagem B de [[decisions/0005]]) — aí o critério é o número de sequência do líder, não o vetor.

## Implementação

```python
# multicast.py:43-56
def can_deliver(message):
    message_id = message['id']
    message_vectorial_time = message['vectorial_time']

    # Próxima mensagem esperada da origem (FIFO por origem)
    if message_vectorial_time[message_id] != vectorial_time.get(message_id, 0) + 1:
        return False

    # Dependências causais já entregues
    for key in message_vectorial_time:
        if key != message_id and message_vectorial_time[key] > vectorial_time.get(key, 0):
            return False
    return True
```

Pontos-chave da implementação:

- Ao entregar, faz `max` componente a componente do vetor local com o da mensagem e incrementa o próprio componente (`multicast.py:78-86`).
- O laço reavalia o `buffer` a cada entrega, pois novas mensagens podem se tornar entregáveis (`multicast.py:70-96`).
- **Falta ordem total:** duas mensagens concorrentes ainda podem ser entregues em ordens diferentes em nós diferentes — resolver via [[decisions/0005]].
- **Atenção a concorrência:** `buffer` e `vectorial_time` são compartilhados entre as threads de recepção e escrita **sem lock** — ver anti-pattern relacionado e ADR-0004.

## Trade-offs

| Aspecto | Custo | Benefício |
|---|---|---|
| Latência | Mensagens esperam no buffer até dependências chegarem | Causalidade garantida |
| Corretude | Só ordem causal (parcial), não total | Base correta para ordem total |
| Concorrência | Estado compartilhado exige lock (ainda ausente) | — |

## Como detectar uso correto (opcional)

- Sinal de uso: função `can_deliver` + `buffer` reavaliado em laço após cada entrega.
- Falha comum: incrementar o vetor na recepção antes de decidir a entrega (a convenção adotada não conta eventos de recepção no incremento — ver §5.2 do enunciado).

## Related

- **Intent:** `context/intent/project-intent.md` (R4)
- **ADRs:** `context/decisions/0003-envelope-mensagem-json.md`, `context/decisions/0004-concorrencia-threads.md`, `context/decisions/0005-ordem-total-abordagem.md`
- **Patterns:** `context/knowledge/patterns/own-echo-filter.md`
- **Anti-patterns:** `context/knowledge/anti-patterns/non-daemon-threads-no-shutdown.md`
- **Buglog:** *nenhum*
- **Standard relacionado:** `context/code-standards.md` (lock em estado compartilhado)
