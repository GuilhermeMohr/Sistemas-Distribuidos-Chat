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


if __name__ == "__main__":
    teste_concorrente()
    teste_causal()
    teste_duplicata()
    print("TODOS OS TESTES PASSARAM")
