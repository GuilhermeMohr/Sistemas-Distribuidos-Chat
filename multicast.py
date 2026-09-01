"""Chat distribuído — comunicação de grupo com ordem total (multicast UDP).

Trabalho 1 de Sistemas Distribuídos (UNIVALI). Cada nó é um processo
independente que se comunica apenas por mensagens de rede (multicast UDP).

Ordem total (Abordagem A — ADR-0005/ADR-0008): relógio vetorial para
causalidade + chave total determinística + condição de estabilidade correta:
uma mensagem m só é entregue quando, de **todos** os outros nós, já se recebeu
(em ordem FIFO por origem) algo com chave **maior** que m — garantindo que
nenhuma mensagem menor ainda pode chegar. Batimentos (HEARTBEAT) periódicos
garantem que nós silenciosos não travem a fila. O processamento FIFO por
origem (com dedup + NACK) evita que um batimento "fure" a ordem sobre o UDP,
que não é FIFO.

Tipos de mensagem: DATA (aplicação), HEARTBEAT (liveness), NACK (retransmissão),
MARKER (snapshot Chandy-Lamport).

Confiabilidade sobre UDP: dedup por message_id + reordenação FIFO por origem +
retransmissão sob demanda (NACK, origem reenvia) + reenvio periódico. Converge.
"""

import socket
import struct
import threading
import json
import sys
import os
import random

CONFIG_PATH = "nos.json"
RECV_BUFFER = 65536
RETRANSMIT_INTERVAL = 1.0  # batimento + retransmissão periódicos
DROP_PROB = float(os.environ.get("DROP_PROB", "0"))  # injeção de perda p/ teste


# ---------------------------------------------------------------------------
# Núcleo de ordenação total (testável, sem rede)
# ---------------------------------------------------------------------------

