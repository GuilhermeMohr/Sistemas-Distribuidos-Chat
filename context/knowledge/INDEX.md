# Knowledge INDEX

> Catálogo leve dos patterns + anti-patterns disponíveis em `context/knowledge/`.
> Cada entry lista metadata + triggers concretos para consulta proativa antes de
> uma ação sensível. O conteúdo completo de cada artefato fica nos arquivos
> individuais, carregado sob demanda (`Read`) quando um trigger casa com a tarefa.
>
> **Como é carregado:** os hooks `SessionStart` e `PostCompact` injetam este
> catálogo automaticamente no contexto quando o arquivo existe — a consulta não
> depende de leitura manual. O catálogo é leve de propósito; o conteúdo completo
> mora nos arquivos linkados e é lido só quando relevante (orçamento de contexto,
> Iron Law 7).
>
> **Quando consultar:** antes de editar um artefato sensível ou compartilhado,
> antes de uma decisão de design, antes de apresentar um plano, antes de declarar
> uma tarefa concluída.
>
> **Como consultar:** percorra os campos `Triggers`; quando um casar com a tarefa
> corrente, faça `Read` do arquivo linkado para o conteúdo completo (seções
> "O que evitar"/"Alternativa correta" no caso de anti-pattern; "Quando usar"/
> "Implementação" no caso de pattern).
>
> **Manutenção:** ao criar um pattern/anti-pattern novo no Learn (No Limbo Rule),
> adicione uma entry aqui no mesmo passo. Quando o arquivo de origem declara o
> campo opcional `Triggers` no metadata, reaproveite-o aqui.

---

## Schema da entry

```text
### `<slug-do-arquivo>`
- **Status:** <experimental | estável | consolidado>
- **Família:** <categoria curta que agrupa artefatos correlatos | —>
- **Sintoma em 1 linha:** <o que o artefato previne ou resolve, em uma frase>
- **Triggers:** <2-5 palavras-chave/cenários concretos>
- **File:** [`<patterns|anti-patterns>/<slug>.md`](<patterns|anti-patterns>/<slug>.md)
```

---

## Anti-patterns

<!--
Adicione uma entry por arquivo em anti-patterns/, seguindo o schema acima. Exemplo:

### `example-anti-pattern-slug`
- **Status:** estável
- **Família:** <família | —>
- **Sintoma em 1 linha:** <descrição observável do problema que o anti-pattern evita>
- **Triggers:** <cenário 1>, <cenário 2>, <cenário 3>
- **File:** [`anti-patterns/example-anti-pattern-slug.md`](anti-patterns/example-anti-pattern-slug.md)
-->

### `bare-except-error-swallow`
- **Status:** estável
- **Família:** tratamento de erros
- **Sintoma em 1 linha:** `except:` nu esconde a causa real de falhas.
- **Triggers:** escrever/editar `try/except`, tratamento de erro em envio de socket, mensagem de erro genérica
- **File:** [`anti-patterns/bare-except-error-swallow.md`](anti-patterns/bare-except-error-swallow.md)

### `non-daemon-threads-no-shutdown`
- **Status:** estável
- **Família:** concorrência / ciclo de vida
- **Sintoma em 1 linha:** threads `while True` não-daemon sem parada impedem encerramento limpo.
- **Triggers:** criar `threading.Thread`, laço `while True` de longa duração, encerramento de nó, orquestrar múltiplos nós
- **File:** [`anti-patterns/non-daemon-threads-no-shutdown.md`](anti-patterns/non-daemon-threads-no-shutdown.md)

### `total-order-sort-without-stability`
- **Status:** estável
- **Família:** ordenação / corretude
- **Sintoma em 1 linha:** ordenar a fila por chave total e entregar o topo sem condição de estabilidade (ACK) diverge entre nós.
- **Triggers:** implementar ordem total, `holdback_queue`, `total_key`, `sort`+`pop(0)`, entrega de mensagem, R4/§5.3
- **File:** [`anti-patterns/total-order-sort-without-stability.md`](anti-patterns/total-order-sort-without-stability.md)

## Patterns

<!--
Adicione uma entry por arquivo em patterns/, seguindo o mesmo schema da seção acima.
-->

### `own-echo-filter`
- **Status:** consolidado
- **Família:** multicast / recepção
- **Sintoma em 1 linha:** descarta a própria mensagem recebida via multicast comparando o id de origem.
- **Triggers:** loop de recepção multicast, processar mensagem recebida, filtrar remetente, evitar auto-eco
- **File:** [`patterns/own-echo-filter.md`](patterns/own-echo-filter.md)

