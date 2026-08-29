# Trabalho 1 — Sistemas Distribuídos (UNIVALI) · Status Técnico Completo

> **Como usar este documento (para o GPT):** este é um dump de contexto autossuficiente de um trabalho acadêmico de Sistemas Distribuídos. Contém os requisitos, o código-fonte atual, as decisões de projeto (fechadas e em aberto) e o que ainda falta. Use-o para me ajudar a: (1) escolher e implementar a **ordem total (§5.3)**, (2) implementar o **estado global (§5.5)**, (3) fechar as decisões em aberto com justificativa, e (4) redigir o relatório técnico. As seções marcadas com ⬅️ são onde mais preciso de ajuda.

- **Disciplina:** Sistemas Distribuídos — UNIVALI (Prof. Ramicés dos Santos Silva)
- **Tema escolhido:** Chat distribuído (comunicação de grupo, ordem total, estado global)
- **Stack:** Python 3, apenas biblioteca padrão (`socket`, `threading`, `json`, `struct`, `sys`, `time`) + launcher PowerShell
- **Repositório:** `GuilhermeMohr/Sistemas-Distribuidos-Chat` (branch `main`)
- **Equipe:** até 4 alunos
- **Prazos:** Entrega 1 (código + relatório, via AVA) **09/09/2026** · Entrega 2 (slides + seminário) **16/09/2026**
- **Snapshot deste documento:** 2026-08-29 · commit atual `faf894c`

---

## 1. Objetivo do trabalho

Construir um sistema distribuído de **comunicação de grupo com múltiplos nós** (configurável para **15+ nós**) que implementa:

1. **Comunicação de grupo** por mensagens de rede.
2. **Ordem total** das mensagens difundidas (todos os nós entregam na mesma sequência).
3. **Estado global** consistente (snapshot).

Objetivos de aprendizagem: relógios lógicos (Lamport) e vetoriais; distinguir **ordem causal (parcial)** de **ordem total**; comunicação de grupo com primitivas de rede; captura de estado global consistente; (opcional) eleição de líder.

### Regra de ouro (constraint central)

> **Somente troca de mensagens de rede.** É PROIBIDO usar memória compartilhada, banco/arquivo comum, variável global entre threads ou serviço externo como canal de coordenação entre nós. Cada nó é um **processo independente** com estado privado. **Exceção:** um arquivo de configuração estático (`nos.json` — catálogo de endereços) lido na inicialização é permitido.

Foco de avaliação: **middleware de comunicação/ordenação/estado global**, não a riqueza da aplicação. Interface de terminal é suficiente.

---

## 2. Requisitos avaliáveis (R1–R8) e status atual

| # | Requisito | Como demonstrar | Status |
|---|---|---|---|
| **R1** | Comunicação de grupo (multicast) | Mensagem de grupo de um nó chega a todos | ✅ **Feito** — multicast UDP, grupo `239.0.0.1:50000` |
| **R2** | Tema: chat distribuído | Funcionalidade operante entre nós | ✅ **Feito** |
| **R3** | Nº de nós configurável ≥ 15 | Iniciar com 3, 8 e 15 nós **sem alterar código** | ❌ **Falta** — `run.ps1` hardcoda 3; não há `nos.json` |
| **R4** | Ordem total via relógio vetorial | Todos os nós entregam na MESMA ordem | 🟡 **Parcial** — relógio vetorial + entrega **causal** prontos (§5.2); falta **ordem total (§5.3)** ⬅️ |
| **R5** | Tela do nó | Enviar unicast, enviar grupo, ordem local, ordem global | 🟡 **Parcial** — envio de grupo e unicast (`receiver`) prontos; falta exibir ordem local e ordem global |
| **R6** | Estado global | Comando dispara captura de estado global consistente e exibe | ❌ **Falta (§5.5)** ⬅️ |
| **R7** | Relatório detalhado | Documento com todos os itens da §10 | ❌ **Falta** |
| **R8** | Eleição de líder (se adotada) | Passo a passo + reeleição ao cair o líder | ⚪ **Opcional** — só se escolher Abordagem B na §5.3 |