class Node:
    """Estado e lógica de ordem total de um nó. Thread-safe (um lock)."""

    def __init__(self, process_id, node_ids):
        self.process_id = str(process_id)
        self.node_ids = [str(n) for n in node_ids]

        self.vectorial_time = {n: 0 for n in self.node_ids}
        # FIFO por origem: próxima seq esperada + buffer de reordenação.
        self.next_expected = {n: 1 for n in self.node_ids}
        self.reorder_buf = {n: {} for n in self.node_ids}
        # Maior chave já processada EM ORDEM de cada nó (progresso conhecido).
        self.latest_key = {n: (0, 0, 0) for n in self.node_ids}

        self.holdback = []            # DATA recebidos em ordem, aguardando entrega
        self.received_ids = set()     # dedup (DATA e HEARTBEAT)
        self.delivered_ids = set()
        self.delivery_order = []      # ordem GLOBAL (idêntica em todos os nós)
        self.local_order = []         # ordem LOCAL (ordem de eventos deste nó)
        self.message_store = {}       # message_id -> envelope (p/ retransmissão)

        # Snapshot Chandy-Lamport (R6).
        self.snapshots = {}
        self.last_snapshot = None
        self._snap_counter = 0

        self._lock = threading.Lock()

    # -- chave de ordem total -------------------------------------------------

    @staticmethod
    def total_key(message):
        """(escalar derivado do vetor, id da origem, seq da origem).

        Chave determinística idêntica em todos os nós. O escalar (soma do vetor)
        é monotônico (cada envio incrementa uma posição); o desempate por origem
        e seq torna a ordem parcial (causal) em ordem total.
        """
        v = message["vectorial_time"]
        origin = message["id"]
        return (sum(v.values()), int(origin), v[origin])

    # -- helpers internos (assumem lock) -------------------------------------

    def _next_seq(self):
        self.vectorial_time[self.process_id] += 1
        return self.vectorial_time[self.process_id]

    def _register_own(self, msg, is_data):
        """Registra uma mensagem própria como já processada em ordem."""
        mid = msg["message_id"]
        self.received_ids.add(mid)
        self.message_store[mid] = msg
        self.latest_key[self.process_id] = self.total_key(msg)
        self.next_expected[self.process_id] = msg["vectorial_time"][self.process_id] + 1
        if is_data:
            self.holdback.append(msg)
            self.local_order.append(mid)

    def _build(self, mtype, text=None, receiver=0):
        seq = self._next_seq()
        mid = f"{self.process_id}:{seq}"
        msg = {"type": mtype, "id": self.process_id, "message_id": mid,
               "vectorial_time": dict(self.vectorial_time)}
        if mtype == "DATA":
            msg["message"] = text
            msg["receiver"] = receiver
        return msg

    # -- envio ----------------------------------------------------------------

    def on_send(self, text, receiver=0):
        """Prepara uma mensagem DATA própria. Retorna o envelope a difundir."""
        with self._lock:
            msg = self._build("DATA", text=text, receiver=receiver)
            self._register_own(msg, is_data=True)
        return msg

    def make_heartbeat(self):
        """Cria um HEARTBEAT (liveness). Retorna o envelope a difundir."""
        with self._lock:
            msg = self._build("HEARTBEAT")
            self._register_own(msg, is_data=False)
        return msg

    # -- recepção de mensagens de fluxo (DATA / HEARTBEAT) -------------------

    def on_stream(self, message):
        """Processa DATA/HEARTBEAT recebido, respeitando FIFO por origem.
        Retorna a lista de mensagens entregues."""
        origin = message["id"]
        mid = message["message_id"]
        seq = message["vectorial_time"][origin]
        with self._lock:
            if mid in self.received_ids:
                return []                        # duplicata
            self.received_ids.add(mid)
            self.message_store[mid] = message
            # causalidade: incorpora o vetor recebido
            for k, v in message["vectorial_time"].items():
                self.vectorial_time[k] = max(self.vectorial_time.get(k, 0), v)
            # enfileira e processa em ordem contígua a partir da origem
            self.reorder_buf[origin][seq] = message
            while self.next_expected[origin] in self.reorder_buf[origin]:
                sm = self.reorder_buf[origin].pop(self.next_expected[origin])
                self.latest_key[origin] = self.total_key(sm)
                if sm["type"] == "DATA":
                    self.holdback.append(sm)
                    self.local_order.append(sm["message_id"])
                    for snap in self.snapshots.values():   # Chandy-Lamport
                        if not snap["done"] and origin in snap["recording"]:
                            snap["channel_state"][origin].append(sm["message_id"])
                self.next_expected[origin] += 1
            return self._try_deliver()

    # -- entrega (coração da ordem total) ------------------------------------

    def _try_deliver(self):
        """Entrega as mensagens estáveis. Chamar com o lock.

        m (a de menor chave no holdback) é entregue quando, de TODO nó o != origem,
        já se processou em ordem uma mensagem com chave > chave(m). Isso garante
        que nenhuma mensagem menor ainda pode chegar (nem em trânsito, nem futura).
        """
        delivered = []
        while self.holdback:
            m = min(self.holdback, key=self.total_key)
            k = self.total_key(m)
            origin = m["id"]
            estavel = all(self.latest_key[o] > k
                          for o in self.node_ids if o != origin)
            if not estavel:
                break
            self.holdback.remove(m)
            self.delivered_ids.add(m["message_id"])
            self.delivery_order.append(m["message_id"])
            delivered.append(m)
        return delivered

    # -- confiabilidade sobre UDP (retransmissão) ----------------------------

    def on_nack(self, message):
        """Responde a um NACK: se sou a origem e tenho a mensagem, reenvio-a."""
        mid = message["message_id"]
        with self._lock:
            if mid.split(":")[0] == self.process_id and mid in self.message_store:
                return [self.message_store[mid]]
            return []

    def retransmit_tick(self):
        """Chamada periódica: batimento (liveness) + NACK de lacunas + reenvio
        do próprio DATA ainda não entregue. Converge e para quando tudo entrega."""
        with self._lock:
            out = []
            # batimento: avança meu progresso para os demais entregarem
            hb = self._build("HEARTBEAT")
            self._register_own(hb, is_data=False)
            out.append(hb)
            # NACK da lacuna por origem (a próxima seq faltante). Um por rodada
            # evita tempestade de reenvios; a recuperação é gradual sob perda
            # severa (limitação P1 documentada — a corretude/safety é preservada).
            for o in self.node_ids:
                if o != self.process_id and self.reorder_buf[o]:
                    out.append({"type": "NACK", "id": self.process_id,
                                "message_id": f"{o}:{self.next_expected[o]}"})
            # reenvia meu DATA ainda não entregue (cobre perda do envio original)
            for m in self.holdback:
                if m["id"] == self.process_id:
                    out.append(m)
            return out

    # -- snapshot Chandy-Lamport (R6) ----------------------------------------

    def _record_local(self, snapshot_id, initiator):
        outros = [n for n in self.node_ids if n != self.process_id]
        self.snapshots[snapshot_id] = {
            "initiator": initiator,
            "local_state": {
                "vectorial_time": dict(self.vectorial_time),
                "delivery_order": list(self.delivery_order),
                "holdback": [m["message_id"] for m in self.holdback],
            },
            "recording": set(outros),
            "channel_state": {n: [] for n in outros},
            "markers_from": set(),
            "done": False,
        }

    def _check_done(self, snap):
        outros = {n for n in self.node_ids if n != self.process_id}
        if snap["markers_from"] >= outros:
            snap["done"] = True
            self.last_snapshot = snap

    def start_snapshot(self):
        """Inicia um snapshot (este nó é o iniciador). Retorna o MARKER."""
        with self._lock:
            self._snap_counter += 1
            snapshot_id = f"{self.process_id}-{self._snap_counter}"
            self._record_local(snapshot_id, self.process_id)
            self._check_done(self.snapshots[snapshot_id])
        return {"type": "MARKER", "id": self.process_id,
                "snapshot_id": snapshot_id, "initiator": self.process_id}

    def on_marker(self, message):
        """Processa um MARKER. Retorna (marker_a_difundir_ou_None, done)."""
        sender = message["id"]
        snapshot_id = message["snapshot_id"]
        initiator = message["initiator"]
        forward = None
        with self._lock:
            if snapshot_id not in self.snapshots:
                self._record_local(snapshot_id, initiator)
                snap = self.snapshots[snapshot_id]
                snap["recording"].discard(sender)   # canal de origem vazio
                forward = {"type": "MARKER", "id": self.process_id,
                           "snapshot_id": snapshot_id, "initiator": initiator}
            else:
                snap = self.snapshots[snapshot_id]
                snap["recording"].discard(sender)   # encerra gravação do canal
            snap["markers_from"].add(sender)
            self._check_done(snap)
            done = snap["done"]
        return forward, done

    def get_snapshot(self, snapshot_id=None):
        with self._lock:
            if snapshot_id is None:
                return self.last_snapshot
            return self.snapshots.get(snapshot_id)

    # -- leitura de estado (para a tela) -------------------------------------

    def snapshot_view(self):
        with self._lock:
            return {
                "vectorial_time": dict(self.vectorial_time),
                "local_order": list(self.local_order),
                "delivery_order": list(self.delivery_order),
                "holdback": [m["message_id"] for m in self.holdback],
            }


