import socket
import threading
import json
import sys
import struct
import time

# Const
MULTICAST_GROUP = "239.0.0.1"
MULTICAST_PORT = 50000

def create_multicast_socket():
    multicast_socket = socket.socket(
        socket.AF_INET,
        socket.SOCK_DGRAM,
        socket.IPPROTO_UDP
    )

    multicast_socket.setsockopt(
        socket.SOL_SOCKET,
        socket.SO_REUSEADDR,
        1
    )

    multicast_socket.bind(
        ("", MULTICAST_PORT)
    )

    membership = struct.pack(
        "4s4s",
        socket.inet_aton(MULTICAST_GROUP),
        socket.inet_aton("0.0.0.0")
    )

    multicast_socket.setsockopt(
        socket.IPPROTO_IP,
        socket.IP_ADD_MEMBERSHIP,
        membership
    )

    return multicast_socket

def receive_multicast(multicast_socket, process_id):
    while True:
        try:
            data, address = multicast_socket.recvfrom(1024)
            message = json.loads(data.decode("utf-8"))

            if (message['id'] == process_id or (message['receiver'] != 0 and message['receiver'] != process_id)):
                continue

            print(f"{process_id}: Mensagem recebida: {message['message']}\n")
        except Exception as error:
            print(f"{process_id}: error: {error}\n")

def write(multicast_socket, process_id):
    while True:
        print("Enviar mensagem: ")
        message = {
            "id": process_id,
            "message": input(),
            "receiver": 0
        }

        print("Enviar mensagem em grupo? (s - Sim / id do processo - Nao)")
        input_message = input()
        if (input_message != "s"):
            message['receiver'] = int(input_message)
        
        try:
            broadcast(multicast_socket, message)
        except:
            print(f"{process_id}: ERRO!\n")

def broadcast(multicast_socket, message):
    multicast_socket.sendto(json.dumps(message).encode("utf-8"), (MULTICAST_GROUP, MULTICAST_PORT))

process_id = int(sys.argv[1])
multicast_socket = create_multicast_socket()

threading.Thread(target=receive_multicast, args=(multicast_socket, process_id)).start()

time.sleep(2)

threading.Thread(target=write, args=(multicast_socket, process_id)).start()