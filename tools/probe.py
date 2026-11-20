#!/usr/bin/env python3
"""Read-only probe of a Nuvo Player Portfolio zone.

Usage:  python3 probe.py [zone-ip]        (default 10.0.0.48)

Sends SSDP searches, downloads the UPnP device description and every
service description (SCPD), and calls a handful of read-only SOAP actions.
It changes nothing on the amp. Output goes to ./captures/.
"""
import os, re, socket, sys, urllib.request, urllib.parse
import xml.etree.ElementTree as ET

IP = sys.argv[1] if len(sys.argv) > 1 else "10.0.0.48"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "captures")
os.makedirs(OUT, exist_ok=True)
log_lines = []

def log(*a):
    s = " ".join(str(x) for x in a)
    print(s)
    log_lines.append(s)

def save(name, data):
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", name)
    mode = "wb" if isinstance(data, bytes) else "w"
    with open(os.path.join(OUT, name), mode) as f:
        f.write(data)

def ssdp(target, st, wait=3):
    msg = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
           'MAN: "ssdp:discover"\r\nMX: 2\r\nST: %s\r\n\r\n' % st).encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.settimeout(wait)
    found = []
    try:
        s.sendto(msg, (target, 1900))
        while True:
            data, addr = s.recvfrom(65535)
            found.append((addr[0], data.decode(errors="replace")))
    except socket.timeout:
        pass
    except OSError as e:
        log("  ssdp error to", target, e)
    s.close()
    return found

def http_get(url, timeout=6):
    req = urllib.request.Request(url, headers={"User-Agent": "nuvo-probe"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, dict(r.headers), r.read()

def soap(control_url, service_type, action, args=""):
    body = ('<?xml version="1.0" encoding="utf-8"?>'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            '<u:%s xmlns:u="%s">%s</u:%s></s:Body></s:Envelope>'
            % (action, service_type, args, action)).encode()
    req = urllib.request.Request(control_url, data=body, headers={
        "Content-Type": 'text/xml; charset="utf-8"',
        "SOAPACTION": '"%s#%s"' % (service_type, action)})
    try:
        with urllib.request.urlopen(req, timeout=6) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:
        return 0, repr(e)

def strip(tag):
    return tag.split("}", 1)[-1]

# 1. Discovery --------------------------------------------------------------
log("== SSDP ==")
locations = {}
for target in ("239.255.255.250", IP):
    for st in ("urn:schemas-nuvotechnologies-com:device:Zone:1", "ssdp:all"):
        for addr, text in ssdp(target, st):
            m = re.search(r"(?im)^location:\s*(\S+)", text)
            srv = re.search(r"(?im)^server:\s*(.+)$", text)
            if m and "nuvo" in text.lower() or (m and addr == IP):
                if m.group(1) not in locations:
                    locations[m.group(1)] = addr
                    log("  %s  %s  [%s]" % (addr, m.group(1), srv.group(1).strip() if srv else "?"))
                    save("ssdp_%s.txt" % addr, text)
if not locations:
    log("  No SSDP answers. Check the IP, and that this Mac is on the same network/VLAN.")

# 2. Port 80 (web UI / JSON API) ---------------------------------------------
log("\n== Port 80 on %s ==" % IP)
try:
    st, hdrs, data = http_get("http://%s/" % IP)
    log("  HTTP", st, "Server:", hdrs.get("Server"), "bytes:", len(data))
    save("port80_index.html", data)
except Exception as e:
    log("  ", repr(e))
for p in (4747,):
    s = socket.socket(); s.settimeout(2)
    try:
        s.connect((IP, p)); log("  tcp/%d open" % p)
    except Exception as e:
        log("  tcp/%d %r" % (p, e))
    s.close()

# 3. Descriptions, SCPDs, read-only actions ----------------------------------
READS = {  # service-type suffix -> [(action, args)]
    "service:Zone:1": [("Get", ""), ("GetFirmwareVersion", ""), ("GetSystemID", ""), ("GetMemberID", "")],
    "service:RenderingControl:1": [("GetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel>"),
                                   ("GetMute", "<InstanceID>0</InstanceID><Channel>Master</Channel>")],
    "service:AVTransport:1": [("GetTransportInfo", "<InstanceID>0</InstanceID>"),
                              ("GetMediaInfo", "<InstanceID>0</InstanceID>"),
                              ("GetPositionInfo", "<InstanceID>0</InstanceID>"),
                              ("GetCurrentTransportActions", "<InstanceID>0</InstanceID>")],
    "service:ContentDirectory:1": [("Browse", "<ObjectID>0</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag>"
                                    "<Filter>*</Filter><StartingIndex>0</StartingIndex>"
                                    "<RequestedCount>50</RequestedCount><SortCriteria></SortCriteria>")],
}

for loc, addr in locations.items():
    log("\n== Device %s ==" % loc)
    try:
        _, _, raw = http_get(loc)
    except Exception as e:
        log("  description fetch failed:", repr(e)); continue
    # The serialNumber doubles as the web UI login secret, so redact it on disk.
    text = re.sub(r"(<serialNumber>)[^<]*(</serialNumber>)", r"\1REDACTED\2", raw.decode(errors="replace"))
    save("desc_%s.xml" % addr, text)
    root = ET.fromstring(raw)
    for el in root.iter():
        if strip(el.tag) in ("deviceType", "friendlyName", "manufacturer", "modelName",
                             "modelNumber", "modelDescription", "UDN"):
            log("  %-16s %s" % (strip(el.tag), (el.text or "").strip()))
    for svc in [e for e in root.iter() if strip(e.tag) == "service"]:
        f = {strip(c.tag): (c.text or "").strip() for c in svc}
        stype = f.get("serviceType", "")
        log("\n  -- %s" % stype)
        log("     control=%s event=%s scpd=%s" % (f.get("controlURL"), f.get("eventSubURL"), f.get("SCPDURL")))
        tag = "%s_%s" % (addr, (f.get("controlURL") or stype).strip("/").replace("/", "-"))
        try:
            _, _, scpd = http_get(urllib.parse.urljoin(loc, f.get("SCPDURL", "")))
            save("scpd_%s.xml" % tag, scpd)
            sroot = ET.fromstring(scpd)
            for act in [e for e in sroot.iter() if strip(e.tag) == "action"]:
                name, ins, outs = "", [], []
                for c in act.iter():
                    if strip(c.tag) == "name" and not name:
                        name = c.text
                    if strip(c.tag) == "argument":
                        a = {strip(x.tag): (x.text or "") for x in c}
                        (ins if a.get("direction") == "in" else outs).append(a.get("name"))
                log("     %s(%s) -> %s" % (name, ", ".join(ins), ", ".join(outs) or "-"))
        except Exception as e:
            log("     scpd fetch failed:", repr(e))
        ctl = urllib.parse.urljoin(loc, f.get("controlURL", ""))
        for suffix, calls in READS.items():
            if stype.endswith(suffix):
                for action, args in calls:
                    code, resp = soap(ctl, stype, action, args)
                    save("soap_%s_%s.xml" % (tag, action), resp)
                    log("     [read] %s -> HTTP %s, %d bytes" % (action, code, len(resp)))

save("probe-log.txt", "\n".join(log_lines) + "\n")
print("\nDone. Results are in", OUT)
