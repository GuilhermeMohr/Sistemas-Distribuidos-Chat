# Relatório Técnico — Trabalho 1
## Comunicação de Grupo, Ordem Total de Mensagens e Estado Global

**Universidade do Vale do Itajaí (UNIVALI)** — Disciplina de Sistemas Distribuídos
**Professor:** Ramicés dos Santos Silva
**Tema escolhido:** Chat distribuído
**Repositório:** github.com/GuilhermeMohr/Sistemas-Distribuidos-Chat
**Data:** setembro de 2026

---

## 1. Descrição do problema e do tema

O trabalho parte do problema clássico de **entrega ordenada de mensagens com relógios vetoriais** e o generaliza para um sistema distribuído de **comunicação de grupo** com múltiplos nós (configurável para 15 ou mais). Cada nó é um **processo independente** do sistema operacional, com estado privado em memória, que se comunica com os demais **exclusivamente por mensagens de rede** — não há memória compartilhada, banco de dados comum nem arquivo compartilhado atuando como canal de coordenação.

O tema escolhido foi o **chat distribuído**: um sistema de bate-papo em que cada nó é um participante que pode enviar mensagens de grupo (difusão a todos) e mensagens privadas (unicast a um nó específico). O requisito central é que as **mensagens de grupo sejam entregues na mesma ordem em todos os participantes** (ordem total), e que o sistema seja capaz de capturar um **estado global consistente** sob demanda.

O foco do trabalho — e desta solução — é o **middleware de comunicação e ordenação**, não a riqueza da aplicação de chat. A interface é de linha de comando (terminal).

---

## 2. Papel de cada membro da equipe

Equipe de 2 integrantes. Divisão de contribuições:

| Integrante | RA | Contribuição principal |
|---|---|---|
| **Guilherme Mohr** | _(a preencher)_ | Camada de rede (socket multicast UDP, ingresso no grupo), envio de mensagem de grupo e unicast (`receiver`), primeira versão do relógio vetorial e entrega causal. |
| **Arthur Hawreliuk** | _(a preencher)_ | Ordem total (chave total + hold-back + condição de estabilidade "ouvi-maior-de-todos" + batimentos), estado global (snapshot de Chandy-Lamport), confiabilidade sobre UDP (retransmissão por NACK), infraestrutura de nós (`nos.json` + launcher), testes automatizados e documentação técnica. |

---

## 3. Arquitetura da solução

### 3.1 Visão geral

Cada nó é um processo Python que executa `multicast.py`. O código separa quatro responsabilidades: **protocolo** (tipos de mensagem), **ordenação** (classe `Node`), **estado global** (snapshot) e **interface** (menu de terminal).

```
                     ┌───────────────────────────────────────────┐
                     │                  NÓ (processo)             │
  multicast UDP      │                                            │
  239.0.0.1:50000    │   thread de recepção        thread de UI   │
        │            │   ─────────────────         ────────────   │
        ▼            │   recvfrom(65536)              menu         │
  ┌───────────┐      │        │                        │          │
  │  GRUPO    │◄─────┼────────┼── sendto ◄─────────────┘          │
  │ multicast │      │        ▼                                   │
  └───────────┘      │   parse JSON → dispatch por 'type'         │
        ▲            │        │                                   │
        │            │   ┌────┴─────┬───────────┐                 │
        └──sendto──┼─ DATA  HEARTBEAT  NACK  MARKER               │
                     │    │         │            │                │
                     │    ▼         ▼            ▼                │
                     │  ┌──────────────────┐  ┌──────────────┐    │
                     │  │  classe Node      │  │  snapshot     │   │
                     │  │  (state_lock)     │  │ Chandy-Lamport│   │
                     │  │  holdback         │  └──────────────┘    │
                     │  │  fifo_frontier       │                      │
                     │  │  vectorial_time   │                      │
                     │  │  delivery_order   │                      │
                     │  └──────────────────┘                      │
                     └───────────────────────────────────────────┘
```

### 3.2 Componentes

