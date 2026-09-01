"""Chat distribuído — comunicação de grupo com ordem total (multicast UDP).

Trabalho 1 de Sistemas Distribuídos (UNIVALI). Cada nó é um processo
independente que se comunica apenas por mensagens de rede (multicast UDP).

Arquitetura (separação protocolo / ordenação / snapshot / UI):
    recvfrom -> parse JSON -> dispatch por 'type'
        DATA   -> Node.on_data()  -> holdback_queue -> try_deliver()
        ACK    -> Node.on_ack()   -> acks           -> try_deliver()
        NACK   -> Node.on_nack()  -> retransmite o DATA pedido
        MARKER -> Node.on_marker() -> snapshot Chandy-Lamport

Ordem total (Abordagem A — ADR-0005): relógio vetorial para causalidade +
chave total determinística + ACK de estabilidade sobre uma hold-back queue.
Uma mensagem só é entregue quando é o TOPO da fila (por total_key) E todos
os nós conhecidos confirmaram (ACK). Isso — e não um simples sort — é o que
garante que todos os nós entreguem na MESMA ordem (ver anti-pattern
total-order-sort-without-stability).

Confiabilidade sobre UDP: dedup por message_id + hold-back (reordenação) +
retransmissão sob demanda (NACK) e reenvio periódico de DATA/ACK pendentes
(cobre perda de DATA e de ACK). Recuperação converge e para quando tudo é
entregue.
"""

import socket
import struct
import threading
import json
import sys
import os
import random

CONFIG_PATH = "nos.json"
RECV_BUFFER = 65536  # vetor de 15+ posições + payload não cabe em 1024
RETRANSMIT_INTERVAL = 1.0  # segundos entre ciclos de retransmissão
# Injeção de perda para TESTE (0.0 = desligado): descarta datagramas recebidos.
DROP_PROB = float(os.environ.get("DROP_PROB", "0"))


# ---------------------------------------------------------------------------
# Núcleo de ordenação (testável, sem rede)
# ---------------------------------------------------------------------------

