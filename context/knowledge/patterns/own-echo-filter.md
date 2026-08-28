# Pattern: Filtro de eco próprio em multicast

- **Validado em:** 2026-08-26 22:54 UTC-03:00
- **Origem:** archeology pass do bootstrap Brainiac (código em `multicast.py`)
- **Maturidade:** consolidado — presente e funcional no código atual
- **Last updated:** 2026-08-26 22:54 UTC-03:00

## O que é

Em multicast, o próprio remetente também recebe as mensagens que envia ao grupo. Este pattern descarta a cópia local comparando o `id` do remetente na mensagem com o `id` do próprio nó.

- Problema que resolve: nó exibir/processar sua própria mensagem como se fosse de outro.
- Mecanismo central: cada mensagem carrega `id` do remetente; na recepção, `if message['id'] == process_id: continue`.
- Por que vale formalizar: é uma armadilha recorrente em multicast; sem o filtro, ordenação e contagem ficam poluídas por auto-recepção.

## Quando usar

- Use quando: o socket ingressa no grupo multicast que ele mesmo usa para enviar (caso padrão de `IP_ADD_MEMBERSHIP` + `sendto` para o grupo).
- Use quando: cada mensagem já carrega identificação de origem (envelope JSON com `id`/`origem`).
- **Não use quando:** o design precisar que o nó também entregue localmente a própria mensagem pela mesma pipeline de ordenação (nesse caso, entregue localmente sem passar pela rede, ou trate a auto-entrega explicitamente na camada de ordem total).

## Implementação

```python
# multicast.py:62-66
message = json.loads(data.decode("utf-8"))

# Ignora mensagens do proprio processo
if (message['id'] == process_id):
    continue
```

Pontos-chave da implementação:

- O `id` de origem é obrigatório no envelope (ver `context/decisions/0003-envelope-mensagem-json.md`).
- Filtrar **antes** de qualquer processamento/ordenação.
- Atenção ao evoluir para R4: se a própria mensagem precisar entrar na ordem total, a auto-entrega deve ser tratada deliberadamente (não simplesmente descartada).

## Trade-offs

| Aspecto | Custo | Benefício |
|---|---|---|
| Correção | Depende de `id` confiável no envelope | Evita processar o próprio eco |
| Ordenação futura (R4) | Pode exigir auto-entrega explícita | Mantém a pipeline de rede limpa |

## Como detectar uso correto (opcional)

- Sinal de uso: `message['id'] == process_id` seguido de `continue`/early-return no laço de recepção.
- Falha comum (anti-pattern correlato): processar mensagem antes do filtro de origem.

## Related

- **Intent:** `context/intent/project-intent.md` (R1)
- **ADRs:** `context/decisions/0001-comunicacao-grupo-multicast-udp.md`, `context/decisions/0003-envelope-mensagem-json.md`
- **Patterns:** *nenhum (este é um pattern)*
- **Anti-patterns:** *nenhum*
- **Buglog:** *nenhum*
- **Standard relacionado:** *nenhum*
