#!/usr/bin/env python3 -I
"""Symbolicate Atria frames in .ips reports (text 'Atria + N' frames and JSON bug_type 309 crashes).
usage: symbolicate_atria_reports.py <dwarf> <out_dir> <report>...  Writes <report>.sym.txt per report."""
import json, re, subprocess, sys, os
dwarf, out_dir, reports = sys.argv[1], sys.argv[2], sys.argv[3:]
BASE = 0x100000000
TEXT_RE = re.compile(r"\?\?\? \(Atria \+ (\d+)\)")
def offsets_text(body): return {int(m) for m in TEXT_RE.findall(body)}
def json_frames(body):
    lines = body.split("\n", 1)
    try: d = json.loads(lines[1])
    except Exception: return None
    imgs = d.get("usedImages", [])
    idx = [i for i, im in enumerate(imgs) if im.get("name") == "Atria"]
    return d, set(idx)
offs = set(); parsed = {}
for r in reports:
    body = open(r, errors="replace").read()
    offs |= offsets_text(body)
    jf = json_frames(body) if body.lstrip().startswith("{") and '"usedImages"' in body else None
    parsed[r] = (body, jf)
    if jf:
        d, idx = jf
        for t in d.get("threads", []) + ([{"frames": d["lastExceptionBacktrace"]}] if "lastExceptionBacktrace" in d else []):
            for f in t.get("frames", []):
                if f.get("imageIndex") in idx: offs.add(f["imageOffset"])
offs = sorted(offs)
names = {}
for i in range(0, len(offs), 400):
    chunk = offs[i:i+400]
    out = subprocess.run(["atos", "-o", dwarf, "-arch", "arm64", "-l", hex(BASE)] + [hex(BASE + o) for o in chunk],
                         capture_output=True, text=True).stdout.splitlines()
    names.update(zip(chunk, out))
os.makedirs(out_dir, exist_ok=True)
for r, (body, jf) in parsed.items():
    res = TEXT_RE.sub(lambda m: "Atria+%s %s" % (m.group(1), names.get(int(m.group(1)), "?")), body)
    if jf:
        d, idx = jf
        res = []
        def dump(title, frames):
            res.append(title)
            for n, f in enumerate(frames):
                im = d["usedImages"][f["imageIndex"]].get("name", "?") if f.get("imageIndex") is not None else "?"
                sym = names.get(f["imageOffset"]) if f.get("imageIndex") in idx else f.get("symbol", "")
                res.append("  %2d %-22s %s" % (n, im, sym))
        if "lastExceptionBacktrace" in d: dump("lastExceptionBacktrace", d["lastExceptionBacktrace"])
        for ti, t in enumerate(d.get("threads", [])):
            dump("thread %d %s %s %s" % (ti, t.get("queue", ""), t.get("name", ""), "TRIGGERED" if t.get("triggered") else ""), t.get("frames", []))
        res = "\n".join(res)
    open(os.path.join(out_dir, os.path.basename(r) + ".sym.txt"), "w").write(res)
print("symbolicated %d offsets across %d reports" % (len(offs), len(reports)))
