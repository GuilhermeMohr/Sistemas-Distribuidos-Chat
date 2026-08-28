# Anti-pattern: `except:` nu que engole erros

- **Detectado em:** 2026-08-26 22:54 UTC-03:00
- **Origem:** archeology pass do bootstrap Brainiac (`multicast.py:66`)
- **Severidade típica:** média — esconde falhas de envio e dificulta depuração
- **Last updated:** 2026-08-26 22:54 UTC-03:00

## O problema

Um `except:` sem tipo captura **qualquer** exceção (incluindo `KeyboardInterrupt`/`SystemExit`) e a substitui por uma mensagem genérica, escondendo a causa real.

- O que aconteceu (manifestação técnica): em `write()`, o envio é envolvido por `try/except:` que imprime apenas `ERRO!`, sem o erro real.
- Por que é ruim: perde-se a stack/tipo do erro; falhas de serialização ou de socket ficam indistinguíveis; pode capturar sinais de interrupção e atrapalhar o encerramento.
- Em qual condição reproduz: qualquer exceção dentro do bloco (falha de `sendto`, JSON inválido, etc.).

> Nota: `receive_multicast` já usa `except Exception as error` (forma correta). O `except:` nu remanescente está apenas em `write()`.

## Manifestação histórica

- **2026-08-26** — `multicast.py:117-120`: `try: broadcast(...) except: print("ERRO!\n")`. Custo: diagnóstico cego de falhas de envio. Referência: `multicast.py:119` (posição após commit `faf894c`).

## O que evitar

- ❌ `except:` sem especificar o tipo da exceção.
- ❌ Substituir a exceção por mensagem genérica sem logar o erro real.
- ❌ Capturar amplamente ao redor de código que inclui pontos de interrupção do usuário.

## Alternativa correta

- ✅ Capturar o tipo esperado e incluir o erro: `except OSError as e: print(f"{process_id}: erro de envio: {e}")`.
- ✅ Se precisar capturar amplo, usar `except Exception as e:` (não o `except:` nu) para não engolir `KeyboardInterrupt`/`SystemExit`.
- ✅ Por que resolve: preserva tipo/mensagem do erro e mantém o encerramento por Ctrl-C funcionando.

## Como detectar (opcional)

- Regex sugerida: `except\s*:`
- Palavras-chave para grep: `except:`
- Ferramenta automatizada: `ruff`/`flake8` (regra `E722 do not use bare except`).

## Related

- **Intent:** `context/intent/project-intent.md`
- **ADRs:** `context/decisions/0002-python-stdlib-pura.md`
- **Patterns:** *nenhum*
- **Anti-patterns:** *nenhum (este é um anti-pattern)*
- **Buglog:** *nenhum*
- **Standard relacionado:** `context/code-standards.md`
