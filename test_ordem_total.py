"""Teste de corretude da ordem total (sem rede real).

Simula 3 nós trocando mensagens concorrentes, entregando DATA em ordens
DIFERENTES em cada nó, e verifica que a delivery_order (ordem global) fica
IDÊNTICA em todos — critério de corretude do enunciado (§8).

Rodar: python test_ordem_total.py
Teste ponta-a-ponta com multicast real: ver run.ps1 (Windows) ou subir N
processos manualmente (`python multicast.py <id>`).
"""
import collections

from multicast import Node

IDS = ["1", "2", "3"]


def novo_sistema():
    return {i: Node(i, IDS) for i in IDS}


def propaga_acks(nodes, acks):
    """ACK é multicast: vai para todos menos a origem do ACK."""
    q = collections.deque(acks)
    while q:
        src, ack = q.popleft()
        for nid, node in nodes.items():
            if nid == src:
                continue
            node.on_ack(ack)  # entrega não gera novos ACKs


def entrega_data(node, msg, sink):
    ack, _ = node.on_data(msg)
    if ack is not None:
        sink.append((node.process_id, ack))


def teste_concorrente():
    """Duas mensagens concorrentes chegando em ordens diferentes por nó."""
    nodes = novo_sistema()
    m1 = nodes["1"].on_send("Ola de 1", 0)   # V=[1,0,0]
    m2 = nodes["2"].on_send("Ola de 2", 0)   # V=[0,1,0] (concorrente)

    acks = []
    entrega_data(nodes["1"], m2, acks)                 # nó1 vê m2
    entrega_data(nodes["2"], m1, acks)                 # nó2 vê m1
    entrega_data(nodes["3"], m2, acks)                 # nó3 vê m2 ANTES de m1
    entrega_data(nodes["3"], m1, acks)                 # ...depois m1 (invertido)
    propaga_acks(nodes, acks)

    ordens = {nid: n.delivery_order for nid, n in nodes.items()}
    assert ordens["1"] == ordens["2"] == ordens["3"], f"divergiram: {ordens}"
    assert ordens["1"] == ["1:1", "2:1"], f"ordem inesperada: {ordens['1']}"
    # A ordem local pode diferir mesmo com a global idêntica:
    assert nodes["2"].local_order != nodes["1"].local_order


def teste_causal():
    """B só é enviada após a entrega de A -> A precede B em todos."""
    nodes = novo_sistema()
    mA = nodes["1"].on_send("A", 0)          # V=[1,0,0]
    acks = []
    entrega_data(nodes["2"], mA, acks)
    entrega_data(nodes["3"], mA, acks)
    propaga_acks(nodes, acks)
    mB = nodes["2"].on_send("B", 0)          # V=[1,1,0] -> depende de A

    acks = []
    entrega_data(nodes["1"], mB, acks)
    entrega_data(nodes["3"], mB, acks)
    propaga_acks(nodes, acks)

    ordens = {nid: n.delivery_order for nid, n in nodes.items()}
    assert ordens["1"] == ordens["2"] == ordens["3"], f"divergiram: {ordens}"
    assert ordens["1"] == ["1:1", "2:1"], f"ordem inesperada: {ordens['1']}"


def teste_duplicata():
    """UDP pode duplicar: a mesma DATA recebida 2x é entregue 1x."""
    nodes = novo_sistema()
    m1 = nodes["1"].on_send("unica", 0)
    acks = []
    entrega_data(nodes["2"], m1, acks)
    entrega_data(nodes["2"], m1, acks)   # duplicata
    entrega_data(nodes["3"], m1, acks)
    propaga_acks(nodes, acks)
    assert nodes["2"].delivery_order == ["1:1"], "duplicata processada 2x!"