---

## 3. Fundamentos técnicos exigidos pelo enunciado (resumo)

### 3.1 Relógio de Lamport (escalar)
Contador inteiro `C` por nó. Evento local/envio: `C = C + 1`. Recepção com carimbo `Cm`: `C = max(C, Cm) + 1`. Limitação: dá ordenação consistente com a causalidade, mas não detecta concorrência.

### 3.2 Relógio vetorial
Cada nó `i` mantém vetor `V` de tamanho N. Regras:
- **Ao enviar:** `V[i] = V[i] + 1`; anexa cópia de `V` à mensagem.
- **Ao receber** msg com vetor `Vm` de origem `k`: primeiro decide se pode entregar; ao entregar, `V[j] = max(V[j], Vm[j])` para todo `j`, e `V[i] = V[i] + 1`.
- Convenção adotada: eventos de recepção **não** incrementam o vetor de imediato (só a entrega). O essencial é que a política seja consistente e documentada.

**Condição de entrega causal (buffer de delivery):** mensagem `m` de origem `k` com carimbo `Vm` só pode ser entregue no nó `i` quando:
- `Vm[k] == V[k] + 1` (é a próxima esperada de `k` — respeita FIFO da origem), **e**
- `Vm[j] <= V[j]` para todo `j != k` (todas as mensagens que causalmente precedem `m` já foram entregues).

Enquanto não satisfeitas, `m` fica num **buffer de espera**; a cada entrega, reavalia-se o buffer.

### 3.3 O ponto central: ordem causal × ordem total ⬅️ (§5.3)
O relógio vetorial **sozinho** garante apenas **ordem causal** (parcial): mensagens **concorrentes** podem ser entregues em ordens diferentes em nós diferentes. A atividade exige **ordem total** (mesma sequência em todos os nós). É preciso um critério extra. **Escolher UMA abordagem e justificar no relatório:**

**Abordagem A — Relógio vetorial + desempate determinístico**
- Chave de ordenação sugerida: `chave(m) = (soma(Vm), id_do_no_de_origem, contador_local_da_origem)`. Compara por soma dos componentes do vetor (relógio escalar derivado); empate → id do nó; depois → contador local.
- Cada nó só entrega uma mensagem quando tem certeza de que nenhuma com chave menor ainda pode chegar (estabilidade / ACKs). Normalmente exige mensagens periódicas de batimento/ACK para não travar por silêncio.
- **Vantagem:** totalmente descentralizado, sem ponto único de falha. **Custo:** maior latência, mais mensagens de controle, cuidado com deadlock por silêncio.

**Abordagem B — Sequenciador / super-servidor eleito**
- Um nó atua como sequenciador: recebe as mensagens de grupo e atribui/difunde um número de sequência global. Todos entregam na ordem do número de sequência. O sequenciador é escolhido por **eleição de líder** (Bully ou Anel) e sua queda **exige reeleição** (R8).
- **Vantagem:** ordem total simples e eficiente; casa com estado global e eleição. **Custo:** ponto crítico (líder), distancia-se do "via relógio vetorial" puro.

### 3.4 Eleição de líder (obrigatória se Abordagem B; opcional na A)
- **Bully (Valentão):** ao notar queda do líder (timeout), o nó envia ELEIÇÃO aos de ID maior; se ninguém maior responde, declara-se líder (COORDENADOR); o maior ID ativo vence.
- **Anel:** nós em anel lógico; quem detecta a falha circula mensagem de eleição acumulando o maior ID; ao retornar à origem, o maior ID é o novo líder.

### 3.5 Estado global ⬅️ (§5.5)
Capturar uma "fotografia" coerente de todos os nós. Recomendado: **snapshot de Chandy-Lamport**:
1. Um iniciador registra seu próprio estado e envia um **MARCADOR** por todos os canais de saída.
2. Ao receber o **primeiro** MARCADOR, o nó registra seu estado, marca como vazio o canal por onde o marcador chegou e propaga o MARCADOR pelos seus canais de saída.
3. Para os demais canais, grava as mensagens recebidas entre o registro do seu estado e a chegada do marcador daquele canal (estado do canal).
4. Termina quando todos registraram estado e todos os canais foram contabilizados.

