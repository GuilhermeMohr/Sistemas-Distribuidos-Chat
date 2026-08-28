# Anti-pattern: Threads não-daemon em laço infinito sem encerramento

- **Detectado em:** 2026-08-26 22:54 UTC-03:00
- **Origem:** archeology pass do bootstrap Brainiac (`multicast.py:43-79`)
- **Severidade típica:** média — dificulta encerramento limpo e liberação de recursos
- **Last updated:** 2026-08-26 22:54 UTC-03:00

## O problema

As threads de recepção e escrita rodam `while True` sem condição de parada e são criadas como não-daemon, sem `join` nem sinalização de shutdown.

- O que aconteceu (manifestação técnica): `receive_multicast` e `write` fazem `while True` indefinidamente; as threads são iniciadas sem `daemon=True` e sem mecanismo de parada.
- Por que é ruim: o processo não encerra de forma limpa; o socket pode não ser fechado; Ctrl-C pode deixar threads penduradas; testes com 15 nós ficam difíceis de derrubar em massa.
- Em qual condição reproduz: ao tentar encerrar um nó (Ctrl-C) ou orquestrar start/stop de muitos nós.

## Manifestação histórica

- **2026-08-26** — `multicast.py:44` e `:57` (`while True`) + `:75`/`:79` (threads sem `daemon`/`join`). Custo: encerramento não-determinístico; recursos de socket não liberados explicitamente. Referência: `multicast.py:43-79`.

## O que evitar

- ❌ `threading.Thread(target=...).start()` sem `daemon=True` quando não há `join` nem shutdown.
- ❌ `while True:` sem `Event`/flag de parada em threads de longa duração.
- ❌ Não fechar o socket ao encerrar.

## Alternativa correta

- ✅ Usar `threading.Event` como sinal de parada: `while not stop_event.is_set(): ...`.
- ✅ Marcar threads de background como `daemon=True` quando apropriado, e/ou fazer `join` no encerramento.
- ✅ Fechar o socket em `finally` / no shutdown. Por que resolve: encerramento previsível e liberação de recursos — importante para orquestrar 3/8/15 nós (R3).

## Como detectar (opcional)

- Regex sugerida: `while True:`
- Palavras-chave para grep: `Thread(`, `while True`, `daemon`
- Ferramenta automatizada: revisão manual / reviewer agent.

## Related

- **Intent:** `context/intent/project-intent.md` (R3)
- **ADRs:** `context/decisions/0004-concorrencia-threads.md`
- **Patterns:** *nenhum*
- **Anti-patterns:** *nenhum (este é um anti-pattern)*
- **Buglog:** *nenhum*
- **Standard relacionado:** `context/code-standards.md`