def teste_snapshot():
    """Chandy-Lamport: todos os nós concluem e capturam estado consistente."""
    nodes = novo_sistema()
    m1 = nodes["1"].on_send("antes do snapshot", 0)
    acks = []
    entrega_data(nodes["2"], m1, acks)
    entrega_data(nodes["3"], m1, acks)
    propaga_acks(nodes, acks)  # m1 entregue em todos -> delivery_order=[1:1]

    marker = nodes["1"].start_snapshot()          # nó1 é o iniciador
    pendentes = [("1", marker)]                    # MARKER é multicast
    while pendentes:
        src, mk = pendentes.pop(0)
        for nid, node in nodes.items():
            if nid == src:
                continue
            fwd, _ = node.on_marker(mk)
            if fwd is not None:
                pendentes.append((nid, fwd))

    for nid, node in nodes.items():
        snap = node.get_snapshot()
        assert snap is not None and snap["done"], f"nó {nid} não concluiu snapshot"
    # estado global consistente: todos capturaram a mesma delivery_order
    ordens = [tuple(n.get_snapshot()["local_state"]["delivery_order"])
              for n in nodes.values()]
    assert all(o == ("1:1",) for o in ordens), f"estado inconsistente: {ordens}"


def teste_retransmissao_data_perdida():
    """DATA perdida gera lacuna; NACK recupera via retransmissão da origem."""
    nodes = novo_sistema()
    m1 = nodes["1"].on_send("m1", 0)   # 1:1
    m2 = nodes["1"].on_send("m2", 0)   # 1:2
    acks = []
    entrega_data(nodes["2"], m2, acks)         # nó2 recebe só m2 (m1 perdida)
    entrega_data(nodes["3"], m1, acks)
    entrega_data(nodes["3"], m2, acks)
    assert nodes["2"].delivery_order == [], "não deveria entregar com lacuna"

    ticks = nodes["2"].retransmit_tick()
    assert any(t["type"] == "NACK" and t["message_id"] == "1:1" for t in ticks), ticks

    resp = nodes["1"].on_nack({"type": "NACK", "id": "2", "message_id": "1:1"})
    data_resp = [r for r in resp if r["type"] == "DATA"]
    assert data_resp and data_resp[0]["message_id"] == "1:1", resp

    entrega_data(nodes["2"], data_resp[0], acks)   # nó2 recebe o DATA reenviado
    propaga_acks(nodes, acks)
    assert nodes["2"].delivery_order == ["1:1", "1:2"], nodes["2"].delivery_order


def teste_retransmissao_ack_perdido():
    """ACK perdido trava a entrega; NACK recupera pedindo o ACK de novo."""
    nodes = novo_sistema()
    mA = nodes["1"].on_send("A", 0)    # 1:1
    ack2 = nodes["2"].on_data(mA)[0]
    ack3 = nodes["3"].on_data(mA)[0]
    # Distribuição com PERDA do ACK de nó2 para nó3:
    nodes["1"].on_ack(ack2); nodes["1"].on_ack(ack3)   # nó1 recebe ambos
    nodes["2"].on_ack(ack3)                             # nó2 recebe o de nó3
    # nó3 não recebe nada (ACK de nó2 perdido; nó1 é origem e não dá ACK)
    assert nodes["1"].delivery_order == ["1:1"]
    assert nodes["2"].delivery_order == ["1:1"]
    assert nodes["3"].delivery_order == [], "nó3 deveria estar travado"

    ticks = nodes["3"].retransmit_tick()
    assert any(t["type"] == "NACK" and t["message_id"] == "1:1" for t in ticks), ticks

    resp = nodes["2"].on_nack({"type": "NACK", "id": "3", "message_id": "1:1"})
    acks_resp = [r for r in resp if r["type"] == "ACK"]
    assert acks_resp, resp
    nodes["3"].on_ack(acks_resp[0])
    assert nodes["3"].delivery_order == ["1:1"], nodes["3"].delivery_order


if __name__ == "__main__":
    teste_concorrente()
    teste_causal()
    teste_duplicata()
    teste_snapshot()
    teste_retransmissao_data_perdida()
    teste_retransmissao_ack_perdido()
    print("TODOS OS TESTES PASSARAM")