# ---------------------------------------------------------------------------
# Camada de rede
# ---------------------------------------------------------------------------

def load_config(path=CONFIG_PATH):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def create_multicast_socket(group, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except OSError:
            pass
    sock.bind(("", port))
    membership = struct.pack(
        "4s4s", socket.inet_aton(group), socket.inet_aton("0.0.0.0"))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)
    return sock


def broadcast(sock, group, port, message):
    sock.sendto(json.dumps(message).encode("utf-8"), (group, port))


def display_delivered(node, delivered):
    for m in delivered:
        receiver = m.get("receiver", 0)
        if receiver != 0 and str(receiver) != node.process_id:
            continue  # unicast para outro nó: ordena mas não exibe
        alvo = "grupo" if receiver == 0 else f"nó {receiver}"
        print(f"\n[entregue #{len(node.delivery_order)} | {alvo}] "
              f"{m['id']}: {m['message']}")


def receive_loop(sock, node, group, port, stop_event):
    while not stop_event.is_set():
        try:
            data, _ = sock.recvfrom(RECV_BUFFER)
            message = json.loads(data.decode("utf-8"))

            if message["id"] == node.process_id:
                continue  # ignora o próprio eco do multicast
            if DROP_PROB and random.random() < DROP_PROB:
                continue  # simula datagrama perdido (teste de confiabilidade)

            mtype = message.get("type")
            if mtype == "DATA":
                delivered = node.on_stream(message)
                broadcast(sock, group, port, node.make_heartbeat())  # convergência rápida
                display_delivered(node, delivered)
            elif mtype == "HEARTBEAT":
                display_delivered(node, node.on_stream(message))
            elif mtype == "NACK":
                for resend in node.on_nack(message):
                    broadcast(sock, group, port, resend)
            elif mtype == "MARKER":
                forward, done = node.on_marker(message)
                if forward is not None:
                    broadcast(sock, group, port, forward)
                if done:
                    print(f"\n[snapshot {message['snapshot_id']} concluído "
                          f"neste nó — opção 7 para ver]")
        except OSError:
            break  # socket fechado no shutdown
        except Exception as error:
            print(f"Erro na recepção: {error}")


