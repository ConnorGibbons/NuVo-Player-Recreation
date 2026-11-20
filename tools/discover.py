#!/usr/bin/env python3
"""Find every Nuvo zone on the LAN. Read-only; changes nothing.

Usage:  python3 discover.py [known-zone-ip]     (default 10.0.0.91)

Three methods: repeated multicast SSDP, a unicast SSDP sweep of the /24,
and mDNS (via macOS dns-sd). Then asks each zone who it is, and asks one
zone to list the system's line inputs (one per zone in the system).
Output: ./captures/discover-log.txt and zone_<ip>.xml files.
"""
import os, re, socket, subprocess, sys, urllib.request, urllib.parse, html

KNOWN = sys.argv[1] if len(sys.argv) > 1 else "10.0.0.91"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "captures")
os.makedirs(OUT, exist_ok=True)
lines = []
def log(*a):
    s = " ".join(str(x) for x in a); print(s); lines.append(s)

def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((KNOWN, 9)); ip = s.getsockname()[0]; s.close(); return ip

ME = local_ip()
PREFIX = ME.rsplit(".", 1)[0]
log("This Mac: %s   sweeping %s.1-254" % (ME, PREFIX))

def msearch(st, mx=3):
    return ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
            'MAN: "ssdp:discover"\r\nMX: %d\r\nST: %s\r\n\r\n' % (mx, st)).encode()

def collect(sock, wait, found):
    sock.settimeout(wait)
    try:
        while True:
            data, addr = sock.recvfrom(65535)
            t = data.decode(errors="replace")
            m = re.search(r"(?im)^location:\s*(\S+)", t)
            srv = re.search(r"(?im)^server:\s*(.+)$", t)
            st = re.search(r"(?im)^st:\s*(.+)$", t)
            if m:
                found.setdefault(addr[0], {})[m.group(1)] = (
                    (srv.group(1).strip() if srv else "?"), (st.group(1).strip() if st else "?"))
    except socket.timeout:
        pass

found = {}
# 1. multicast, several rounds, bound to the right interface
log("\n== Multicast SSDP (4 rounds) ==")
for rnd in range(4):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    try:
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ME))
    except OSError:
        pass
    for st in ("urn:schemas-nuvotechnologies-com:device:Zone:1", "upnp:rootdevice", "ssdp:all"):
        s.sendto(msearch(st), ("239.255.255.250", 1900))
    collect(s, 4, found); s.close()
    log("  round %d: %d hosts so far" % (rnd + 1, len(found)))

# 2. unicast sweep
log("\n== Unicast SSDP sweep ==")
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for i in range(1, 255):
    for st in ("urn:schemas-nuvotechnologies-com:device:Zone:1", "upnp:rootdevice"):
        try:
            s.sendto(msearch(st, 1), ("%s.%d" % (PREFIX, i), 1900))
        except OSError:
            pass
collect(s, 5, found); s.close()

log("\n== All UPnP devices seen ==")
for ip in sorted(found, key=lambda x: tuple(int(p) for p in x.split("."))):
    for loc, (srv, st) in found[ip].items():
        log("  %-14s %s  [%s]" % (ip, loc, srv))

# 3. mDNS
log("\n== mDNS ==")
for svc in ("_nuvoplayer._tcp", "_nuvomaster._tcp", "_spotify-connect._tcp", "_airplay._tcp"):
    try:
        p = subprocess.run(["dns-sd", "-Z", svc, "local"], capture_output=True, text=True, timeout=5)
        out = p.stdout
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
    except Exception as e:
        out = repr(e)
    keep = [l for l in out.splitlines() if l.strip() and not l.startswith(";") and "Browsing" not in l]
    log("  -- %s" % svc)
    for l in keep[:40]:
        log("     " + l)

# 4. interrogate zones
def soap(ctl, stype, action, args=""):
    body = ('<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:%s xmlns:u="%s">%s</u:%s>'
            '</s:Body></s:Envelope>' % (action, stype, args, action)).encode()
    req = urllib.request.Request(ctl, data=body, headers={
        "Content-Type": 'text/xml; charset="utf-8"', "SOAPACTION": '"%s#%s"' % (stype, action)})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:
        return 0, repr(e)

ZONE = "urn:schemas-nuvotechnologies-com:service:Zone:1"
CD = "urn:schemas-upnp-org:service:ContentDirectory:1"
zones = {}
for ip, locs in found.items():
    for loc in locs:
        if re.search(r"/00000000-0000-0000-0000-[0-9a-f]{12}\.xml$", loc):
            zones[loc] = ip
log("\n== Nuvo zones: %d ==" % len(zones))
for loc, ip in sorted(zones.items(), key=lambda kv: kv[1]):
    base = loc.rsplit("/", 1)[0]
    code, resp = soap(base + "/ZoneService/control", ZONE, "Get")
    mac = loc[-16:-4]
    open(os.path.join(OUT, "zone_%s_%s.xml" % (ip, mac)), "w").write(resp)
    f = {k: html.unescape(v) for k, v in re.findall(r"<(\w+)>([^<]*)</\1>", resp)}
    log("  %-14s %-22s model=%-6s fw=%-7s power=%-8s input=%-8s member=%s"
        % (ip, f.get("Title"), f.get("Model"), f.get("FirmwareVersion"),
           f.get("PowerState"), f.get("AudioInput"), f.get("MemberGroup")))
    for port in (80, 4747):
        t = socket.socket(); t.settimeout(2)
        try:
            t.connect((ip, port)); state = "open"
        except Exception as e:
            state = type(e).__name__
        t.close()
        log("       tcp/%d %s" % (port, state))

# 5. ask one zone for the whole system's line inputs (lists every zone)
if zones:
    loc = sorted(zones)[0]
    base = loc.rsplit("/", 1)[0]
    log("\n== System line inputs, asked via %s ==" % zones[loc])
    for oid in ("lineIn:systemLineIns",):
        args = ("<ObjectID>%s</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter>"
                "<StartingIndex>0</StartingIndex><RequestedCount>50</RequestedCount><SortCriteria></SortCriteria>" % oid)
        code, resp = soap(base + "/ContentDirectory/control", CD, "Browse", args)
        open(os.path.join(OUT, "browse_%s.xml" % oid.replace(":", "_")), "w").write(resp)
        didl = html.unescape(resp)
        titles = re.findall(r"<dc:title>([^<]*)</dc:title>", didl)
        ids = re.findall(r'<item id="([^"]*)"', didl)
        log("  HTTP %s, %d items" % (code, len(titles)))
        for t, i in zip(titles, ids):
            log("    %-28s %s" % (t, i))

open(os.path.join(OUT, "discover-log.txt"), "w").write("\n".join(lines) + "\n")
print("\nDone. Saved to", os.path.join(OUT, "discover-log.txt"))
