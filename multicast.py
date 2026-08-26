import socket
import threading
import json
import sys

# Const
NUMBER_OF_PROCESSES = 3
MULTICAST_PORT = 50000

# Variables
host = socket.gethostbyname(socket.gethostname())

def create_multicast_socket():
    # multicast_socket = socket.socket(
    #     socket.AF_INET,
    #     socket.SOCK_DGRAM
    #     # socket.IPPROTO_UDP
    # )

    multicast_socket = socket.socket(
        socket.AF_INET,
        socket.SOCK_DGRAM
    )

    # Allow several processes to bind to the same UDP port.
    multicast_socket.setsockopt(
        socket.SOL_SOCKET,
        socket.SO_REUSEADDR,
        1
    )

    multicast_socket.bind((host, MULTICAST_PORT))

    return multicast_socket

def receive_multicast(multicast_socket, process_id):
    while True:
        try:
            threading.Thread(target=handle_message, args=(multicast_socket, process_id)).start()

        except Exception as error:
            print(f"{process_id}: error: {error}\n")

def handle_message(multicast_socket, process_id):
    try:
        data, address = multicast_socket.recvfrom(1024)
        message = json.loads(data.decode("utf-8"))

        print(f"{process_id}: Mensagem recebida: {message['message']}\n")
    except:
        print(f"Erro!\n")

def write(multicast_socket, host, process_id):
    message = {
        "message": "Olá",
    }

    try:
        broadcast(multicast_socket, host, message)
    except:
        print(f"{process_id}: ERRO!\n")

def broadcast(multicast_socket, host, message):
    multicast_socket.sendto(json.dumps(message).encode("utf-8"), (host, MULTICAST_PORT))

process_id = int(sys.argv[1])
multicast_socket = create_multicast_socket()

threading.Thread(target=receive_multicast, args=(multicast_socket, process_id)).start()
threading.Thread(target=write, args=(multicast_socket, host, process_id)).start()