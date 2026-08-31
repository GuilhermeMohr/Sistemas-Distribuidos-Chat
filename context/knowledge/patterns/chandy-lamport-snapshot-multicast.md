# Pattern: Snapshot Chandy-Lamport sobre multicast (canais lógicos por origem)

- **Validado em:** 2026-08-31 19:08 UTC-03:00
- **Origem:** Build da feature ordem total (PR #2 / CP4); `multicast.py` classe `Node`
- **Maturidade:** consolidado — validado com 3 e 8 nós reais (todos concluem, estado consistente)
- **Last updated:** 2026-08-31 19:08 UTC-03:00

## O que é

Captura um estado global **consistente** de um sistema distribuído sem parar o sistema nem relógio sincronizado, usando apenas mensagens de rede (marcadores).

- Problema que resolve: fotografar estado dos nós + dos canais de forma coerente (R6).
- Mecanismo central: algoritmo de Chandy-Lamport com `MARKER`, modelando **canais lógicos direcionados por origem** sobre um único grupo multicast.
- Por que vale formalizar: sobre multicast não há "socket por canal" — a abstração "canal = origem da mensagem" é a chave para aplicar o algoritmo clássico.

## Quando usar

- Use quando: precisa de snapshot consistente num sistema já 100% baseado em mensagens.
- Use quando: os nós compartilham um grupo multicast e cada mensagem carrega sua origem.
- **Não use quando:** um coordenador central já pode ser confiável e simplicidade > descentralização (variante centralizada — descartada aqui, ver [[decisions/0006]]).

## Implementação

```python
def start_snapshot(self):                     # iniciador
    sid = f"{self.process_id}-{self._snap_counter}"
    self._record_local(sid, self.process_id)  # estado local + grava canais
    return {"type": "MARKER", "id": self.process_id,
            "snapshot_id": sid, "initiator": self.process_id}

def on_marker(self, message):
    sid, sender = message["snapshot_id"], message["id"]
    if sid not in self.snapshots:             # PRIMEIRO marker
        self._record_local(sid, message["initiator"])
        self.snapshots[sid]["recording"].discard(sender)  # canal de origem vazio
        forward = {"type": "MARKER", ...}     # propaga uma vez
    else:                                     # markers seguintes
        self.snapshots[sid]["recording"].discard(sender)  # encerra o canal
    self.snapshots[sid]["markers_from"].add(sender)
    # done quando markers_from >= todos os outros nós
```

Pontos-chave:

- **Estado do canal `j`** = mensagens `DATA` recebidas de `j` entre o registro do estado local e a chegada do `MARKER` de `j` (gravadas em `on_data` enquanto `j` está em `recording`).
- Cada nó propaga o `MARKER` **uma vez** (no primeiro recebimento) — o eco próprio é ignorado pelo `receive_loop`.
- Snapshot conclui quando o nó recebeu `MARKER` de **todos os outros** `node_ids`.

## Trade-offs

| Aspecto | Custo | Benefício |
|---|---|---|
| Complexidade | Gravação de canais + contagem de markers | Estado global consistente sem parar o sistema |
| Perdas UDP | MARKER perdido estagna o canal | Descentralizado, respeita "somente rede" |

## Como detectar uso correto (opcional)

- Sinal de uso: `on_marker` distingue primeiro marker (registra + propaga) de subsequentes (encerra canal).
- Falha comum: gravar no canal mensagens recebidas ANTES do registro local (violaria a consistência).

## Related

- **Intent:** `context/intent/feature-ordem-total.md` (R6)
- **ADRs:** `context/decisions/0006-estado-global-mecanismo.md`
- **Patterns:** `context/knowledge/patterns/totally-ordered-multicast-ack-holdback.md`
- **Anti-patterns:** *nenhum*
- **Buglog:** *nenhum*
- **Standard relacionado:** *nenhum*
