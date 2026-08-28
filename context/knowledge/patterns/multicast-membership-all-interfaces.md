# Pattern: Ingresso em grupo multicast em todas as interfaces

- **Validado em:** 2026-08-26 22:54 UTC-03:00
- **Origem:** archeology pass do bootstrap Brainiac (código em `multicast.py`)
- **Maturidade:** consolidado — presente e funcional no código atual
- **Last updated:** 2026-08-26 22:54 UTC-03:00

## O que é

Configuração de socket UDP para ingressar em um grupo multicast e receber suas mensagens de forma robusta em ambiente local com múltiplos processos.

- Problema que resolve: receber tráfego multicast de forma confiável com vários nós na mesma máquina.
- Mecanismo central: `SO_REUSEADDR` + `bind("", PORTA)` + `IP_ADD_MEMBERSHIP` no grupo via interface `0.0.0.0` (todas as interfaces).
- Por que vale formalizar: a combinação exata dessas opções é sutil; erro em qualquer uma faz o nó não receber nada.

## Quando usar

- Use quando: múltiplos processos-nó rodam na mesma máquina e precisam todos receber o multicast (teste local com 3/8/15 nós — R3).
- Use quando: quer ligar o membership a todas as interfaces em vez de uma específica.
- **Não use quando:** precisar isolar por interface específica (troque `0.0.0.0`/`INADDR_ANY` pelo IP da interface desejada) ou precisar de `SO_REUSEPORT` em vez de `SO_REUSEADDR` em certas plataformas.

## Implementação

```python
# multicast.py:12-41
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("", MULTICAST_PORT))

membership = struct.pack(
    "4s4s",
    socket.inet_aton(MULTICAST_GROUP),   # 239.0.0.1
    socket.inet_aton("0.0.0.0"),         # todas as interfaces
)
s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)
```

Pontos-chave da implementação:

- `SO_REUSEADDR` permite múltiplos processos ligados à mesma porta na mesma máquina.
- `bind("", PORTA)` escuta em todas as interfaces locais.
- Endereço multicast na faixa `224.0.0.0`–`239.255.255.255` (aqui `239.0.0.1`, faixa administrativa local).
- Para testes entre máquinas, considere ajustar `IP_MULTICAST_TTL` (TTL baixo em localhost).

## Trade-offs

| Aspecto | Custo | Benefício |
|---|---|---|
| Portabilidade | `SO_REUSEADDR` vs `SO_REUSEPORT` varia por SO | Vários nós na mesma porta/máquina |
| Isolamento | `0.0.0.0` escuta tudo | Simplicidade em teste local |

## Como detectar uso correto (opcional)

- Sinal de uso: presença conjunta de `SO_REUSEADDR`, `bind(("", ...))` e `IP_ADD_MEMBERSHIP`.
- Falha comum: esquecer `SO_REUSEADDR` (segundo nó falha ao bindar) ou fazer bind no IP do grupo em vez de `""`.

## Related

- **Intent:** `context/intent/project-intent.md` (R1, R3)
- **ADRs:** `context/decisions/0001-comunicacao-grupo-multicast-udp.md`
- **Patterns:** `context/knowledge/patterns/own-echo-filter.md`
- **Anti-patterns:** *nenhum*
- **Buglog:** *nenhum*
- **Standard relacionado:** *nenhum*
