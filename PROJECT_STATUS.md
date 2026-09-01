# Trabalho 1 — Sistemas Distribuídos (UNIVALI) · Status Técnico Completo

> **Como usar (para o GPT):** dump de contexto autossuficiente de um trabalho acadêmico de Sistemas Distribuídos. O middleware (R1–R6) está **implementado e testado**. Use este documento para me ajudar a **escrever o relatório técnico (R7)** conforme a estrutura da seção 9, incluindo o passo a passo do algoritmo com exemplo numérico. As seções ⬅️ são onde mais preciso de ajuda.

- **Disciplina:** Sistemas Distribuídos — UNIVALI (Prof. Ramicés dos Santos Silva)
- **Tema:** Chat distribuído (comunicação de grupo, ordem total, estado global)
- **Stack:** Python 3, apenas stdlib (`socket`, `threading`, `json`, `struct`, `sys`) + launcher PowerShell
- **Repositório:** `GuilhermeMohr/Sistemas-Distribuidos-Chat` · PR #2 (`feat/1-ordem-total`)
- **Prazos:** Entrega 1 (código + relatório) **09/09/2026** · Entrega 2 (slides + seminário) **16/09/2026**
- **Snapshot deste documento:** 2026-08-31 · branch `feat/1-ordem-total`

---

## 1. Objetivo e regra de ouro

Sistema de comunicação de grupo com **15+ nós** implementando: (1) comunicação de grupo, (2) **ordem total** das mensagens difundidas, (3) **estado global** consistente.

> **Regra central:** somente troca de mensagens de rede. Proibido memória/BD/arquivo compartilhado como canal de coordenação. Cada nó é um processo independente com estado privado. Exceção: `nos.json` (catálogo estático de endereços) lido na inicialização.

---

## 2. Requisitos avaliáveis (R1–R8) — status

| # | Requisito | Status |
|---|---|---|
| **R1** | Comunicação de grupo (multicast) | ✅ Feito — multicast UDP `239.0.0.1:50000` |
| **R2** | Tema chat distribuído | ✅ Feito |
| **R3** | Nº de nós configurável ≥ 15 | ✅ Feito — `nos.json` + `run.ps1 -Nodes`; validado 3 e 15 nós |
| **R4** | Ordem total (relógio vetorial + melhorias) | ✅ Feito — chave total + ACK de estabilidade + hold-back queue |
| **R5** | Tela do nó (unicast, grupo, ordem local, ordem global) | ✅ Feito — menu |
| **R6** | Estado global | ✅ Feito — snapshot Chandy-Lamport |
| **R7** | Relatório detalhado | ❌ **Falta** ⬅️ (é o próximo passo) |
| **R8** | Eleição de líder | ⚪ Não adotado (Abordagem A é sem líder) |

Validação: `test_ordem_total.py` (concorrente/causal/duplicata/snapshot) + testes reais de multicast com 3, 8 e 15 processos — **ordem global idêntica em todos os nós** e **snapshot consistente**.

---

## 3. Arquitetura

`multicast.py` — classe `Node` (protocolo/ordenação/snapshot/UI separados) + camada de rede + UI (menu de terminal).

```
recvfrom(65536) -> parse JSON -> dispatch por 'type'
    DATA   -> Node.on_data()  -> holdback_queue -> try_deliver()
    ACK    -> Node.on_ack()   -> acks           -> try_deliver()
    NACK   -> Node.on_nack()  -> retransmite DATA/ACK pedido
    MARKER -> Node.on_marker() -> snapshot Chandy-Lamport
```
Uma thread de retransmissão (~1s) reenvia DATA/ACK pendentes e emite NACK do que falta, recuperando perdas UDP (ver seção 8).

- **1 processo = 1 nó.** Identidade via `sys.argv[1]`; membros lidos de `nos.json`.
- **Concorrência:** 2 threads (recepção `daemon` + UI). Todo estado compartilhado no `Node`, protegido por um `threading.Lock` único; I/O e `print` fora do lock. Shutdown via `threading.Event` + `socket.close()`.
- **Envelope:** `type` (DATA|ACK|MARKER), `id` (origem), `message_id="origin:seq"` (`seq=V[origin]`), `message`, `receiver` (0=grupo), `vectorial_time`.

---

## 4. Ordem total (R4/§5.3) — como funciona

O relógio vetorial garante **ordem causal** (parcial). Para **ordem total** usa-se uma **chave determinística** + **estabilidade por ACK** sobre uma hold-back queue (multicast totalmente ordenado do Lamport). ⚠️ Ordenar por chave e entregar o topo **não basta** — é preciso a condição de estabilidade.

**Convenção do relógio vetorial:** envio incrementa a própria posição; entrega faz `max` componente a componente (recepção não incrementa) — assim `V[origem]` é exatamente a sequência da origem.

```python
@staticmethod
def total_key(message):
    v = message["vectorial_time"]
    return (sum(v.values()), int(message["id"]), v[message["id"]])

def _try_deliver(self):                 # com o lock
    delivered = []
    while self.holdback_queue:
        self.holdback_queue.sort(key=self.total_key)
        m = self.holdback_queue[0]
        mid, origin = m["message_id"], m["id"]
        seq = m["vectorial_time"][origin]
        if len(self.acks.get(mid, set())) < len(self.node_ids):
            break                       # estabilidade: falta ACK de alguém
        if seq != self.delivered_seq[origin] + 1:
            break                       # FIFO por origem (sem lacuna)
        self.holdback_queue.pop(0); self.delivered_seq[origin] = seq
        self.delivery_order.append(mid); delivered.append(m)
    return delivered
```

