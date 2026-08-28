# AGENTS.md — Sistemas-Distribuidos-Chat

> Roteador para agentes de IA. Leia este arquivo ANTES de qualquer tarefa.
> Este projeto adota **Brainiac Context** v1.50.0.

<!-- BRAINIAC:CANONICAL-START version=1.50.0 | Managed by /brainiac-context-update — DO NOT EDIT manually.
     The framework spec imported below is the authoritative source of Brainiac rules.
     Customizations belong in the PROJECT:OVERRIDES block below.
     Bypass: rare, justified, with marker `brainiac-canonical-edit reason="..."`.
     The `version=X.Y.Z` attribute is the source of truth for the version of the
     canonical block; `/brainiac-context-update` keeps it in sync. -->

@context/.brainiac-context-framework.md

<!-- BRAINIAC:CANONICAL-END -->

<!-- PROJECT:OVERRIDES-START | Editable by humans. Preserved across /brainiac-context-update.
     Add project-specific rules, conventions, agents, limits below.
     This block is YOURS. -->

## Operating Mode

Modo default deste projeto: **Conversational**. Trabalho dirigido em natural language; IA classifica não-trivial e propõe captura (intent/ADR/pattern) antes de codar; espera confirm curto (`sim`, `vai`, `ajusta X`, `skip`).

Slash commands (`/brainiac-context-*`) permanecem disponíveis como escape hatch explícito — nunca deprecados.

Heurística canonical e exemplos: ver `## Operating Modes` em `.brainiac-context-framework.md` (auto-importado via canonical block acima).

Override project-specific (opcional): se este projeto prefere modo `guided` (full Socratic) ou tem critérios non-trivial customizados, documente aqui.

## Project Identity

- **Nome**: Sistemas-Distribuidos-Chat
- **Descrição**: Chat distribuído com comunicação de grupo, ordem total de mensagens e estado global. Trabalho 1 da disciplina de Sistemas Distribuídos (UNIVALI, Prof. Ramicés dos Santos Silva).
- **Domínio**: Sistemas Distribuídos — comunicação de grupo, relógios lógicos/vetoriais, ordenação total, snapshot de estado global (acadêmico)
- **Stack**: Python 3 (stdlib: `socket`, `threading`, `json`, `struct`, `sys`, `time`) + launcher PowerShell (`run.ps1`)
- **Tipo**: Projeto acadêmico (Trabalho de graduação — equipe de até 4 alunos)

## Project Operational Rules

Regras específicas deste projeto (numeradas — adicione conforme necessário):

1. **Somente troca de mensagens de rede** (regra do enunciado §2). É PROIBIDO usar memória compartilhada, banco/arquivo comum, variável global entre threads ou serviço externo como canal de coordenação entre nós. Cada nó é um **processo independente** com estado privado em memória.
2. **Exceção de configuração estática:** um arquivo `nos.json` (catálogo de endereços: grupo multicast, porta, lista de nós com id/host/porta) lido na inicialização é permitido — é catálogo de endereços, não canal de coordenação em runtime.
3. **Nº de nós configurável ≥ 15** (R3): a solução deve iniciar com 3, 8 e 15 nós **sem alterar código**. Não hardcodar quantidade de nós.
4. **Concorrência interna com threads/locks:** dentro de cada nó, separar (a) escuta de rede, (b) processamento/entrega ordenada, (c) interface de usuário. Proteger estruturas internas compartilhadas (buffer de delivery, relógio vetorial) com locks.
5. **UDP não é confiável:** ao usar multicast, tratar perda/duplicação/reordenação na camada de ordenação (números de sequência por origem, detecção de lacunas). Documentar a limitação no relatório (§10.6).
6. **Foco em corretude do middleware** (comunicação + ordenação + estado global) antes de recursos extras — interface de terminal é suficiente (§Dica de escopo do enunciado).
7. **Toda decisão de projeto exigida pelo relatório vira ADR** em `context/decisions/` (multicast×unicast, Abordagem A×B de ordem total, mecanismo de estado global, eleição de líder). O relatório da Entrega 1 é derivado dos artefatos Brainiac.

## Project Artifacts Map (extras além do framework)

Tabela é opcional — preencha apenas com tipos de artefato que o projeto adiciona ou customiza além do que o framework já define em `context/`:

| Artefato | Local | Responsável |
|---|---|---|
| Código do nó | `multicast.py` (raiz) | Build |
| Launcher multi-nó | `run.ps1` (raiz) / futuro script Python | Build |
| Catálogo de endereços | `nos.json` (raiz, a criar) | Build |
| Relatório da Entrega 1 (§10) | a definir (derivado de `context/`) | equipe |

## Project Limits

- **Prazos (fixos):** Entrega 1 (código + relatório, via AVA) **09/09/2026** · Entrega 2 (slides + seminário, em aula) **16/09/2026**.
- **Escopo:** middleware de comunicação/ordenação/estado global. A riqueza da aplicação de chat NÃO é avaliada — priorizar corretude de ordem total e estado global.
- **Equipe:** até 4 alunos; o relatório deve descrever o papel de cada membro (§10.2).
- **Sem persistência/serviços externos** como canal de coordenação (ver Operational Rule 1).

## Project Agents (Extensions)

Agents específicos deste projeto em `context/agents/project/`. Canonicals (`brainiac/`) são listados no framework spec; aqui ficam só os project-owned.

Nenhuma extension ainda. Criar via `/brainiac-context-agent`.

## Source of Truth Hierarchy

Enunciado do trabalho (PDF UNIVALI) > Brainiac Context (`context/`) > Código > Tarefas ad-hoc.

> O enunciado (`Trabalho M1 - Roteiro Implementação + Relatório.pdf`) define os requisitos avaliáveis R1–R8 e é a autoridade sobre o *que* entregar; o Brainiac Context é a autoridade sobre *como* o projeto decidiu implementar.

## Project Environment

```env
# Projeto stdlib-only sem variáveis de ambiente ou segredos.
# Configuração de rede (grupo multicast, porta, lista de nós) vive em nos.json (catálogo estático).
```

**Importante:** Nunca commitar `.env` ou `.env.local`. Adicione ao `.gitignore`.

<!-- PROJECT:OVERRIDES-END -->

---

## References

- [Brainiac Context Framework](https://github.com/kaleldias/Brainiac-Context/blob/main/.brainiac-context-framework.md) — Especificação completa
- [CODE_STANDARDS.md](https://github.com/kaleldias/Brainiac-Context/blob/main/CODE_STANDARDS.md) — Contrato universal de qualidade
- [SECURITY_STANDARDS.md](https://github.com/kaleldias/Brainiac-Context/blob/main/SECURITY_STANDARDS.md) — Contrato universal de security gates
- [PROTOCOL.md (GitHub layer)](https://github.com/kaleldias/Brainiac-Context/blob/main/integrations/github/PROTOCOL.md) — Camada operacional GitHub
- Enunciado do trabalho: `~/Downloads/Trabalho M1 - Roteiro Implementação + Relatório.pdf` (fonte dos requisitos R1–R8)
- Lamport, L. "Time, Clocks, and the Ordering of Events in a Distributed System" (1978)
- Chandy, K. M.; Lamport, L. "Distributed Snapshots: Determining Global States of Distributed Systems" (1985)
