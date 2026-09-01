# Sensors — Sistemas-Distribuidos-Chat

> Sinais automáticos/manuais que indicam saúde do código. Projeto stdlib-only sem
> lint/formatter/CI configurados no bootstrap — sensores abaixo são o mínimo viável.

| Sensor | Tool | Command | Signal |
|---|---|---|---|
| Sintaxe | CPython | `python -m py_compile multicast.py` | Falha = erro de sintaxe |
| Corretude ordem total + snapshot + perda | pytest-less | `python test_ordem_total.py` | `TODOS OS TESTES PASSARAM` (concorrente/causal/duplicata/snapshot/retransmissão) |
| Recuperação de perda (real) | manual | subir N nós com `DROP_PROB=0.3` no ambiente | Ordem global converge idêntica apesar da perda (retransmissão) |
| Smoke multi-nó | manual | `pwsh ./run.ps1 -Nodes 3` (ou N terminais `python multicast.py <id>`) | Mensagem de grupo de um nó aparece nos demais |
| Escala (R3) | manual | `run.ps1 -Nodes 3|8|15` (gera `nos.json` e sobe N) sem alterar código | Todos ingressam no grupo; **filas de delivery idênticas** (§8) |

## How Model Should React

- **`py_compile` falha** → corrigir sintaxe antes de qualquer outra coisa.
- **Smoke falha (mensagem não chega)** → verificar firewall/roteamento multicast local, `SO_REUSEADDR`, TTL e membership (ver [[knowledge/patterns/multicast-membership-all-interfaces]]).
- **Filas de delivery divergem entre nós** → bug na camada de ordenação total (R4); é o defeito mais crítico do projeto. Revisar relógio vetorial + critério de desempate + condição de entrega/estabilidade.
- **Sensores automáticos ausentes** → à medida que o projeto matura, considerar adicionar `ruff`/`flake8` e testes (`pytest`); registrar via `/brainiac-context-decision` se adotados.
