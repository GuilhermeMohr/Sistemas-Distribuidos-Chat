"""Fuzzer adversarial de ordem total: perda + reordenação aleatórias em N nós.

Verifica duas propriedades em muitas execuções pseudo-aleatórias:
- SAFETY (ordem total): para todo par de nós, a menor delivery_order é PREFIXO
  da maior — ou seja, ninguém entrega mensagens em ordem relativa divergente.
- LIVENESS: após a fase de dreno (sem perda), todos entregam todas as mensagens.

Inclui um cenário adversarial dirigido (recepção fora de ordem -> heartbeat
próprio "contaminado" -> tentativa de estabilidade falsa em outro nó), que
NÃO deve produzir divergência.

Rodar: python test_fuzz_ordem_total.py
"""
import random

from multicast import Node


def run_fuzz(seed, n_nodes=4, n_msgs=6, drop=0.35, drain=200000):
    rnd = random.Random(seed)
    ids = [str(i) for i in range(1, n_nodes + 1)]
    nodes = {i: Node(i, ids) for i in ids}
    inflight = []
    sent = set()

    def send(msg, drop_ok=True):
        src = msg["id"]
        for d in ids:
            if d == src:
                continue
            if drop_ok and rnd.random() < drop:
                continue
            inflight.append((d, msg))

    def deliver_one(drop_ok):
        i = rnd.randrange(len(inflight))
        dest, msg = inflight.pop(i)
        n = nodes[dest]
        t = msg["type"]
        if t in ("DATA", "HEARTBEAT"):
            n.on_stream(msg)
            if t == "DATA":
                send(n.make_heartbeat(), drop_ok)
        elif t == "NACK":
            for r in n.on_nack(msg):
                send(r, drop_ok)

    for _ in range(n_msgs):
        s = rnd.choice(ids)
        m = nodes[s].on_send(f"m-{s}", 0)
        sent.add(m["message_id"])
        send(m)

    for _ in range(4000):                       # fase caótica (com perda)
        if inflight and rnd.random() < 0.85:
            deliver_one(drop_ok=True)
        else:
            for i in ids:
                for msg in nodes[i].retransmit_tick():
                    send(msg, drop_ok=True)
        if not inflight and all(not nodes[i].holdback for i in ids):
            break

    for _ in range(drain):                       # dreno (sem perda)
        if inflight:
            deliver_one(drop_ok=False)
        else:
            pend = any(nodes[i].holdback for i in ids)
            gaps = any(nodes[i].reorder_buf[o] for i in ids for o in ids)
            if not pend and not gaps:
                break
            for i in ids:
                for msg in nodes[i].retransmit_tick():
                    send(msg, drop_ok=False)

    seqs = [nodes[i].delivery_order for i in ids]
    safety = all(a[:min(len(a), len(b))] == b[:min(len(a), len(b))]
                 for a in seqs for b in seqs)
    completo = all(set(s) == sent for s in seqs)
    return safety, completo, {i: nodes[i].delivery_order for i in ids}


def teste_cenario_adversarial():
    """Recepção fora de ordem -> heartbeat contaminado NÃO fura a ordem total."""
    ids = ["1", "2", "3"]
    nodes = {i: Node(i, ids) for i in ids}
    o1 = nodes["1"].on_send("O1", 0)
    o2 = nodes["1"].on_send("O2", 0)
    nodes["2"].on_stream(o2)                      # nó2 recebe O2 fora de ordem
    nodes["2"].make_heartbeat()                   # heartbeat "contaminado"
    for msg in (o1, o2):                          # recuperação completa
        for d in ids:
            if d != msg["id"]:
                nodes[d].on_stream(msg)
    for _ in range(50):
        for i in ids:
            for msg in nodes[i].retransmit_tick():
                for d in ids:
                    if d != msg["id"]:
                        if msg["type"] in ("DATA", "HEARTBEAT"):
                            nodes[d].on_stream(msg)
                        elif msg["type"] == "NACK":
                            for r in nodes[d].on_nack(msg):
                                for d2 in ids:
                                    if d2 != r["id"]:
                                        nodes[d2].on_stream(r)
    orders = {i: nodes[i].delivery_order for i in ids}
    assert orders["1"] == orders["2"] == orders["3"] == ["1:1", "1:2"], orders


def teste_fuzz(n=50):
    """SAFETY (ordem total) é obrigatório em TODA run; LIVENESS (completude)
    verificado com dreno generoso (a recuperação por NACK é gradual sob perda)."""
    liveness_incompl = 0
    for seed in range(n):
        nn = 3 + (seed % 4)
        nm = 3 + (seed % 6)
        dp = 0.2 + (seed % 4) * 0.1
        safe, comp, orders = run_fuzz(seed, n_nodes=nn, n_msgs=nm, drop=dp)
        assert safe, f"VIOLAÇÃO DE ORDEM TOTAL seed={seed}: {orders}"
        if not comp:
            liveness_incompl += 1
    assert liveness_incompl == 0, f"{liveness_incompl}/{n} incompletos (liveness)"


if __name__ == "__main__":
    teste_cenario_adversarial()
    teste_fuzz()
    print("TODOS OS TESTES DE FUZZ PASSARAM")
