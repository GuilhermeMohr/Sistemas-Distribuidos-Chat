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

> **⚠️ A CONFIRMAR PELA EQUIPE.** A divisão abaixo é uma sugestão baseada no histórico de commits do repositório. Ajustem os nomes e a distribuição conforme a realidade da equipe (até 4 integrantes).

| Integrante | Contribuição principal |
|---|---|
| **Guilherme Mohr** | Camada de rede inicial (socket multicast UDP, ingresso no grupo), envio de mensagem de grupo e unicast (`receiver`), primeira versão do relógio vetorial e entrega causal. |
| **Arthur Hawreliuk** | Reestruturação para **ordem total** (chave total + ACK de estabilidade + hold-back queue), **estado global** (snapshot de Chandy-Lamport), infraestrutura de nós (`nos.json` + launcher configurável), testes automatizados e documentação técnica. |
| *(integrante 3)* | *a definir* |
| *(integrante 4)* | *a definir* |

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
        └────sendto──┼── DATA      ACK        MARKER              │
                     │    │         │            │                │
                     │    ▼         ▼            ▼                │
                     │  ┌──────────────────┐  ┌──────────────┐    │
                     │  │  classe Node      │  │  snapshot     │   │
                     │  │  (state_lock)     │  │ Chandy-Lamport│   │
                     │  │  holdback_queue   │  └──────────────┘    │
                     │  │  acks             │                      │
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
                                   │
                          cada nó: on_data()
                                   │  guarda na holdback_queue
                                   │  envia ACK ──multicast──► todos
                                   ▼
                          cada nó: on_ack() acumula acks[msg]
                                   │
                          try_deliver(): entrega quando a mensagem é o
                          TOPO por total_key E todos os nós deram ACK
                                   ▼
                          delivery_order (idêntica em todos os nós)
```

### 3.4 Formato das mensagens (envelope JSON)

| Campo | Descrição |
|---|---|
| `type` | `DATA`, `ACK` ou `MARKER` |
| `id` | identificador do nó de origem |
| `message_id` | `"origem:seq"` (seq = componente da origem no vetor) |
| `message` | conteúdo (apenas em `DATA`) |
| `receiver` | `0` = grupo; caso contrário, id do destino (unicast) |
| `vectorial_time` | relógio vetorial no momento do envio (apenas em `DATA`) |

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
| Snapshot | Chandy-Lamport com 3 nós | ✅ todos concluem, estado consistente |

### 5.2 Testes ponta-a-ponta (multicast real)

| Nº de nós | Cenário | Resultado |
|---|---|---|
| 3 | 2 mensagens de grupo concorrentes | ✅ ordem global `[1:1, 2:1]` idêntica nos 3 |
| 15 | 2 mensagens de grupo concorrentes | ✅ ordem global idêntica nos 15 |
| 8 | snapshot global disparado por um nó | ✅ 8/8 concluem com estado consistente |

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

- **UDP não confiável:** multicast pode perder, duplicar ou reordenar datagramas. A solução trata **duplicação** (deduplicação por `message_id`) e **reordenação** (hold-back queue + FIFO por origem), mas **não implementa recuperação/retransmissão de mensagens perdidas** — isto está fora do escopo. Consequência: um `DATA`, `ACK` ou `MARKER` perdido estagna a entrega/snapshot daquela origem/canal.
- **Custo de controle da Abordagem A:** o ACK de estabilidade gera O(N²) mensagens de controle por difusão no grupo. É aceitável para 15 nós, mas aumenta a latência de entrega (uma mensagem só é entregue após o ACK de todos).
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

A equipe adotou a **Abordagem A** do enunciado: **relógio vetorial + critério de ordenação total determinístico + confirmação de estabilidade (ACK)** sobre uma fila de espera (hold-back queue). **Não** há sequenciador nem eleição de líder.

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

### 8.3 Condição de entrega (estabilidade por ACK)

Ordenar pela chave **não basta**: sob rede assíncrona, uma mensagem de chave menor pode ainda estar em trânsito. A entrega usa a técnica do **multicast totalmente ordenado de Lamport**:

1. Ao receber uma `DATA`, o nó a coloca na hold-back queue e **difunde um `ACK`** para o grupo.
2. Cada nó acumula, por mensagem, o conjunto de nós que a confirmaram (o próprio emissor conta como confirmação).
3. Uma mensagem `m` só é **entregue** quando: (a) é o **topo** da fila por `total_key`, **e** (b) **todos os nós conhecidos** confirmaram `m`, **e** (c) respeita o FIFO da origem (sem lacuna).

Como todos os nós usam a mesma chave e só entregam mensagens estáveis (confirmadas por todos), a sequência de entrega — a `delivery_order` — é **idêntica em todos os nós**.

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

após os `ACK`s tornarem `M1` e `M2` **estáveis** (confirmadas por todos), os três nós entregam na mesma ordem:

```
Nó 1 → [M1, M2]
Nó 2 → [M1, M2]
Nó 3 → [M1, M2]
```

Ordem total alcançada. *(Este resultado foi reproduzido em teste real com 3 e 15 nós — ver seção 5.)*

### 8.5 Eleição de líder

Não se aplica: a Abordagem A é totalmente descentralizada e não usa sequenciador. Portanto não há eleição de líder (R8 é opcional nesse caso).

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

- [x] Equipe com até 4 integrantes; papéis descritos *(confirmar nomes na seção 2)*.
- [x] Sistema inicia com número configurável de nós e foi testado com 15.
- [x] Comunicação de grupo (multicast) funcionando e justificada.
- [x] Filas de delivery (ordem global) idênticas em todos os nós.
- [x] Tela do nó mostra envio unicast, envio de grupo, ordem local e ordem global.
- [x] Estado global pode ser capturado e exibido, com a escolha justificada.
- [x] Nenhuma memória/serviço compartilhado — só mensagens de rede.
- [ ] Relatório cobre todos os itens da Seção 10 *(este documento — revisar prints/nomes antes de submeter)*.