- **Camada de rede:** um socket UDP inscrito no grupo multicast (`SO_REUSEADDR` + `SO_REUSEPORT` + `IP_ADD_MEMBERSHIP`). Uma thread dedicada faz `recvfrom` e despacha por tipo de mensagem.
- **Classe `Node` (ordenação):** mantém todo o estado compartilhado do nó, protegido por um único `threading.Lock`. Implementa a ordem total.
- **Snapshot (estado global):** implementa Chandy-Lamport sobre o mesmo canal multicast.
- **Interface (UI):** a thread principal exibe um menu e lê comandos do usuário.

### 3.3 Fluxo de mensagens (ordem total)

```
Nó A envia DATA ──multicast──► todos os nós
                                   │  processa em ordem FIFO por origem
                                   │  (dedup; fora de ordem → buffer + NACK)
                                   ▼
                          guarda na hold-back queue; atualiza fifo_frontier[A]
                                   │  (e emite um HEARTBEAT imediato)
        HEARTBEAT/DATA de cada nó ─┤  avançam fifo_frontier[nó]
                                   ▼
   try_deliver(): entrega m (menor chave) quando, de TODO nó != origem,
   já processou (FIFO) algo com chave > m
                                   ▼
                          delivery_order (idêntica em todos os nós)
```

### 3.4 Formato das mensagens (envelope JSON)

| Campo | Descrição |
|---|---|
| `type` | `DATA`, `HEARTBEAT`, `NACK` ou `MARKER` |
| `id` | identificador do nó de origem |
| `message_id` | `"origem:seq"` (seq = componente da origem no vetor) |
| `message` | conteúdo (apenas em `DATA`) |
| `receiver` | `0` = grupo; caso contrário, id do destino (unicast) — apenas em `DATA` |
| `vectorial_time` | relógio vetorial no momento do envio (`DATA`/`HEARTBEAT`) |

---

## 4. Endereços de rede utilizados

- **Comunicação:** IP Multicast sobre UDP (comunicação de grupo nativa).
- **Grupo multicast:** `239.0.0.1` (faixa administrativa local `239.0.0.0/8`).
- **Porta:** `50000`.
- **TTL:** padrão do sistema (testes em `localhost`).
- **Catálogo de nós:** arquivo estático `nos.json`, lido na inicialização (é o "catálogo de endereços" permitido pelo enunciado, não um canal de coordenação em runtime).

**Tabela de nós usada nas simulações** (exemplo com 3 nós; para 8 ou 15, a lista cresce analogamente):

| id | host | porta (grupo) |
|---|---|---|
| 1 | 127.0.0.1 | 50000 |
| 2 | 127.0.0.1 | 50000 |
| 3 | 127.0.0.1 | 50000 |

Exemplo do `nos.json`:

```json
{
  "multicast": { "group": "239.0.0.1", "port": 50000 },
  "nodes": [
    { "id": "1", "host": "127.0.0.1" },
    { "id": "2", "host": "127.0.0.1" },
    { "id": "3", "host": "127.0.0.1" }
  ]
}
```

---

## 5. Simulações realizadas

Foram executados testes automatizados (sem rede, validando a lógica) e testes ponta-a-ponta (com processos reais trocando multicast em `localhost`).

### 5.1 Testes de lógica (`test_ordem_total.py`)

| Cenário | Verificação | Resultado |
|---|---|---|
| Concorrente | 2 mensagens concorrentes chegando em ordens diferentes por nó | ✅ ordem global idêntica |
| Causal | mensagem B enviada após entrega de A | ✅ A precede B em todos |
| Duplicata | mesma `DATA` recebida 2× (UDP duplica) | ✅ entregue 1× |
| Sem entrega prematura | batimento posterior fora de ordem não pode liberar entrega antes da mensagem menor | ✅ segura até recuperar (regressão do bug) |
| Retransmissão | `DATA` perdida recuperada por NACK | ✅ entregue após retransmissão |
| Snapshot | Chandy-Lamport com 3 nós | ✅ todos concluem, estado consistente |

### 5.2 Testes ponta-a-ponta (multicast real)

