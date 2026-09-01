# Project Intent — Sistemas-Distribuidos-Chat

## Visão

Chat distribuído em que cada nó é um processo independente que se comunica **exclusivamente por mensagens de rede** (multicast UDP). O sistema implementa **comunicação de grupo**, **ordem total** das mensagens difundidas (via relógio vetorial + critério de desempate) e captura de **estado global** consistente. Configurável para **15+ nós**. É o Trabalho 1 da disciplina de Sistemas Distribuídos (UNIVALI, Prof. Ramicés dos Santos Silva).

## Objetivo (What / Why)

Trabalho acadêmico. Objetivos de aprendizagem do enunciado:

- Compreender e implementar relógios lógicos (Lamport) e vetoriais na prática.
- Distinguir **ordem causal (parcial)** de **ordem total** e garantir ordem total das mensagens difundidas.
- Implementar comunicação de grupo com primitivas de rede (multicast).
- Modelar e capturar um **estado global consistente**.
- (Opcional) exercitar eleição de líder e o papel de coordenador/sequenciador.
- Projetar, documentar e defender oralmente uma solução distribuída.

## Tech Stack

Python 3 (stdlib: `socket`, `threading`, `json`, `struct`, `sys`, `time`) + launcher PowerShell (`run.ps1`). Sem dependências externas. Ver [[decisions/0002]].

## Requisitos funcionais (o que será avaliado)

| Req | Requisito | Como demonstrar | Estado |
|---|---|---|---|
| **R1** | Comunicação de grupo (multicast) | Mensagem de grupo de um nó chega a todos os demais | ✅ Implementado (`multicast.py`) — ver [[decisions/0001]] |
| **R2** | Tema: chat distribuído | Funcionalidade operante entre nós | ✅ Escolhido |
| **R3** | Nº de nós configurável ≥ 15 | Iniciar com 3, 8 e 15 nós sem alterar código | ✅ **Feito** — `nos.json` + `run.ps1 -Nodes`; validado com 3 e 15 nós reais |
| **R4** | **Ordem total via relógio vetorial** (Lamport + melhorias) | Todos os nós entregam as mensagens na MESMA ordem | ✅ **Feito** (§5.3) — relógio vetorial + `total_key` + ACK de estabilidade + hold-back queue ([[decisions/0005]]); ordem global idêntica validada |
| **R5** | Tela do nó | Envio p/ nó específico (unicast), envio p/ grupo, ordem local, ordem global | ✅ **Feito** — menu com unicast/grupo + relógio vetorial + ordem local + ordem global |
| **R6** | **Estado global** | Comando dispara captura de estado global consistente e exibe | ✅ **Feito** (§5.5) — snapshot Chandy-Lamport ([[decisions/0006]]); validado com 3 e 8 nós, estado consistente |
| **R7** | Relatório detalhado | Documento com todos os itens da §10 do enunciado | ❌ Pendente (derivado de `context/`) |
| **R8** | Eleição de líder (se adotada) | Passo a passo do algoritmo + reeleição ao cair o líder | ⚪ Opcional — só se Abordagem B em [[decisions/0005]] |

## Decisões de projeto

**Fechadas** (ver `context/decisions/`):
- [[decisions/0001]] — Comunicação de grupo por IP Multicast (UDP)
- [[decisions/0002]] — Python 3, stdlib pura
- [[decisions/0003]] — Envelope de mensagem JSON
- [[decisions/0004]] — Modelo de concorrência com threads

**Em aberto** (fechar durante o Build — o relatório §10.8/§10.9 exige justificativa):
- [[decisions/0005]] — **Ordem total: Abordagem A (relógio vetorial + desempate) vs B (sequenciador eleito)** — a decisão mais importante do trabalho
- [[decisions/0006]] — Estado global: Chandy-Lamport vs variante centralizada

## Constraints

- **Somente rede como canal de coordenação.** Proibido memória/BD/arquivo compartilhado ou serviço externo. Cada nó = processo independente com estado privado. Exceção: `nos.json` estático (catálogo de endereços lido na inicialização).
- **≥ 15 nós** configuráveis sem alterar código (R3).
- **UDP não confiável** — duplicação (dedup), reordenação (hold-back) e **perda (retransmissão por NACK, [[decisions/0007]])** tratadas. Limites restantes: queda da origem e MARKER perdido (documentar no relatório).
- **Prazos:** Entrega 1 (código + relatório) **09/09/2026** · Entrega 2 (slides + seminário) **16/09/2026**.
- **Equipe:** até 4 alunos; relatório descreve o papel de cada membro.
- **Escopo avaliado:** middleware de comunicação/ordenação/estado global — não a riqueza da app. Interface de terminal é suficiente.

## Source of Truth

Enunciado do trabalho (PDF UNIVALI) > Brainiac Context (`context/`) > Código > Tarefas ad-hoc.
