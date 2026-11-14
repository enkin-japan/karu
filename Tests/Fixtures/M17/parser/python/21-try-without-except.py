import socket

TIMEOUT = 5.0


def probe(host, port):
    try:
        sock = socket.create_connection((host, port), TIMEOUT)
        banner = sock.recv(64)
        sock.close()
        return banner.decode().‸


def parse_banner(banner):
    return banner.split()