class Node:
    """Estado e lógica de ordem total de um nó. Thread-safe.

    Convenção do relógio vetorial (documentada no relatório):
    - Evento de ENVIO incrementa apenas a própria posição.
    - Evento de ENTREGA faz max componente a componente (recepção NÃO
      incrementa) — assim ``V[origem]`` é exatamente a sequência da origem.
    """

    def __init__(self, process_id, node_ids):
        self.process_id = str(process_id)
        self.node_ids = [str(n) for n in node_ids]

        self.vectorial_time = {n: 0 for n in self.node_ids}
        self.holdback_queue = []          # mensagens DATA aguardando entrega
        self.received_ids = set()         # dedup de DATA (message_id)
        self.acks = {}                    # message_id -> set(ids que confirmaram)
        self.delivered_ids = set()
        self.delivery_order = []          # ordem GLOBAL (idêntica em todos os nós)
        self.local_order = []             # ordem LOCAL (ordem de eventos deste nó)
        self.delivered_seq = {n: 0 for n in self.node_ids}  # FIFO por origem

        # Confiabilidade sobre UDP: cache para retransmissão sob demanda (NACK).
        self.message_store = {}           # message_id -> envelope DATA (para reenvio)

        # Snapshot Chandy-Lamport (R6): um registro por snapshot_id.
        self.snapshots = {}
        self.last_snapshot = None
        self._snap_counter = 0

        self._lock = threading.Lock()

    # -- chave de ordem total -------------------------------------------------

    @staticmethod
    def total_key(message):
        """(escalar derivado do vetor, id numérico da origem, seq da origem).

        O escalar é a soma dos componentes do vetor no envio — NÃO um relógio
        de Lamport perfeito, mas suficiente porque cada envio incrementa
        exatamente uma posição. O desempate determinístico (origem, seq)
        transforma a ordem parcial (causal) em ordem total.
        """
        vector = message["vectorial_time"]
        origin = message["id"]
        return (sum(vector.values()), int(origin), vector[origin])

    # -- envio ----------------------------------------------------------------

    def on_send(self, text, receiver=0):
        """Prepara uma mensagem DATA própria. Retorna o envelope a difundir."""
        with self._lock:
            self.vectorial_time[self.process_id] += 1
            seq = self.vectorial_time[self.process_id]
            message_id = f"{self.process_id}:{seq}"
            message = {
                "type": "DATA",
                "id": self.process_id,
                "message_id": message_id,
                "message": text,
                "receiver": receiver,
                "vectorial_time": dict(self.vectorial_time),
            }
            # A própria origem já "recebeu" e "confirma" a mensagem.
            self.received_ids.add(message_id)
            self.acks.setdefault(message_id, set()).add(self.process_id)
            self.holdback_queue.append(message)
            self.local_order.append(message_id)
            self.message_store[message_id] = message  # para retransmissão
        return message

    # -- recepção -------------------------------------------------------------

    def on_data(self, message):
        """Processa DATA recebida. Retorna (ack_a_enviar, entregues)."""
        message_id = message["message_id"]
        origin = message["id"]
        with self._lock:
            if message_id in self.received_ids:
                return None, []          # duplicata (UDP pode duplicar)
            self.received_ids.add(message_id)
            self.message_store[message_id] = message  # para retransmissão
            self.holdback_queue.append(message)
            self.local_order.append(message_id)
            # A origem conhece a própria mensagem; nós também.
            acked = self.acks.setdefault(message_id, set())
            acked.add(origin)
            acked.add(self.process_id)
            # Chandy-Lamport: grava a mensagem no estado do canal lógico da
            # origem, para snapshots que já registraram estado local e ainda
            # estão gravando esse canal.
            for snap in self.snapshots.values():
                if not snap["done"] and origin in snap["recording"]:
                    snap["channel_state"][origin].append(message_id)
            delivered = self._try_deliver()
        ack = {"type": "ACK", "id": self.process_id, "message_id": message_id}
        return ack, delivered

    def on_ack(self, message):
        """Processa ACK recebido. Retorna lista de mensagens entregues."""
        message_id = message["message_id"]
        with self._lock:
            self.acks.setdefault(message_id, set()).add(message["id"])
            return self._try_deliver()

    # -- confiabilidade sobre UDP (retransmissão) ----------------------------

    def on_nack(self, message):
        """Processa um NACK (pedido de re-sincronização de uma mensagem).
        Retorna a lista de mensagens a difundir em resposta:
        - se sou a origem e tenho o DATA em cache → reenvio o DATA;
        - se já recebi/conheço a mensagem → reenvio o meu ACK.
        Assim um único NACK recupera tanto DATA perdida quanto ACK perdido."""
        message_id = message["message_id"]
        resends = []
        with self._lock:
            if (message_id.split(":")[0] == self.process_id
                    and message_id in self.message_store):
                resends.append(self.message_store[message_id])
            if message_id in self.received_ids:
                resends.append({"type": "ACK", "id": self.process_id,
                                "message_id": message_id})
        return resends

    def retransmit_tick(self):
        """Chamada periódica pela thread de retransmissão. Retorna a lista de
        mensagens a difundir para recuperar de perdas UDP (converge e para
        quando tudo é entregue):

        - Meu próprio DATA ainda não entregue → reenvia o DATA (cobre a perda
          do envio original, inclusive a 1ª mensagem, cuja ausência não gera
          lacuna detectável no destino).
        - Se a entrega está travada no topo da fila:
          * por lacuna (falta a mensagem anterior da origem) → NACK pedindo a
            mensagem que falta;
          * por falta de ACK (tenho a mensagem, mas nem todos confirmaram) →
            NACK do próprio topo, para que quem já a conhece reenvie DATA/ACK.
        """
        out = []
        with self._lock:
            for m in self.holdback_queue:
                if m["id"] == self.process_id:
                    out.append(m)                       # reenvia meu DATA
            if self.holdback_queue:
                top = min(self.holdback_queue, key=self.total_key)
                origin = top["id"]
                seq = top["vectorial_time"][origin]
                prox = self.delivered_seq[origin] + 1
                if seq > prox:                          # lacuna
                    out.append({"type": "NACK", "id": self.process_id,
                                "message_id": f"{origin}:{prox}"})
                elif len(self.acks.get(top["message_id"], set())) < len(self.node_ids):
                    out.append({"type": "NACK", "id": self.process_id,
                                "message_id": top["message_id"]})
        return out

    # -- entrega (coração da ordem total) ------------------------------------

    def _try_deliver(self):
        """Entrega todas as mensagens estáveis do topo. Chamar com o lock."""
        delivered = []
        while self.holdback_queue:
            self.holdback_queue.sort(key=self.total_key)
            message = self.holdback_queue[0]
            message_id = message["message_id"]
            origin = message["id"]
            seq = message["vectorial_time"][origin]

            # (1) estabilidade: todos os nós conhecidos confirmaram?
            if len(self.acks.get(message_id, set())) < len(self.node_ids):
                break
            # (2) FIFO por origem: sem lacuna (mensagem anterior da origem
            #     já entregue). Sob perda UDP, a lacuna é recuperada por NACK
            #     (ver retransmit_tick / on_nack) — a espera é temporária.
            if seq != self.delivered_seq[origin] + 1:
                break

            self.holdback_queue.pop(0)
            self.delivered_ids.add(message_id)
            self.delivered_seq[origin] = seq
            self.delivery_order.append(message_id)

            # Atualiza o relógio vetorial na entrega (max componente a componente).
            for k, v in message["vectorial_time"].items():
                if k in self.vectorial_time:
                    self.vectorial_time[k] = max(self.vectorial_time[k], v)
                else:
                    self.vectorial_time[k] = v

            delivered.append(message)
        return delivered

    # -- snapshot Chandy-Lamport (R6) ----------------------------------------

    def _record_local(self, snapshot_id, initiator):
        """Registra o estado local e começa a gravar todos os canais de entrada.

        Chamar com o lock. Canal lógico de entrada = cada outro nó (a mensagem
        carrega sua origem, então o canal é identificado por ``message['id']``).
        """
        outros = [n for n in self.node_ids if n != self.process_id]
        self.snapshots[snapshot_id] = {
            "initiator": initiator,
            "local_state": {
                "vectorial_time": dict(self.vectorial_time),
                "delivery_order": list(self.delivery_order),
                "holdback": [m["message_id"] for m in self.holdback_queue],
            },
            "recording": set(outros),          # canais em gravação
            "channel_state": {n: [] for n in outros},
            "markers_from": set(),             # de quem já recebi MARKER
            "done": False,
        }

    def _check_done(self, snap):
        outros = {n for n in self.node_ids if n != self.process_id}
        if snap["markers_from"] >= outros:
            snap["done"] = True
            self.last_snapshot = snap

    def start_snapshot(self):
        """Inicia um snapshot (este nó é o iniciador). Retorna o MARKER a difundir."""
        with self._lock:
            self._snap_counter += 1
            snapshot_id = f"{self.process_id}-{self._snap_counter}"
            self._record_local(snapshot_id, self.process_id)
            self._check_done(self.snapshots[snapshot_id])  # caso N==1
        return {"type": "MARKER", "id": self.process_id,
                "snapshot_id": snapshot_id, "initiator": self.process_id}

    def on_marker(self, message):
        """Processa um MARKER. Retorna (marker_a_difundir_ou_None, snapshot_done)."""
        sender = message["id"]
        snapshot_id = message["snapshot_id"]
        initiator = message["initiator"]
        forward = None
        with self._lock:
            first = snapshot_id not in self.snapshots
            if first:
                # Primeiro MARKER: registra estado local; o canal de origem
                # deste MARKER fica vazio (nada o precedeu). Propaga o MARKER.
                self._record_local(snapshot_id, initiator)
                snap = self.snapshots[snapshot_id]
                snap["recording"].discard(sender)
                forward = {"type": "MARKER", "id": self.process_id,
                           "snapshot_id": snapshot_id, "initiator": initiator}
            else:
                snap = self.snapshots[snapshot_id]
                # MARKER subsequente: encerra a gravação do canal daquele nó.
                snap["recording"].discard(sender)
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
                "holdback": [m["message_id"] for m in self.holdback_queue],
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
    # SO_REUSEPORT é necessário em macOS/BSD para vários nós no mesmo porto
    # multicast na mesma máquina (essencial para testar 3/8/15 nós localmente).
    if hasattr(socket, "SO_REUSEPORT"):
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except OSError:
            pass
    sock.bind(("", port))
    membership = struct.pack(
        "4s4s",
        socket.inet_aton(group),
        socket.inet_aton("0.0.0.0"),
    )
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)
    return sock