def retransmit_loop(sock, node, group, port, stop_event):
    """Confiabilidade + liveness: batimento periódico, NACK de lacunas e
    reenvio do próprio DATA pendente, até tudo ser entregue."""
    while not stop_event.wait(RETRANSMIT_INTERVAL):
        try:
            for msg in node.retransmit_tick():
                broadcast(sock, group, port, msg)
        except OSError:
            break
        except Exception as error:
            print(f"Erro na retransmissão: {error}")


# ---------------------------------------------------------------------------
# Interface (tela do nó — R5)
# ---------------------------------------------------------------------------

MENU = """
================================
 Nó {pid}
================================
[1] Enviar mensagem de grupo
[2] Enviar mensagem para um nó
[3] Mostrar relógio vetorial
[4] Mostrar ordem local
[5] Mostrar ordem global
[6] Iniciar snapshot global (Chandy-Lamport)
[7] Mostrar último snapshot
[0] Sair
"""


def ui_loop(sock, node, group, port, stop_event):
    while not stop_event.is_set():
        print(MENU.format(pid=node.process_id))
        try:
            option = input("Opção: ").strip()
        except (EOFError, KeyboardInterrupt):
            option = "0"

        if option == "1":
            texto = input("Mensagem: ")
            broadcast(sock, group, port, node.on_send(texto, receiver=0))
        elif option == "2":
            alvo = input("ID do nó destino: ").strip()
            texto = input("Mensagem: ")
            broadcast(sock, group, port, node.on_send(texto, receiver=alvo))
        elif option == "3":
            print(f"Relógio vetorial: {node.snapshot_view()['vectorial_time']}")
        elif option == "4":
            print(f"Ordem local:  {node.snapshot_view()['local_order']}")
        elif option == "5":
            print(f"Ordem global: {node.snapshot_view()['delivery_order']}")
        elif option == "6":
            marker = node.start_snapshot()
            broadcast(sock, group, port, marker)
            print(f"Snapshot {marker['snapshot_id']} iniciado (MARKER difundido).")
        elif option == "7":
            snap = node.get_snapshot()
            if snap is None:
                print("Nenhum snapshot concluído ainda.")
            else:
                print(f"Último snapshot (iniciador {snap['initiator']}):")
                print(f"  estado local: {snap['local_state']}")
                print(f"  estado dos canais: {snap['channel_state']}")
        elif option == "0":
            stop_event.set()
            break
        else:
            print("Opção inválida.")


def main():
    if len(sys.argv) < 2:
        print("Uso: python multicast.py <process_id> [nos.json]")
        sys.exit(1)

    process_id = sys.argv[1]
    config = load_config(sys.argv[2] if len(sys.argv) > 2 else CONFIG_PATH)
    group = config["multicast"]["group"]
    port = int(config["multicast"]["port"])
    node_ids = [n["id"] for n in config["nodes"]]

    if process_id not in node_ids:
        print(f"process_id {process_id} não está em nos.json ({node_ids})")
        sys.exit(1)

    node = Node(process_id, node_ids)
    sock = create_multicast_socket(group, port)
    stop_event = threading.Event()

    threading.Thread(target=receive_loop,
                     args=(sock, node, group, port, stop_event),
                     daemon=True).start()
    threading.Thread(target=retransmit_loop,
                     args=(sock, node, group, port, stop_event),
                     daemon=True).start()

    try:
        ui_loop(sock, node, group, port, stop_event)
    finally:
        stop_event.set()
        sock.close()
        print("Encerrando nó.")


if __name__ == "__main__":
    main()
