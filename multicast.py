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

def can_deliver(message):
    message_id = message['id']
    message_vectorial_time = message['vectorial_time']
    
    # Próxima mensagem esperada
    if message_vectorial_time[message_id] != vectorial_time.get(message_id, 0) + 1:
        return False

    # Dependências causais entregues
    for key in message_vectorial_time:
        if key != message_id and message_vectorial_time[key] > vectorial_time.get(key, 0):
            return False
        
    return True

def receive_multicast(multicast_socket):
    while True:
        try:
            data, address = multicast_socket.recvfrom(1024)
            message = json.loads(data.decode("utf-8"))

            # Ignora mensagens do proprio processo
            if (message['id'] == process_id):
                continue

            buffer.append(message)

            while True:
                delivered = False

                for message in buffer[:]:
                    if can_deliver(message):
                        buffer.remove(message)
                        message_id = message["id"]

                        # Atualiza vectorial_time
                        message_vectorial_time = message['vectorial_time']
                        for key in message_vectorial_time:
                            value = message_vectorial_time[key]
                            if key not in vectorial_time:
                                vectorial_time[key] = value
                            else:
                                vectorial_time[key] = max(vectorial_time[key], value)
                        vectorial_time[process_id] += 1
                        
                        delivered = True

                        if (message['receiver'] != 0 and message['receiver'] != process_id):
                            continue

                        print(f"Mensagem recebida: {message['message']}\n")

                if not delivered:
                    break
        except Exception as error:
            print(f"Error: {error}\n")

def write(multicast_socket):
    while True:
        print("Enviar mensagem: ")
        vectorial_time[process_id] = vectorial_time[process_id]+1
        message = {
            "id": process_id,
            "message": input(),
            "receiver": 0,
            "vectorial_time": vectorial_time
        }

        print("Enviar mensagem em grupo? (s - Sim / id do processo - Nao)")
        input_message = input()

        if (input_message != "s"):
            message['receiver'] = int(input_message)
        
        try:
            broadcast(multicast_socket, message)
        except:
            print("ERRO!\n")

def broadcast(multicast_socket, message):
    multicast_socket.sendto(json.dumps(message).encode("utf-8"), (MULTICAST_GROUP, MULTICAST_PORT))


# Começo das execucoes
process_id = sys.argv[1]
vectorial_time = {
    process_id: 0
}
buffer = []

print(process_id)

multicast_socket = create_multicast_socket()

threading.Thread(target=receive_multicast, args=(multicast_socket,)).start()

time.sleep(2)

threading.Thread(target=write, args=(multicast_socket,)).start()