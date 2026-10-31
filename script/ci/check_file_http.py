#!/usr/bin/env python3
"""Exercise file_actions.rb on an already-running compiled server."""
import http.client
import os
import socket
import sys
import urllib.parse

url = urllib.parse.urlsplit(sys.argv[1])
payload = bytes(range(256)) * 8192

def request(method, path, body=None, headers=None):
    connection = http.client.HTTPConnection(url.hostname, url.port, timeout=15)
    connection.request(method, path, body, headers or {})
    response = connection.getresponse()
    result = response.status, dict(response.getheaders()), response.read()
    connection.close()
    return result

def multipart(data, filename='binary.bin'):
    return (b'--edge\r\nContent-Disposition: form-data; name="title"\r\n\r\none\r\n'
            b'--edge\r\nContent-Disposition: form-data; name="title"\r\n\r\ntwo\r\n'
            b'--edge\r\nContent-Disposition: form-data; name="file"; filename="' + filename.encode() +
            b'"\r\nContent-Type: application/octet-stream\r\n\r\n' + data + b'\r\n--edge--\r\n')

for data in (payload, b''):
    status, headers, body = request('POST', '/upload', multipart(data), {'Content-Type': 'multipart/form-data; boundary=edge'})
    assert status == 200, (status, body)
    assert body == data
    assert headers['x-title'] == 'one,two'
assert request('POST', '/upload', multipart(b'x', '../escape'), {'Content-Type': 'multipart/form-data; boundary=edge'})[0] == 400
assert request('POST', '/upload', b'bad', {'Content-Type': 'multipart/form-data; boundary=edge'})[0] == 400
connection = http.client.HTTPConnection(url.hostname, url.port, timeout=5)
connection.putrequest('POST', '/upload')
connection.putheader('Content-Length', '5000000')
connection.putheader('Content-Type', 'multipart/form-data; boundary=edge')
connection.endheaders()
assert connection.getresponse().status == 413
connection.close()
status, headers, body = request('GET', '/download')
assert status == 200 and body == payload
assert headers['transfer-encoding'] == 'chunked'
status, headers, body = request('HEAD', '/download')
assert status == 200 and body == b''
# Abort a download; the next request must still succeed.
sock = socket.create_connection((url.hostname, url.port), timeout=5)
sock.sendall(b'GET /download HTTP/1.1\r\nHost: localhost\r\n\r\n')
sock.recv(256)
sock.close()
assert request('HEAD', '/download')[0] == 200
print('PASS native multipart binary/empty/limits/malformed and streaming GET/HEAD/disconnect')
