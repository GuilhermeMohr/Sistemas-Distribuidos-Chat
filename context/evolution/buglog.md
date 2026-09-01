# Buglog — Sistemas-Distribuidos-Chat

Bug log (L1 — always). Add entries via /brainiac-context-bugfix.

## 2026-09-01 — Ordem total diverge sob perda/reordenação (L2)

- **Sintoma:** com perda de pacotes injetada (50%), ~1 em 3 execuções um nó entregava `2:1` antes de `1:1`, enquanto outros entregavam `1:1` antes de `2:1` → **filas de delivery divergentes** (viola R4/§8).
- **Detecção:** teste e2e `orchestrate_loss.py 0.5`.
- **Causa raiz:** a condição de estabilidade implementada era *"todos os nós deram ACK nesta mensagem m"*. Isso **não** garante que nenhuma mensagem com chave menor ainda pode chegar — um nó podia estabilizar e entregar `2:1` antes de `1:1` (menor) ter chegado. Ver [[knowledge/anti-patterns/total-order-sort-without-stability]].
- **Correção:** condição canônica da Abordagem A — entregar `m` só quando, de **todo** nó ≠ origem, já se processou **em ordem FIFO** algo com chave **> m** (garante que nada menor pode chegar). Batimentos (`HEARTBEAT`) periódicos dão liveness; FIFO por origem (dedup + NACK) impede que um batimento posterior "fure" a ordem sob UDP não-FIFO. ACKs removidos. Ver [[decisions/0008]].
- **Validação:** 50% de perda 8/8 e 30% 3/3 convergem; regressão coberta por `teste_sem_entrega_prematura`.
- **Fix:** PR (issue #5), branch `fix/5-ordem-total-estabilidade`.
