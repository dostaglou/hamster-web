import json
import sys
import urllib.request
import urllib.error

base = sys.argv[1]
def request(body, content_type):
    req = urllib.request.Request(base + '/json', data=body, headers={'Content-Type': content_type})
    try:
        return urllib.request.urlopen(req)
    except urllib.error.HTTPError as error:
        return error

value = {'text': '日本語\n"\\', 'nested': [None, True, False, 12, 1.5]}
with request(json.dumps(value).encode(), 'application/json') as response:
    assert response.status == 201
    assert response.headers.get_content_type() == 'application/json'
    assert json.load(response) == value
assert request(b'{broken', 'application/json').status == 400
assert request(b'{}', 'text/plain').status == 415