| Nº de nós | Cenário | Resultado |
|---|---|---|
| 2, 3, 8, 15 | mensagens de grupo concorrentes | ✅ ordem global idêntica em todos os nós |
| 8 | snapshot global disparado por um nó | ✅ 8/8 concluem com estado consistente |
| 3 | **30% de perda** de pacotes injetada | ✅ converge (3/3 execuções) |
| 3 | **50% de perda** de pacotes injetada | ✅ converge (8/8 execuções) |

### 5.3 Evidência da ordem total (critério de corretude §8)

No cenário concorrente com 3 nós, a **ordem local** (ordem em que cada nó observou as mensagens chegando) **difere** entre os nós, mas a **ordem global** (fila de delivery após ordenação) é **idêntica**:

```
nó1: global=[1:1, 2:1]   local=[1:1, 2:1]
nó2: global=[1:1, 2:1]   local=[2:1, 1:1]   ← viu 2 antes de 1
nó3: global=[1:1, 2:1]   local=[2:1, 1:1]   ← viu 2 antes de 1
```

> **Nota para a defesa:** ao rodar a simulação, capturem prints da opção "[5] Mostrar ordem global" de cada nó mostrando as filas idênticas — é a principal evidência de que a ordem total funciona.

---

## 6. Limitações do modelo escolhido

- **UDP não confiável:** multicast pode perder, duplicar ou reordenar datagramas. A solução trata **duplicação** (deduplicação por `message_id`), **reordenação** (hold-back queue + FIFO por origem) e **perda** (retransmissão por NACK — ver seção 8.6). Limites restantes: se a **origem cai** antes de retransmitir uma mensagem que nenhum outro nó possui, ela se perde; a perda de um **MARKER** de snapshot não é recuperada. Validação: o sistema converge para a mesma ordem global mesmo com **30% e 50%** de perda de pacotes injetada.
- **Custo de controle da Abordagem A:** os batimentos (heartbeats) geram O(N²) mensagens de controle no grupo. É aceitável para 15 nós, mas aumenta a latência de entrega (uma mensagem só é entregue após ouvir "algo posterior" de todos os nós). Batimentos periódicos também incrementam continuamente o relógio/`seq` (crescimento do contador/`message_store`).
- **Ambiente:** os testes foram feitos em `localhost` (vários processos na mesma máquina). Multicast entre máquinas distintas depende de a rede/roteador permitirem tráfego multicast.
- **Segurança:** o tráfego multicast não é cifrado nem autenticado — limitação inerente ao escopo do trabalho.

---

## 7. Tecnologia e linguagem utilizadas + como executar

- **Linguagem:** Python 3, usando apenas a biblioteca padrão (`socket`, `threading`, `json`, `struct`, `sys`).
- **Launcher:** PowerShell (`run.ps1`).
- **Sem dependências externas.**

**Execução (Windows / PowerShell):**

```powershell
.\run.ps1 -Nodes 3      # gera nos.json com 3 nós e sobe 3 processos
.\run.ps1 -Nodes 8
.\run.ps1 -Nodes 15     # mesmo código, 15 nós
```

**Execução manual (qualquer SO):** em N terminais, `python multicast.py <id> nos.json`.

**Teste de corretude:** `python test_ordem_total.py`.

**Menu de cada nó (requisito R5):**

```
[1] Enviar mensagem de grupo      [2] Enviar mensagem para um nó
[3] Mostrar relógio vetorial      [4] Mostrar ordem local
[5] Mostrar ordem global          [6] Iniciar snapshot global
[7] Mostrar último snapshot       [0] Sair
```

---

## 8. Passo a passo do algoritmo de ordem total (com exemplo numérico)

A equipe adotou a **Abordagem A** do enunciado: **relógio vetorial + critério de ordenação total determinístico + condição de estabilidade** sobre uma fila de espera (hold-back queue), com **batimentos (heartbeats)** para liveness. **Não** há sequenciador nem eleição de líder.

### 8.1 Relógio vetorial

