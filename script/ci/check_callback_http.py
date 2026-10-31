#!/usr/bin/env python3
"""Check a generated callback fixture's native HTTP response (server already running)."""
import sys
import urllib.request
response = urllib.request.urlopen(sys.argv[1], timeout=5)
assert response.status == 200
assert response.headers['audit'] == 'yes'
assert response.read() == (sys.argv[2].encode() if len(sys.argv) > 2 else b'auth')
print('PASS native callback/concern HTTP response')
