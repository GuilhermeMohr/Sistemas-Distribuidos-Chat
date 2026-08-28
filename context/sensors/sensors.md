# Sensors — Sistemas-Distribuidos-Chat

> Sinais automáticos/manuais que indicam saúde do código. Projeto stdlib-only sem
> lint/formatter/CI configurados no bootstrap — sensores abaixo são o mínimo viável.

| Sensor | Tool | Command | Signal |
|---|---|---|---|
| Sintaxe | CPython | `python -m py_compile multicast.py` | Falha = erro de sintaxe |
| Smoke multi-nó | manual | `pwsh ./run.ps1` (ou 3 terminais `python multicast.py <id>`) | Mensagem de grupo de um nó aparece nos demais |
| Corretude ordem total (R4) | manual | Rodar simulação com mensagens concorrentes | **Filas de delivery ordenadas idênticas em todos os nós** (critério de corretude do enunciado §8) |
| Escala (R3) | manual | Iniciar 3, 8 e 15 nós via `nos.json` sem alterar código | Todos ingressam no grupo e trocam mensagens |

## How Model Should React

- **`py_compile` falha** → corrigir sintaxe antes de qualquer outra coisa.
- **Smoke falha (mensagem não chega)** → verificar firewall/roteamento multicast local, `SO_REUSEADDR`, TTL e membership (ver [[knowledge/patterns/multicast-membership-all-interfaces]]).
- **Filas de delivery divergem entre nós** → bug na camada de ordenação total (R4); é o defeito mais crítico do projeto. Revisar relógio vetorial + critério de desempate + condição de entrega/estabilidade.
- **Sensores automáticos ausentes** → à medida que o projeto matura, considerar adicionar `ruff`/`flake8` e testes (`pytest`); registrar via `/brainiac-context-decision` se adotados.
