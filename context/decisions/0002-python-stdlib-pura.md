# ADR-0002 — Python 3 com stdlib pura (sem dependências)

- **Created:** 2026-08-26 22:54 UTC-03:00
- **Last updated:** 2026-08-26 22:54 UTC-03:00
- **Status:** Accepted
- **Decision-makers:** equipe (inferido via archeology pass — Confidence 🟢 High)

## Context

O enunciado (§6) sugere Python pela facilidade com sockets e concorrência, mas a linguagem é livre. É preciso escolher a stack de implementação.

**Source of inference:** `multicast.py:1-6` importa apenas módulos da stdlib (`socket`, `threading`, `json`, `sys`, `struct`, `time`). Não há `requirements.txt`, `pyproject.toml` nem lock file no repositório.

## Decision

Implementar em **Python 3 usando exclusivamente a biblioteca padrão** — `socket`, `threading`, `json`, `struct`, `sys`, `time`. Sem dependências externas nem gerenciador de pacotes.

## Alternatives considered

### Alternativa A — Python 3 + stdlib pura (escolhida)
**Pró:** sockets e threads nativos, zero setup, portátil, alinhado à sugestão do enunciado. **Contra:** sem frameworks de rede de alto nível (tudo manual).

### Alternativa B — Outra linguagem (Java, Go, C#, Node.js)
Aceitas pelo enunciado. **Contra:** maior curva/setup para a equipe; nenhuma vantagem decisiva para um trabalho focado em middleware de ordenação. Rejeitada.

## Consequences

### Positive

- Setup zero: basta `python multicast.py <id>`.
- Portabilidade e simplicidade de avaliação.

### Negative

- Confiabilidade/ordenação precisam ser implementadas manualmente sobre UDP. Mitigação: é justamente o objetivo pedagógico do trabalho.

## Outcomes

**Outcomes recorded:** —

## Related

- **Intent:** `context/intent/project-intent.md` (Tech Stack)
- **ADRs:** `context/decisions/0001-comunicacao-grupo-multicast-udp.md`
- **Patterns:** *nenhum*
- **Anti-patterns:** *nenhum*
- **Buglog:** *nenhum*

## Status history

| Timestamp | Status | Reason |
|---|---|---|
| 2026-08-26 22:54 UTC-03:00 | Accepted | Decisão já implementada; registrada retroativamente via archeology pass |
