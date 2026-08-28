# Sistemas-Distribuidos-Chat

Chat distribuído com comunicação de grupo, ordem total de mensagens e estado global, construído para o Trabalho 1 da disciplina de Sistemas Distribuídos (UNIVALI). Cada nó é um processo independente que se comunica apenas por mensagens de rede (multicast UDP), implementando relógio vetorial para ordenação total e snapshot de estado global. A solução é configurável para 15+ nós e serve de base para o relatório técnico e o seminário exigidos.

**Stack:** Python 3 (stdlib: `socket`, `threading`, `json`, `struct`) + launcher PowerShell

---

## Router

Este projeto adota o framework **Brainiac Context** v1.50.0. Toda instrução operacional, convenção, regras de workflow, code/security standards, GitHub Operational Protocol e regras project-specific estão em `AGENTS.md`.

@AGENTS.md

---

## Brainiac Commands disponíveis

Comandos mais úteis (skills do Brainiac Context):

| Comando | Quando usar |
|---|---|
| `/brainiac-context-feature` | Criar feature nova OU atualizar feature existente (intent + ADR + changelog) |
| `/brainiac-context-bugfix` | Documentar e corrigir bug (triage L1/L2/L3) |
| `/brainiac-context-build` | Implementar feature/bug documentado (Plan→Approve→Execute + branch + Draft PR) |
| `/brainiac-context-learn` | Learn step (Phase 1 Quality Gate + Phase 2 Knowledge Capture) |
| `/brainiac-context-decision` | Criar ADR avulsa em `context/decisions/` |
| `/brainiac-context-agent` | Criar Project Extension agent em `context/agents/project/` |
| `/brainiac-context-update` | Atualizar framework local pra versão canonical mais recente |
| `/brainiac-context-audit` | Detectar implementation drift entre código e `context/` docs |
| `/brainiac-context-lint` | Detectar documentation drift interno em `context/` |
| `/brainiac-context-github` | Configurar camada operacional GitHub (labels, Project, templates) |

Lista completa: `/help` ou ver `Brainiac-Context/skills/README.md`.

---

## Hooks Claude Code instalados

Hooks ativos via `.claude/settings.json` (instalados por `integrations/claude-code/install.sh`):

- **SessionStart** — carrega contratos do framework
- **UserPromptSubmit** — detecta trigger pattern e sugere skill apropriada
- **PreToolUse (Write|Edit)** — 3 gates:
  - `brainiac-canonical-gate.sh` — protege canonicals em `context/agents/brainiac/`
  - `brainiac-require-intent.sh` — exige Intent carregado antes de Edit de código
  - `brainiac-clean-code-gate.sh` — enforça SEC-1 + Clean Code hard gates
- **Stop** — Learn Gate + QA Gate

Mudar idioma das mensagens: editar `BRAINIAC_LANG` em `.claude/settings.json` (suportado: `en`, `pt-BR`).

---

## Onde começar

1. Leia `AGENTS.md` integralmente — ele é o roteador operacional
2. Verifique `context/intent/project-intent.md` — escopo, constraints, tech stack
3. Consulte `context/decisions/` — decisões técnicas já tomadas
4. Use os comandos Brainiac acima conforme o tipo de tarefa

---

## Compact Instructions

Se este arquivo está sendo lido após `/compact` ou `/clear`, releia `AGENTS.md` integralmente antes de prosseguir com trabalho crítico (Build, Learn, framework update, migração, refactor, bugfix complexo). Para tarefa simples em continuação, summary pós-compact é suficiente. Iron Law 7 detalha em `context/.brainiac-context-framework.md` (importado via AGENTS.md — fonte autoritativa).

**Regra-âncora:** nunca iniciar novo escopo em ou acima de 40% de uso do context window. Rode `/context` antes de trabalho crítico.