Alternativa: variante centralizada (líder consulta todos e agrega) — justificar trade-off simplicidade × ponto único.

---

## 4. Estado atual da implementação

### 4.1 Arquitetura
- **1 processo = 1 nó.** Identidade via argumento CLI (`process_id`).
- **Transporte:** multicast UDP no grupo `239.0.0.1`, porta `50000`. Ingressa no grupo em todas as interfaces (`SO_REUSEADDR` + `bind("")` + `IP_ADD_MEMBERSHIP` em `0.0.0.0`).
- **Envelope JSON:** `{ "id": <origem>, "message": <texto>, "receiver": <0=grupo | id destino>, "vectorial_time": {<id>: <contador>} }`.
- **Concorrência interna:** 2 threads por nó — recepção (`receive_multicast`) e escrita/UI (`write`) — sobre o mesmo socket.
- **Ordenação:** relógio vetorial (`vectorial_time`) + **buffer de entrega causal** (`buffer` + `can_deliver`). Isto garante **ordem causal**, **não** total.
- **Unicast:** campo `receiver` (0 = difusão a todos; senão só o nó destino imprime).

### 4.2 O que já funciona
- Difusão de grupo (R1) e envio direcionado a um nó (parte de R5).
- Relógio vetorial e entrega causal com buffer (R4 / §5.2).
- Filtro de eco próprio (o nó ignora as mensagens que ele mesmo enviou).

### 4.3 O que NÃO funciona ainda
- **Ordem total (§5.3)** — só há ordem causal. ⬅️
- **Estado global (§5.5)** — inexistente. ⬅️
- **Configuração de N nós ≥ 15 (R3)** — sem `nos.json`; launcher fixo em 3.
- **Tela (R5)** — não exibe ordem local nem ordem global (fila de delivery).
- **Robustez UDP** — sem tratamento de perda/duplicação/reordenação (sem `seq` por origem).

---

## 5. Código-fonte atual (completo)

### 5.1 `multicast.py` (140 linhas)

```python
import socket
import threading
import json
import sys
import struct
import time

# Const
MULTICAST_GROUP = "239.0.0.1"
MULTICAST_PORT = 50000

def create_multicast_socket():
    multicast_socket = socket.socket(
        socket.AF_INET,
        socket.SOCK_DGRAM,
        socket.IPPROTO_UDP
    )

    multicast_socket.setsockopt(
        socket.SOL_SOCKET,
        socket.SO_REUSEADDR,
        1
    )

    multicast_socket.bind(
        ("", MULTICAST_PORT)
    )

    membership = struct.pack(
        "4s4s",
        socket.inet_aton(MULTICAST_GROUP),
        socket.inet_aton("0.0.0.0")
    )

    multicast_socket.setsockopt(
        socket.IPPROTO_IP,
        socket.IP_ADD_MEMBERSHIP,
        membership
    )

    return multicast_socket

def can_deliver(message):
    message_id = message['id']
    message_vectorial_time = message['vectorial_time']
    
    # Próxima mensagem esperada
    if message_vectorial_time[message_id] != vectorial_time.get(message_id, 0) + 1:
        return False

    # Dependências causais entregues
    for key in message_vectorial_time:
        if key != message_id and message_vectorial_time[key] > vectorial_time.get(key, 0):
            return False
        
    return True

def receive_multicast(multicast_socket):
    while True:
        try:
            data, address = multicast_socket.recvfrom(1024)
            message = json.loads(data.decode("utf-8"))

            # Ignora mensagens do proprio processo
            if (message['id'] == process_id):
                continue

            buffer.append(message)

            while True:
                delivered = False

                for message in buffer[:]:
                    if can_deliver(message):
                        buffer.remove(message)
                        message_id = message["id"]

                        # Atualiza vectorial_time
                        message_vectorial_time = message['vectorial_time']
                        for key in message_vectorial_time:
                            value = message_vectorial_time[key]
                            if key not in vectorial_time:
                                vectorial_time[key] = value
                            else:
                                vectorial_time[key] = max(vectorial_time[key], value)
                        vectorial_time[process_id] += 1
                        
                        delivered = True

                        if (message['receiver'] != 0 and message['receiver'] != process_id):
                            continue

                        print(f"Mensagem recebida: {message['message']}\n")

                if not delivered:
                    break
        except Exception as error:
            print(f"Error: {error}\n")

def write(multicast_socket):
    while True:
        print("Enviar mensagem: ")
        vectorial_time[process_id] = vectorial_time[process_id]+1
        message = {
            "id": process_id,
            "message": input(),
            "receiver": 0,
            "vectorial_time": vectorial_time
        }

        print("Enviar mensagem em grupo? (s - Sim / id do processo - Nao)")
        input_message = input()

        if (input_message != "s"):
            message['receiver'] = int(input_message)
        
        try:
            broadcast(multicast_socket, message)
        except:
            print("ERRO!\n")

def broadcast(multicast_socket, message):
    multicast_socket.sendto(json.dumps(message).encode("utf-8"), (MULTICAST_GROUP, MULTICAST_PORT))


# Começo das execucoes
process_id = sys.argv[1]
vectorial_time = {
    process_id: 0
}
buffer = []

print(process_id)

multicast_socket = create_multicast_socket()

threading.Thread(target=receive_multicast, args=(multicast_socket,)).start()

time.sleep(2)

threading.Thread(target=write, args=(multicast_socket,)).start()
```

