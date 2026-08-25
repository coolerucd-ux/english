#!/usr/bin/env python3
"""Regenerate the bundled offline fallback dictionary (Resources/offline_dict.json).

The offline dictionary is the no-network safety net (subway case) — a COMPACT
common-word English→Chinese list, NOT the full 770k-entry ECDICT. We distill the
common core (exam syllabi + Oxford/Collins high-frequency + top frequency ranks)
so the bundle stays ~2MB with pure-Foundation JSON parsing (no runtime deps).

Usage:
    python3 tools/build_offline_dict.py [path/to/ecdict.csv]

If no CSV path is given it downloads the full ECDICT from GitHub (MIT license):
    https://github.com/skywind3000/ECDICT

Data source: ECDICT by skywind3000, MIT License.
"""
import csv, json, os, re, sys, urllib.request

ECDICT_URL = "https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv"
OUT = os.path.join(os.path.dirname(__file__), "..", "PointWord", "Resources", "offline_dict.json")
EXAM_TAGS = ("zk", "gk", "cet4", "cet6", "ky", "toefl", "ielts", "gre")
FREQ_CUTOFF = 20000          # keep words ranked in the top 20k by frq or bnc
MAX_DEF_LEN = 60             # cap a single translation so no entry bloats the bundle

csv.field_size_limit(10**7)


def toint(x):
    x = (x or "").strip()
    return int(x) if x.isdigit() else 0


def clean_translation(tr):
    # ECDICT joins multiple POS senses with literal "\n"; drop web-slang noise.
    parts = [p.strip() for p in tr.split("\\n")]
    parts = [p for p in parts if p and not p.startswith("[网络]") and not p.startswith("[俚语]")]
    if not parts:
        parts = [tr.replace("\\n", "；").strip()]
    joined = re.sub(r"\s+", " ", " ".join(parts)).strip()
    if len(joined) > MAX_DEF_LEN:
        joined = joined[:MAX_DEF_LEN].rstrip("；;，, ") + "…"
    return joined


def selected(row):
    tag = (row.get("tag") or "").split()
    if any(t in tag for t in EXAM_TAGS):
        return True
    if (row.get("oxford") or "").strip() == "1":
        return True
    cl = (row.get("collins") or "").strip()
    if cl.isdigit() and int(cl) >= 1:
        return True
    frq, bnc = toint(row.get("frq")), toint(row.get("bnc"))
    return (0 < frq <= FREQ_CUTOFF) or (0 < bnc <= FREQ_CUTOFF)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else None
    if not src:
        src = "/tmp/ecdict_full.csv"
        if not os.path.exists(src):
            print("downloading ECDICT…")
            urllib.request.urlretrieve(ECDICT_URL, src)

    out = {}
    with open(src, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            w = (row.get("word") or "").strip()
            tr = (row.get("translation") or "").strip()
            if not w or not tr:
                continue
            if not re.fullmatch(r"[A-Za-z][A-Za-z\-']{0,24}", w):
                continue                          # single clean tokens only
            if not selected(row):
                continue
            key = w.lower()
            if key in out:
                continue
            entry = {"t": clean_translation(tr)}
            ph = (row.get("phonetic") or "").strip()
            if ph:
                entry["p"] = ph
            out[key] = entry

    data = json.dumps(out, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(data)
    print(f"wrote {len(out)} entries → {OUT} ({os.path.getsize(OUT)/1024/1024:.2f} MB)")


if __name__ == "__main__":
    main()