def broadcast(sock, group, port, message):
    sock.sendto(json.dumps(message).encode("utf-8"), (group, port))


def display_delivered(node, delivered):
    """Exibe as mensagens entregues (só grupo ou unicast destinado a este nó)."""
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

            # Injeção de perda para teste de confiabilidade (DROP_PROB>0).
            if DROP_PROB and random.random() < DROP_PROB:
                continue  # simula datagrama perdido

            mtype = message.get("type")
            if mtype == "DATA":
                ack, delivered = node.on_data(message)
                if ack is not None:
                    broadcast(sock, group, port, ack)
                display_delivered(node, delivered)
            elif mtype == "ACK":
                delivered = node.on_ack(message)
                display_delivered(node, delivered)
            elif mtype == "NACK":
                for resend in node.on_nack(message):
                    broadcast(sock, group, port, resend)  # DATA e/ou ACK
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
    """Thread de confiabilidade: reenvia periodicamente DATA/ACK pendentes e
    pede (NACK) as mensagens que faltam, até tudo ser entregue."""
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

    receiver = threading.Thread(
        target=receive_loop, args=(sock, node, group, port, stop_event),
        daemon=True,
    )
    receiver.start()

    retransmitter = threading.Thread(
        target=retransmit_loop, args=(sock, node, group, port, stop_event),
        daemon=True,
    )
    retransmitter.start()

    try:
        ui_loop(sock, node, group, port, stop_event)
    finally:
        stop_event.set()
        sock.close()
        print("Encerrando nó.")


if __name__ == "__main__":
    main()
