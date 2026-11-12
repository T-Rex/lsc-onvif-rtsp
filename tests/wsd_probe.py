#!/usr/bin/env python3
"""WS-Discovery test client (build container only, not needed on the camera).

  wsd_probe.py probe  --target ADDR [--iface-ip IP] [--types T] --xaddr URL [--uuid UUID]
      Send a standard ONVIF Probe to ADDR:3702 (multicast 239.255.255.250 or a
      unicast address) and validate the ProbeMatches answer.

  wsd_probe.py listen --iface-ip IP --seconds N --expect Bye,Hello
      Join 239.255.255.250:3702 and wait for Hello/Bye announcements.
"""
import argparse
import socket
import struct
import sys
import time
import uuid
import xml.etree.ElementTree as ET

MCAST = "239.255.255.250"
PORT = 3702
NS = {
    "s": "http://www.w3.org/2003/05/soap-envelope",
    "a": "http://schemas.xmlsoap.org/ws/2004/08/addressing",
    "d": "http://schemas.xmlsoap.org/ws/2005/04/discovery",
}

PROBE = """<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing"
            xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
            xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
  <s:Header>
    <a:Action s:mustUnderstand="1">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action>
    <a:MessageID>uuid:{msgid}</a:MessageID>
    <a:ReplyTo><a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address></a:ReplyTo>
    <a:To s:mustUnderstand="1">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To>
  </s:Header>
  <s:Body>
    <d:Probe>{types}</d:Probe>
  </s:Body>
</s:Envelope>"""


def text(root, path):
    el = root.find(path, NS)
    return (el.text or "").strip() if el is not None else ""


def probe(args):
    msgid = str(uuid.uuid4())
    types = "<d:Types>%s</d:Types>" % args.types if args.types else ""
    data = PROBE.format(msgid=msgid, types=types).encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
    if args.iface_ip:
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(args.iface_ip))
    s.bind(("", 0))
    s.settimeout(1.0)
    s.sendto(data, (args.target, PORT))
    print("sent Probe (%d bytes) to %s:%d, MessageID uuid:%s" % (len(data), args.target, PORT, msgid))
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        try:
            pkt, src = s.recvfrom(65535)
        except socket.timeout:
            continue
        try:
            root = ET.fromstring(pkt)
        except ET.ParseError as e:
            print("FAIL: malformed XML from %s: %s" % (src, e))
            return 1
        action = text(root, "s:Header/a:Action")
        if not action.endswith("/ProbeMatches"):
            continue
        relates = text(root, "s:Header/a:RelatesTo")
        m = root.find("s:Body/d:ProbeMatches/d:ProbeMatch", NS)
        xaddrs = text(m, "d:XAddrs") if m is not None else ""
        scopes = text(m, "d:Scopes") if m is not None else ""
        typ = text(m, "d:Types") if m is not None else ""
        addr = text(m, "a:EndpointReference/a:Address") if m is not None else ""
        print("ProbeMatches from %s:%d (%d bytes)" % (src[0], src[1], len(pkt)))
        print("  RelatesTo : %s" % relates)
        print("  Endpoint  : %s" % addr)
        print("  Types     : %s" % typ)
        print("  XAddrs    : %s" % xaddrs)
        print("  Scopes    : %s" % scopes)
        errors = []
        if relates != "uuid:" + msgid:
            errors.append("RelatesTo does not match the Probe MessageID")
        if args.xaddr not in xaddrs.split():
            errors.append("XAddrs does not contain %s" % args.xaddr)
        if not typ.endswith("NetworkVideoTransmitter"):
            errors.append("Types is not NetworkVideoTransmitter")
        if args.uuid and addr != "urn:uuid:" + args.uuid:
            errors.append("EndpointReference %s differs from GetEndpointReference urn:uuid:%s" % (addr, args.uuid))
        sl = scopes.split()
        if "onvif://www.onvif.org/Profile/Streaming" not in sl:
            errors.append("Profile/Streaming scope missing")
        bad = [x for x in sl if "/ptz" in x.lower() or x.endswith("/Profile/T")]
        if bad:
            errors.append("unsupported scopes advertised: %s" % bad)
        for e in errors:
            print("FAIL: " + e)
        return 1 if errors else 0
    print("FAIL: no ProbeMatches within %ss" % args.timeout)
    return 1


def listen(args):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", PORT))
    mreq = struct.pack("4s4s", socket.inet_aton(MCAST), socket.inet_aton(args.iface_ip))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    s.settimeout(1.0)
    want = [w for w in args.expect.split(",") if w]
    seen = []
    deadline = time.time() + args.seconds
    while time.time() < deadline and len(seen) < len(want):
        try:
            pkt, src = s.recvfrom(65535)
        except socket.timeout:
            continue
        try:
            root = ET.fromstring(pkt)
        except ET.ParseError:
            continue
        action = text(root, "s:Header/a:Action").rsplit("/", 1)[-1]
        if action in ("Hello", "Bye"):
            xaddrs = text(root, "s:Body/d:%s/d:XAddrs" % action)
            print("%s from %s (%d bytes) XAddrs=%s" % (action, src[0], len(pkt), xaddrs or "-"))
            if action in want and action not in seen and want[len(seen)] == action:
                seen.append(action)
    print("RESULT %s (expected %s, got %s)" % ("OK" if seen == want else "FAIL", want, seen))
    return 0 if seen == want else 1


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("probe")
    a.add_argument("--target", required=True)
    a.add_argument("--iface-ip")
    a.add_argument("--types", default="")
    a.add_argument("--xaddr", required=True)
    a.add_argument("--uuid")
    a.add_argument("--timeout", type=float, default=8.0)
    b = sub.add_parser("listen")
    b.add_argument("--iface-ip", required=True)
    b.add_argument("--seconds", type=float, default=20)
    b.add_argument("--expect", default="Hello")
    args = p.parse_args()
    return probe(args) if args.cmd == "probe" else listen(args)


if __name__ == "__main__":
    sys.exit(main())