Cada nó mantém um vetor `V` com uma posição por nó conhecido. Convenção adotada (documentada e consistente):
- **Envio:** o nó incrementa a própria posição `V[i] += 1` e anexa uma cópia de `V` à mensagem.
- **Entrega:** o nó faz `V[j] = max(V[j], Vm[j])` para todo `j` (recepção não incrementa). Assim, `V[origem]` corresponde exatamente à sequência da origem.

O relógio vetorial garante **ordem causal** (parcial): mensagens concorrentes ainda podem ser entregues em ordens diferentes. Por isso é necessário o critério de ordem total.

### 8.2 Chave de ordenação total

Para cada mensagem define-se uma chave determinística, idêntica em todos os nós:

```
total_key(m) = ( soma(Vm),  id_da_origem,  Vm[origem] )
```

- `soma(Vm)` é um escalar derivado do vetor (cada envio incrementa exatamente uma posição). Não é um relógio de Lamport perfeito, mas serve como primeiro critério.
- O desempate por **id da origem** e depois pela **sequência da origem** transforma a ordem parcial (causal) em **ordem total**.

### 8.3 Condição de entrega (estabilidade correta)

Ordenar pela chave **não basta**: sob rede assíncrona, uma mensagem de chave menor pode ainda estar em trânsito. **Também não basta** exigir "todos confirmaram m" — isso não garante que nada menor ainda chegará (foi um bug real que corrigimos; ver seção 6 e o buglog). A condição **correta** da Abordagem A é:

> A mensagem `m` (a de **menor** chave na hold-back queue) é entregue quando, de **todo** nó `o ≠ origem(m)`, o nó já **processou em ordem FIFO** alguma mensagem (DATA ou HEARTBEAT) com **chave > chave(m)**.

Isso garante que nenhuma mensagem menor pode mais chegar de nenhum outro nó. Três peças tornam isso robusto sobre UDP:

1. **`fifo_frontier[o]`** = maior chave já processada **em ordem contígua** de cada nó `o`. Só avança pelo processamento FIFO.
2. **FIFO por origem** (`next_expected` + `reorder_buf` + deduplicação + NACK): uma mensagem fora de ordem é **bufferizada** e **não** avança `fifo_frontier` até a lacuna ser preenchida — assim um batimento posterior não "fura" a ordem sobre o UDP, que não é FIFO.
3. **Batimentos (HEARTBEAT)** periódicos: cada nó difunde batimentos que avançam o seu próprio progresso, para que nós silenciosos não travem a fila. Ao receber uma `DATA`, o nó também emite um batimento imediato (convergência rápida).

Como todos os nós usam a mesma chave e a mesma condição, a sequência de entrega — a `delivery_order` — é **idêntica em todos os nós**.

### 8.4 Exemplo numérico

Três nós, estado inicial `V = [0,0,0]`. `N1` envia `M1` e `N2` envia `M2` de forma **concorrente**:

```
M1: origem=1, V=[1,0,0]
M2: origem=2, V=[0,1,0]
```

Cálculo das chaves totais:

```
total_key(M1) = ( soma=1, origem=1, seq=1 ) = (1, 1, 1)
total_key(M2) = ( soma=1, origem=2, seq=1 ) = (1, 2, 1)
```

Como `(1,1,1) < (1,2,1)`, temos `M1 < M2`. Ainda que a rede entregue `M2` antes de `M1` em alguns nós:

```
Nó 1 recebe:  M1, M2
Nó 2 recebe:  M2, M1
Nó 3 recebe:  M2, M1
```

quando cada nó já ouviu de todos os outros (via DATA/batimento em ordem FIFO) algo com chave maior — tornando `M1` e `M2` **estáveis** — os três nós entregam na mesma ordem:

```
Nó 1 → [M1, M2]
Nó 2 → [M1, M2]
Nó 3 → [M1, M2]
```

Ordem total alcançada. *(Este resultado foi reproduzido em teste real com 3 e 15 nós — ver seção 5.)*

### 8.5 Eleição de líder

Não se aplica: a Abordagem A é totalmente descentralizada e não usa sequenciador. Portanto não há eleição de líder (R8 é opcional nesse caso).

