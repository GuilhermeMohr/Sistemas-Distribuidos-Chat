"""Testes de corretude da ordem total (sem rede real).

Modelo novo (ADR-0008): entrega quando, de TODO nó != origem, já se processou
em ordem uma mensagem com chave > m; batimentos (heartbeat) dão liveness;
FIFO por origem evita entrega prematura sob reordenação/perda.

Rodar: python test_ordem_total.py
"""
from multicast import Node

IDS = ["1", "2", "3"]


def novo_sistema():
    return {i: Node(i, IDS) for i in IDS}


def bcast(nodes, msg):
    """Entrega uma mensagem a todos menos a origem (como o multicast faria)."""
    for nid, n in nodes.items():
        if nid == msg["id"]:
            continue
        t = msg["type"]
        if t in ("DATA", "HEARTBEAT"):
            n.on_stream(msg)
        elif t == "NACK":
            for r in n.on_nack(msg):
                bcast(nodes, r)
        elif t == "MARKER":
            fwd, _ = n.on_marker(msg)
            if fwd is not None:
                bcast(nodes, fwd)


def settle(nodes, rounds=6):
    """Roda rodadas de retransmissão (batimento + NACK + reenvio), como a
    thread real, até a fila estabilizar e curar lacunas."""
    for _ in range(rounds):
        for n in list(nodes.values()):
            for msg in n.retransmit_tick():
                bcast(nodes, msg)


def ordens(nodes):
    return {nid: n.delivery_order for nid, n in nodes.items()}


def teste_concorrente():
    """Duas mensagens concorrentes: ordem global idêntica em todos."""
    nodes = novo_sistema()
    m1 = nodes["1"].on_send("A", 0)   # 1:1
    m2 = nodes["2"].on_send("B", 0)   # 2:1
    bcast(nodes, m1)
    bcast(nodes, m2)
    settle(nodes)
    o = ordens(nodes)
    assert o["1"] == o["2"] == o["3"], f"divergiram: {o}"
    assert o["1"] == ["1:1", "2:1"], o["1"]


def teste_causal():
    """B enviada após A ser entregue -> A precede B em todos."""
    nodes = novo_sistema()
    mA = nodes["1"].on_send("A", 0)
    bcast(nodes, mA)
    settle(nodes)
    mB = nodes["2"].on_send("B", 0)   # depois de ver A (seq inclui batimentos)
    bcast(nodes, mB)
    settle(nodes)
    o = ordens(nodes)
    assert o["1"] == o["2"] == o["3"], f"divergiram: {o}"
    assert len(o["1"]) == 2 and o["1"][0] == "1:1" and o["1"][1] == mB["message_id"], o["1"]


def teste_duplicata():
    """DATA recebida 2x (UDP duplica) é entregue 1x."""
    nodes = novo_sistema()
    m1 = nodes["1"].on_send("unica", 0)
    nodes["2"].on_stream(m1)
    nodes["2"].on_stream(m1)   # duplicata
    nodes["3"].on_stream(m1)
    settle(nodes)
    assert nodes["2"].delivery_order == ["1:1"], nodes["2"].delivery_order


def teste_sem_entrega_prematura():
    """REGRESSÃO do bug: um nó NÃO pode entregar m2 antes de m1 só porque
    ouviu 'depois' de todos — se m1 (menor) ainda não chegou, deve esperar.
    Mesmo recebendo um batimento posterior de nó1 fora de ordem, nó2 segura."""
    nodes = novo_sistema()
    m1 = nodes["1"].on_send("m1", 0)   # 1:1  (menor chave)
    m2 = nodes["2"].on_send("m2", 0)   # 2:1
    # nó2 tem o próprio m2; recebe um batimento POSTERIOR de nó1 (fora de ordem,
    # pois m1=seq1 se perdeu) e um batimento de nó3.
    hb1 = nodes["1"].make_heartbeat()  # 1:2 (chave > m2)
    hb3 = nodes["3"].make_heartbeat()  # 3:1
    nodes["2"].on_stream(hb1)          # seq2 de nó1 sem o seq1 -> vai p/ buffer
    nodes["2"].on_stream(hb3)
    # nó2 NÃO pode ter entregue nada: latest_key[1] ainda é 0 (m1 em falta)
    assert nodes["2"].delivery_order == [], \
        f"entrega prematura! {nodes['2'].delivery_order}"
    # NACK deve pedir 1:1
    assert any(t["type"] == "NACK" and t["message_id"] == "1:1"
               for t in nodes["2"].retransmit_tick())
    # recupera: todos recebem m1 e m2 devidamente, depois estabiliza
    bcast(nodes, m1)   # nó2 processa 1:1 e então o hb1 (1:2) que estava no buffer
    bcast(nodes, m2)   # nó1 e nó3 recebem m2
    settle(nodes)
    o = ordens(nodes)
    assert o["1"] == o["2"] == o["3"] == ["1:1", "2:1"], o


def teste_retransmissao_data_perdida():
    """DATA perdida gera lacuna; NACK recupera via retransmissão da origem."""
    nodes = novo_sistema()
    m1 = nodes["1"].on_send("m1", 0)   # 1:1
    nodes["3"].on_stream(m1)           # nó3 recebe; nó2 "perde"
    hb = nodes["1"].make_heartbeat()   # 1:2
    nodes["2"].on_stream(hb)           # nó2 vê 1:2 -> lacuna em 1:1
    ticks = nodes["2"].retransmit_tick()
    assert any(t["type"] == "NACK" and t["message_id"] == "1:1" for t in ticks), ticks
    resp = nodes["1"].on_nack({"id": "2", "message_id": "1:1"})
    assert resp and resp[0]["message_id"] == "1:1", resp
    nodes["2"].on_stream(resp[0])
    settle(nodes)
    o = ordens(nodes)
    assert o["1"] == o["2"] == o["3"] == ["1:1"], o


def teste_snapshot():
    """Chandy-Lamport: todos concluem e capturam estado consistente."""
    nodes = novo_sistema()
    m1 = nodes["1"].on_send("antes", 0)
    bcast(nodes, m1)
    settle(nodes)
    assert all(n.delivery_order == ["1:1"] for n in nodes.values())

    marker = nodes["1"].start_snapshot()
    bcast(nodes, marker)
    for nid, n in nodes.items():
        snap = n.get_snapshot()
        assert snap is not None and snap["done"], f"nó {nid} não concluiu"
    dords = {tuple(n.get_snapshot()["local_state"]["delivery_order"])
             for n in nodes.values()}
    assert dords == {("1:1",)}, dords


if __name__ == "__main__":
    teste_concorrente()
    teste_causal()
    teste_duplicata()
    teste_sem_entrega_prematura()
    teste_retransmissao_data_perdida()
    teste_snapshot()
    print("TODOS OS TESTES PASSARAM")