### 5.2 `run.ps1` (launcher — sobe 3 nós; PRECISA virar configurável para R3)

```powershell
1..3 | ForEach-Object {
    Start-Process python -ArgumentList "./multicast.py $_"
}
```

---

## 6. Decisões de projeto

### 6.1 Fechadas (Accepted)
- **Multicast UDP** para comunicação de grupo (grupo `239.0.0.1:50000`). Justificativa para o relatório: difusão de grupo nativa e eficiente.
- **Python 3, stdlib pura** (sem dependências).
- **Envelope JSON** com `id`, `message`, `receiver`, `vectorial_time`.
- **Concorrência por threads** (recepção + escrita) — *Provisional*: falta camada de entrega ordenada dedicada e **locks**.

### 6.2 EM ABERTO (precisam ser fechadas — impactam o relatório §10.8/§10.9) ⬅️
- **DECISÃO 1 — Ordem total (§5.3): Abordagem A (relógio vetorial + desempate) vs B (sequenciador eleito).** É "a decisão de projeto mais importante do trabalho". Recomendação a discutir com o GPT: a entrega causal já existe, então **Abordagem A** é o caminho de menor esforço incremental (adiciona critério de ordenação total + estabilidade sobre o buffer atual, sem precisar de eleição de líder). **Abordagem B** é conceitualmente mais simples de ordenar mas obriga eleição de líder + tratamento de queda (R8).
- **DECISÃO 2 — Estado global (§5.5): Chandy-Lamport vs variante centralizada.** Chandy-Lamport é o recomendado e respeita "somente rede"; a variante centralizada acopla ao líder (só faz sentido se escolher a Abordagem B).

---

## 7. O que falta implementar (backlog priorizado)

1. **[R4/§5.3] Ordem total** ⬅️ — fechar a Decisão 1 e implementar. Se Abordagem A: adicionar chave de ordenação total + condição de **estabilidade** (só entregar quando nenhuma mensagem de chave menor puder chegar) + mensagens de batimento/ACK para não travar por silêncio. Critério de corretude: **as filas de delivery ordenadas devem ser idênticas em todos os nós**.
2. **[R6/§5.5] Estado global** ⬅️ — fechar a Decisão 2 e implementar snapshot (Chandy-Lamport recomendado) disparável por comando de menu, exibindo o estado capturado.
3. **[R3] Configuração ≥ 15 nós** — criar `nos.json` (grupo, porta, lista de nós id/host/porta) lido na inicialização; trocar `run.ps1` por launcher que gera `nos.json` e sobe 3/8/15 nós sem alterar código. Inicializar o vetor com todos os N ids conhecidos.
4. **[R5] Tela do nó** — exibir **ordem local** (sequência em que o nó emitiu/observou eventos) e **ordem global** (fila de delivery ordenada pela ordem total). Sugestão: também mostrar o relógio vetorial atual e o buffer de espera.
5. **[R7] Relatório** — ver estrutura na seção 9.
6. **[R8] (Se Abordagem B)** — eleição de líder (Bully ou Anel) + demonstração de reeleição ao cair o líder.