### 8.6 Confiabilidade sobre UDP (tratamento de perdas)

Como o transporte é multicast UDP, a camada de ordenação trata os três problemas do UDP:

- **Duplicação:** cada mensagem tem `message_id = origem:seq`; datagramas repetidos são ignorados (deduplicação).
- **Reordenação:** a hold-back queue + FIFO por origem já garantem a ordem correta mesmo com chegada fora de ordem.
- **Perda:** retransmissão sob demanda por **NACK**. Uma thread periódica (a cada 1 s) difunde: (a) um **HEARTBEAT** (liveness, que também avança `fifo_frontier`); (b) um `NACK` para cada **lacuna** por origem (mensagem fora de ordem à espera no buffer); (c) o próprio `DATA` ainda não entregue (recupera a perda do 1º envio, cuja ausência não gera lacuna no destino). Ao receber um `NACK`, a **origem** reenvia a mensagem de fluxo pedida (DATA/HEARTBEAT). O processo é idempotente e limitado ao pendente, convergindo e parando quando tudo é entregue.

Este mecanismo foi validado injetando perda artificial de pacotes: com **30%** (3/3 execuções) e mesmo **50%** (8/8 execuções), todos os nós convergiram para a mesma ordem global — inclusive após a correção do bug de estabilidade descrito na seção 6.

---

## 9. Justificativa do mecanismo de estado global

A equipe escolheu o **algoritmo de snapshot de Chandy-Lamport**, em vez de uma variante centralizada, pelos motivos:

- É o algoritmo **canônico** para capturar um estado global **consistente** de um sistema distribuído.
- **Não exige parar o sistema** nem relógio sincronizado.
- **Não depende de coordenador permanente**, alinhando-se à arquitetura descentralizada já adotada na ordem total (sem líder) — evita introduzir um ponto único de falha só para o snapshot.
- **Respeita a restrição de comunicação exclusivamente por rede** (usa apenas mensagens `MARKER`).

### 9.1 Modelagem dos canais sobre multicast

O algoritmo pressupõe **canais direcionados** entre pares de processos. Como a solução usa um **único grupo multicast**, os canais são modelados **logicamente**: o canal de entrada `j → i` é identificado pela **origem da mensagem** (`message['id']`). Não se cria socket por canal — a abstração é suficiente para registrar o estado de cada canal.

### 9.2 Passo a passo

1. O nó **iniciador** registra seu estado local, difunde um `MARKER` e começa a gravar todos os seus canais de entrada.
2. Ao receber o **primeiro** `MARKER`, um nó registra seu estado local, marca como **vazio** o canal por onde o marcador chegou, propaga o `MARKER` e começa a gravar os demais canais.
3. Ao receber um `MARKER` **subsequente** de um canal, o nó **encerra** a gravação daquele canal — o estado do canal são as mensagens `DATA` recebidas dele entre o registro do estado local e a chegada do marcador.
4. O snapshot do nó termina quando ele recebeu `MARKER` de **todos** os outros nós.

Estado capturado por nó: relógio vetorial, ordem global de entrega (`delivery_order`), fila de espera e estado de cada canal. Nos testes com 3 e 8 nós, todos os nós concluíram o snapshot com `delivery_order` **idêntica**, evidenciando consistência.

---

## Anexo A — Checklist de autoavaliação (§12 do enunciado)

- [x] Equipe com até 4 integrantes (2: Guilherme Mohr, Arthur Hawreliuk); papéis descritos na seção 2.
- [x] Sistema inicia com número configurável de nós e foi testado com 15.
- [x] Comunicação de grupo (multicast) funcionando e justificada.
- [x] Filas de delivery (ordem global) idênticas em todos os nós.
- [x] Tela do nó mostra envio unicast, envio de grupo, ordem local e ordem global.
- [x] Estado global pode ser capturado e exibido, com a escolha justificada.
- [x] Nenhuma memória/serviço compartilhado — só mensagens de rede.
- [ ] Relatório cobre todos os itens da Seção 10 *(este documento — revisar prints/nomes antes de submeter)*.
