"""Chat distribuído — comunicação de grupo com ordem total (multicast UDP).

Trabalho 1 de Sistemas Distribuídos (UNIVALI). Cada nó é um processo
independente que se comunica apenas por mensagens de rede (multicast UDP).

Arquitetura (separação protocolo / ordenação / UI):
    recvfrom -> parse JSON -> dispatch por 'type'
        DATA   -> Node.on_data()  -> holdback_queue -> try_deliver()
        ACK    -> Node.on_ack()   -> acks           -> try_deliver()
        MARKER -> (CP4 — snapshot Chandy-Lamport, ainda não implementado)

Ordem total (Abordagem A — ADR-0005): relógio vetorial para causalidade +
chave total determinística + ACK de estabilidade sobre uma hold-back queue.
Uma mensagem só é entregue quando é o TOPO da fila (por total_key) E todos
os nós conhecidos confirmaram (ACK). Isso — e não um simples sort — é o que
garante que todos os nós entreguem na MESMA ordem (ver anti-pattern
total-order-sort-without-stability).
"""

import socket
import struct
import threading
import json
import sys

CONFIG_PATH = "nos.json"
RECV_BUFFER = 65536  # vetor de 15+ posições + payload não cabe em 1024


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
            self.holdback_queue.append(message)
            self.local_order.append(message_id)
            # A origem conhece a própria mensagem; nós também.
            acked = self.acks.setdefault(message_id, set())
            acked.add(origin)
            acked.add(self.process_id)
            delivered = self._try_deliver()
        ack = {"type": "ACK", "id": self.process_id, "message_id": message_id}
        return ack, delivered

    def on_ack(self, message):
        """Processa ACK recebido. Retorna lista de mensagens entregues."""
        message_id = message["message_id"]
        with self._lock:
            self.acks.setdefault(message_id, set()).add(message["id"])
            return self._try_deliver()

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
            #     já entregue). Sob perda UDP isto pode estagnar a origem —
            #     limitação documentada (recuperação fora de escopo).
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

            mtype = message.get("type")
            if mtype == "DATA":
                ack, delivered = node.on_data(message)
                if ack is not None:
                    broadcast(sock, group, port, ack)
                display_delivered(node, delivered)
            elif mtype == "ACK":
                delivered = node.on_ack(message)
                display_delivered(node, delivered)
            # MARKER: reservado para o snapshot (CP4).
        except OSError:
            break  # socket fechado no shutdown
        except Exception as error:
            print(f"Erro na recepção: {error}")


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
[6] Iniciar snapshot global   (CP4 — em breve)
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
            print("Snapshot Chandy-Lamport ainda não implementado (CP4).")
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

    try:
        ui_loop(sock, node, group, port, stop_event)
    finally:
        stop_event.set()
        sock.close()
        print("Encerrando nó.")


if __name__ == "__main__":
    main()