- Cada `DATA` recebida gera um `ACK` multicast; o emissor conta como ACK; a origem é adicionada por todos ao ver o `DATA`.
- Entrega quando: (a) topo por `total_key` **e** (b) `len(acks[mid]) == len(node_ids)` **e** (c) FIFO por origem.

### Exemplo numérico (para o relatório §10.8) ⬅️

3 nós, estado inicial `[0,0,0]`. `N1` envia `M1` → `V=[1,0,0]`; `N2` envia `M2` → `V=[0,1,0]` (concorrentes).

- `total_key(M1) = (1, 1, 1)`  ·  `total_key(M2) = (1, 2, 1)` → `M1 < M2` (empate na soma; desempate por origem).
- Mesmo que a rede entregue `M2` antes de `M1` em alguns nós (ordem **local** difere), após os ACKs tornarem ambas estáveis, **todos** entregam `[M1, M2]` (ordem **global** idêntica). Confirmado em teste real com 3 e 15 nós.

---

## 5. Estado global (R6/§5.5) — Chandy-Lamport

Snapshot consistente sem parar o sistema. **Canais lógicos modelados por origem** sobre o grupo multicast único (não há socket por canal).

- **Iniciador:** registra estado local + difunde `MARKER` + grava todos os canais de entrada.
- **1º MARKER recebido:** registra estado local, marca o canal de origem como vazio, propaga `MARKER`, grava os demais canais.
- **MARKER seguinte de um canal:** encerra a gravação daquele canal (estado do canal = DATA recebidas entre o registro local e o MARKER).
- **Conclui** quando recebeu `MARKER` de todos os outros nós.
- Estado capturado por nó: `vectorial_time`, `delivery_order`, `holdback`, `channel_state[j]`.

Validação: 3 e 8 nós reais concluem com `delivery_order` idêntica (estado consistente).

---

## 6. Tela do nó (R5) — menu

```
[1] Enviar mensagem de grupo      [2] Enviar mensagem para um nó
[3] Mostrar relógio vetorial      [4] Mostrar ordem local
[5] Mostrar ordem global          [6] Iniciar snapshot global
[7] Mostrar último snapshot       [0] Sair
```

Ordem **local** = ordem de eventos observados por este nó; ordem **global** = `delivery_order` (idêntica em todos). Unicast (`receiver != 0`) é ordenado em todos, mas só o destino exibe.

---

## 7. Como executar

```powershell
.\run.ps1 -Nodes 3     # gera nos.json com 3 nós e sobe 3 processos
.\run.ps1 -Nodes 15    # 15 nós, mesmo código
```
Manual / multiplataforma: `python multicast.py <id> nos.json` em N terminais.
Teste de corretude: `python test_ordem_total.py`.

---

## 8. Decisões (ADRs) e limitações

- **ADR-0001** Multicast UDP · **ADR-0002** Python stdlib · **ADR-0003** Envelope JSON.
- **ADR-0004** Concorrência: `Lock` único + threads daemon + shutdown.
- **ADR-0005** Ordem total = **Abordagem A** (relógio vetorial + chave total + ACK de estabilidade + hold-back). Sem líder.
- **ADR-0006** Estado global = **Chandy-Lamport** (canais lógicos por origem).

- **ADR-0007** Confiabilidade sobre UDP: retransmissão por NACK (recupera perda de DATA e ACK).

**Limitações (documentar no relatório §10.6):**
- UDP não confiável: dedup + hold-back + **retransmissão por NACK** recuperam duplicação, reordenação e **perda** (validado com 30% e 50% de perda). Limites restantes: **queda da origem** antes de retransmitir, e **MARKER de snapshot perdido**, não são recuperados.
- ACK de estabilidade custa O(N²) mensagens por difusão (aceitável para 15 nós; maior latência); NACKs adicionam tráfego sob perda.
- Tráfego multicast não é cifrado/autenticado (inerente ao trabalho).

---

## 9. Estrutura obrigatória do relatório (R7 — §10) ⬅️

1. Descrição do problema e do tema.
2. Papel de cada membro da equipe.
3. Arquitetura da solução (componentes, diagrama, fluxo de mensagens).
4. Endereços de rede (faixa, IPs, portas, tabela de nós).
5. Simulações (cenários, nº de nós, prints das filas de delivery idênticas).
6. Limitações do modelo (ver seção 8).
7. Tecnologia/linguagem e como executar (ver seção 7).
8. **Passo a passo do algoritmo de ordem total, com exemplo numérico** (ver seção 4).
9. Justificativa do mecanismo de estado global (Chandy-Lamport — ver seções 5 e ADR-0006).

---

## 10. Onde preciso de ajuda do GPT ⬅️

1. **Redigir o relatório (R7)** conforme a seção 9, expandindo o passo a passo da ordem total (seção 4) e do snapshot (seção 5) com linguagem acadêmica.
2. **Diagrama de arquitetura** (fluxo DATA → ACK → entrega; MARKER → snapshot) descrito em texto/ASCII para colar no relatório.
3. **Slides do seminário** (Entrega 2, 16/09) — roteiro a partir deste documento.
4. Revisão crítica das **limitações** (seção 8) — algo a acrescentar sobre corretude/robustez?