### `multicast-membership-all-interfaces`
- **Status:** consolidado
- **Família:** multicast / socket setup
- **Sintoma em 1 linha:** configuração de socket para ingressar no grupo multicast e receber com vários nós na mesma máquina.
- **Triggers:** criar socket UDP multicast, `IP_ADD_MEMBERSHIP`, `SO_REUSEADDR`, bind de porta, rodar 3/8/15 nós locais
- **File:** [`patterns/multicast-membership-all-interfaces.md`](patterns/multicast-membership-all-interfaces.md)

### `causal-delivery-vector-clock-buffer`
- **Status:** experimental
- **Família:** ordenação / relógios lógicos
- **Sintoma em 1 linha:** relógio vetorial + buffer garantem ordem causal; base para a ordem total (§5.3).
- **Triggers:** editar `can_deliver`/`vectorial_time`/`buffer`, ordem causal vs total, entrega de mensagem de grupo, R4
- **File:** [`patterns/causal-delivery-vector-clock-buffer.md`](patterns/causal-delivery-vector-clock-buffer.md)

### `totally-ordered-multicast-ack-holdback`
- **Status:** consolidado
- **Família:** ordenação / relógios lógicos
- **Sintoma em 1 linha:** chave total + ACK de estabilidade + hold-back queue garantem ordem total sem líder.
- **Triggers:** implementar ordem total, `total_key`, `acks`, `try_deliver`, estabilidade, R4/§5.3
- **File:** [`patterns/totally-ordered-multicast-ack-holdback.md`](patterns/totally-ordered-multicast-ack-holdback.md)

### `chandy-lamport-snapshot-multicast`
- **Status:** consolidado
- **Família:** estado global / snapshot
- **Sintoma em 1 linha:** snapshot consistente via MARKER, com canais lógicos por origem sobre multicast.
- **Triggers:** implementar estado global, `MARKER`, `start_snapshot`/`on_marker`, canais lógicos, R6/§5.5
- **File:** [`patterns/chandy-lamport-snapshot-multicast.md`](patterns/chandy-lamport-snapshot-multicast.md)

### `reliable-multicast-nack-retransmission`
- **Status:** consolidado
- **Família:** confiabilidade / transporte
- **Sintoma em 1 linha:** recupera perda UDP (DATA e ACK) via NACK + reenvio de pendentes.
- **Triggers:** perda de pacote UDP, retransmissão, `NACK`, `retransmit_tick`, `message_store`, §13 do enunciado
- **File:** [`patterns/reliable-multicast-nack-retransmission.md`](patterns/reliable-multicast-nack-retransmission.md)

---

## Cobertura

> Mantenha o catálogo sincronizado com os arquivos em
> `context/knowledge/{patterns,anti-patterns}/`: toda entry deve apontar para um
> arquivo existente, e todo arquivo deve ter uma entry. Divergência entre o
> filesystem e este catálogo é detectável por lint de cobertura.

---

## Knowledge Gate rules (opcional)

> O hook `knowledge-gate.sh` (PreToolUse `Write|Edit`) interpreta regras
> declaradas no bloco abaixo para exigir consulta a um pattern/anti-pattern antes
> de editar paths de risco do **seu** projeto. **É opt-in:** sem regras no bloco,
> o gate é no-op. As regras são policy LOCAL — o hook canonical não conhece nenhum
> slug; toda a policy mora aqui.
>
> Schema (1 objeto JSON por linha, entre os markers):
>
> - `id` — identificador estável da regra.
> - `mode` — `block` (exige evidência de consulta) | `advisory` (só imprime aviso).
> - `path_regex` — regex contra o path do edit, relativo ao project root (normalizado `/`).
> - `knowledge_path` — SÓ `context/knowledge/{patterns,anti-patterns}/<slug>.md` (sem secrets, sem `../`).
> - `summary` — risco em 1 linha.
> - `action` — o que fazer antes do edit, em 1 linha.
>
> Fail-closed: linha não-JSON entre os markers → o gate bloqueia (policy quebrada
> não vira bypass silencioso); `mode=block` com `knowledge_path` inválido/ausente
> → bloqueia. **Evidência de consulta** = `Read` do `knowledge_path` OU `@ref`
> exato ao arquivo. Bypass: `BRAINIAC_KNOWLEDGE_GATE_BYPASS=true` +
> `BRAINIAC_KNOWLEDGE_GATE_BYPASS_REASON` (≥12 chars) via shell env ou
> `.claude/settings.local.json` (nunca na `settings.json` versionada).
>
> Exemplo de uma linha de regra (não copie literalmente — declare as suas):
> `{"id":"<id>","mode":"block","path_regex":"^<rel-regex>$","knowledge_path":"context/knowledge/anti-patterns/<slug>.md","summary":"<risco>","action":"<o que fazer>"}`

<!-- BRAINIAC:KNOWLEDGE-GATE-RULES-START -->
<!-- BRAINIAC:KNOWLEDGE-GATE-RULES-END -->