---

## 8. Dívida técnica (corrigir junto com o backlog)

- **Estado compartilhado sem lock:** `buffer` e `vectorial_time` são lidos/escritos pelas threads de recepção e escrita **sem `threading.Lock`** → race condition ao escalar para 15 nós (o commit se chama "vectorial lock" mas não há lock de fato). Proteger com um `Lock`.
- **`except:` nu** em `write()` (`multicast.py:119`) — engole o erro real e pode capturar `KeyboardInterrupt`. Trocar por `except Exception as e:` (o `receive_multicast` já usa a forma correta).
- **Threads não-daemon + `while True`** sem shutdown gracioso — dificulta encerrar 15 nós; usar `threading.Event` e/ou `daemon=True` e fechar o socket.
- **`process_id` é string** (`sys.argv[1]`), mas a Abordagem A de desempate compara por id — definir se o desempate é numérico ou lexicográfico e ser consistente.
- **UDP não confiável:** sem `seq` por origem nem detecção de lacunas/retransmissão — documentar como limitação no relatório e/ou tratar.
- **Buffer `recvfrom(1024)`** pode ser pequeno para vetores de 15+ posições — validar; o enunciado sugere 65536.

---

## 9. Estrutura obrigatória do relatório (Entrega 1 — §10)

O relatório deve conter, no mínimo:
1. Descrição do problema e do tema escolhido.
2. Papel de cada membro da equipe.
3. Arquitetura da solução (componentes, diagrama, fluxo de mensagens).
4. Endereços de rede utilizados (faixa, IPs, portas e a tabela de nós).
5. Simulações realizadas (cenários, nº de nós, prints das filas de delivery mostrando a ordem global idêntica).
6. Limitações do modelo escolhido (perdas em UDP/multicast; ponto único no sequenciador; latência na Abordagem A).
7. Tecnologia e linguagem utilizadas e como executar.
8. **Passo a passo do algoritmo de ordem total (com exemplo numérico)** e, se adotado, do algoritmo de eleição de líder.
9. Justificativa do mecanismo de estado global escolhido.

---

## 10. Onde preciso de ajuda do GPT (perguntas específicas)

1. **Ordem total (§5.3):** dado que a entrega causal já está implementada (seção 5.1), qual a forma mais limpa de estender para **ordem total pela Abordagem A**? Preciso do algoritmo de estabilidade (quando é seguro entregar) e de como evitar deadlock por silêncio com mensagens de batimento. Escrever o código Python integrando ao `buffer`/`can_deliver` atuais.
2. **Exemplo numérico:** produzir um exemplo com 2–3 nós e mensagens **concorrentes** mostrando os dois nós chegando à **mesma ordem global** — para o relatório (§10.8).
3. **Estado global (§5.5):** implementar Chandy-Lamport sobre multicast UDP respeitando "somente rede" — como modelar "canais" e os MARCADORes neste cenário de difusão? Código + comando de menu para disparar e exibir o snapshot.
4. **Config ≥15 nós (R3):** desenhar `nos.json` e o launcher (Python ou PowerShell) para 3/8/15 nós sem alterar código, e como inicializar o vetor vetorial com todos os ids.
5. **Concorrência:** onde exatamente colocar o(s) `Lock` para proteger `buffer` e `vectorial_time` sem travar a recepção.
6. **Revisão do relatório** conforme a estrutura da seção 9.

> Observação: manter a restrição de **somente mensagens de rede** (nada de estado compartilhado entre processos; `nos.json` estático é permitido).
