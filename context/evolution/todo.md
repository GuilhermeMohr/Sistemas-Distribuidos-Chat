# TODO — Sistemas-Distribuidos-Chat

Project backlog. Tracked items beyond active intents (research debt, follow-ups, future ADRs).

## Requisitos pendentes (do enunciado)

- [ ] **R3** — Configuração de nós ≥ 15 sem alterar código: criar `nos.json` (catálogo estático) + parametrizar `process_id`/lista de nós na inicialização. Substituir `run.ps1` hardcoded (3 nós) por launcher que gera `nos.json` para 3/8/15 nós.
- [x] **R4 (parte 5.2)** — Relógio vetorial + buffer de entrega causal (`can_deliver`) implementados por Guilherme (commit `faf894c`).
- [ ] **R4 (parte 5.3)** — **Ordem total**: fechar [[decisions/0005]] (Abordagem A vs B) e adicionar o critério de ordenação total sobre a entrega causal já existente. ⬅️ próximo foco.
- [x] **R5 (unicast)** — Envio p/ nó específico via campo `receiver` (0 = grupo) implementado (commit `8046d24`).
- [ ] **R5 (tela)** — Exibir ordem local e ordem global (fila de delivery ordenada idêntica em todos os nós).
- [ ] **R6** — Estado global (§5.5): fechar [[decisions/0006]] e implementar snapshot (Chandy-Lamport recomendado) disparável por comando de menu. ⬅️ pendente (Guilherme).
- [ ] **R7** — Relatório da Entrega 1 (§10): derivar dos artefatos `context/`.
- [ ] **R8** — (Se Abordagem B em 0005) eleição de líder (Bully ou Anel) + teste de reeleição ao cair o líder.

## Legacy debt (archeology pass — 2026-08-26)

- [ ] Corrigir `except:` nu em `write()` (`multicast.py:119`) — ver [[knowledge/anti-patterns/bare-except-error-swallow]].
- [ ] Threads não-daemon com `while True` sem shutdown gracioso — ver [[knowledge/anti-patterns/non-daemon-threads-no-shutdown]].
- [ ] **Estado compartilhado sem lock:** `buffer` e `vectorial_time` são lidos/escritos pelas threads de recepção e escrita sem `threading.Lock` — risco de race condition (viola Operational Rule 4 e ADR-0004). Proteger com lock.
- [ ] Envelope JSON: já tem `id/message/receiver/vectorial_time`; avaliar `seq` (sequência por origem) para detecção de lacunas UDP — ver [[decisions/0003]].
- [ ] Buffer fixo `recvfrom(1024)` — validar tamanho vs mensagens com vetor de 15+ posições; enunciado sugere 65536.
- [ ] Tratar não-confiabilidade UDP (perda/duplicação/reordenação) na camada de ordenação — Operational Rule 5.

## Infra / Segurança (não-bloqueante)

- [ ] `.gitignore` criado no bootstrap — revisar cobertura Python.
- [ ] [SEC] Documentar no relatório (§10.6) que o tráfego multicast é não-cifrado/não-autenticado (limitação inerente ao trabalho, não defeito).
- [x] Camada operacional GitHub aplicada (2026-08-28): labels canonical (8 famílias) + 5 labels `area:*` do projeto, templates `.github/` (issue/PR + branch-policy), bloco GitHub Operational Protocol no AGENTS.md.
- [ ] **GitHub Project** (Kanban Brainiac) — pulado no bootstrap (overhead p/ time acadêmico). Criar depois se o time quiser board.
- [ ] **Branch protection em `main`** — requer permissão **ADMIN** (só o dono `GuilhermeMohr` tem; sou WRITE). Guilherme deve aplicar via `/brainiac-context-github` ou nas settings do repo. Nota: hoje o time faz push direto em `main`; ativar proteção exige migrar p/ fluxo de PR.
