#!/usr/bin/env python3
"""Print a WS-Security UsernameToken (PasswordDigest) SOAP header block.

  wsse.py USER PASSWORD

Digest = Base64(SHA1(nonce + created + password)), as ONVIF clients send it.
"""
import base64
import datetime
import hashlib
import os
import sys

user, password = sys.argv[1], sys.argv[2]
nonce = os.urandom(16)
created = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
digest = base64.b64encode(hashlib.sha1(nonce + created.encode() + password.encode()).digest()).decode()
print(
    '<wsse:Security s:mustUnderstand="1"><wsse:UsernameToken>'
    "<wsse:Username>%s</wsse:Username>"
    '<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">%s</wsse:Password>'
    '<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">%s</wsse:Nonce>'
    "<wsu:Created>%s</wsu:Created>"
    "</wsse:UsernameToken></wsse:Security>"
    % (user, digest, base64.b64encode(nonce).decode(), created)
)
