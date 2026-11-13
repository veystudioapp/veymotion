#!/usr/bin/env python3
"""Markdown score table for one benchmark run (scripts/bench/run.sh), or a comparison of two.

    summary.py bench-out/<run> [bench-out/<other-run>]
"""
import json, os, re, sys


def load(run):
    rows = {}
    for id in sorted(os.listdir(run)):
        d = os.path.join(run, id)
        if not os.path.isdir(d):
            continue
        row = {"lint": None, "scores": {}, "overall": None, "time": None, "cost": None, "error": None}
        try:
            rev = json.load(open(os.path.join(d, "review.json")))[0]
            row["lint"] = sum(1 for i in rev.get("lint", []) if i.get("severity") in ("warning", "error"))
            if "review" in rev:
                row["scores"] = rev["review"].get("scores", {})
                vals = list(row["scores"].values())
                row["overall"] = sum(vals) / len(vals) if vals else None
            elif "reviewError" in rev:
                row["error"] = rev["reviewError"]
        except Exception as e:  # no review yet / failed run
            row["error"] = f"no review ({e.__class__.__name__})"
        try:
            log = open(os.path.join(d, "chat.log"), errors="replace").read()
            m = re.findall(r"· (done|error) · ([\d.]+)s · \$([\d.]+)", log)
            if m:
                row["time"] = float(m[-1][1])
                row["cost"] = float(m[-1][2])
                if m[-1][0] == "error":
                    row["error"] = row["error"] or "agent turn ended in error"
        except FileNotFoundError:
            pass
        rows[id] = row
    return rows


def fmt(v, f="{:.1f}"):
    return "–" if v is None else f.format(v)


def table(run, rows):
    names = []
    for r in rows.values():
        for k in r["scores"]:
            if k not in names:
                names.append(k)
    head = ["prompt", "lint"] + names + ["overall", "time s", "cost $"]
    out = [f"### {os.path.basename(run)}", "", "| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    for id, r in rows.items():
        cells = [id, fmt(r["lint"], "{}")] + [fmt(r["scores"].get(n), "{}") for n in names]
        cells += [fmt(r["overall"]), fmt(r["time"], "{:.0f}"), fmt(r["cost"], "{:.2f}")]
        out.append("| " + " | ".join(cells) + " |")
        if r["error"]:
            out.append(f"|  ↳ {r['error'][:100]} |" + " |" * (len(head) - 1))
    ov = [r["overall"] for r in rows.values() if r["overall"] is not None]
    li = [r["lint"] for r in rows.values() if r["lint"] is not None]
    co = [r["cost"] for r in rows.values() if r["cost"] is not None]
    out.append("")
    out.append(f"mean overall {fmt(sum(ov) / len(ov) if ov else None)} · mean lint {fmt(sum(li) / len(li) if li else None)} · "
               f"total cost ${fmt(sum(co) if co else None, '{:.2f}')} · {len(rows)} prompts")
    return "\n".join(out)


def compare(a, ra, b, rb):
    out = [f"### {os.path.basename(a)} → {os.path.basename(b)}", "", "| prompt | overall | lint |", "|---|---|---|"]
    for id in sorted(set(ra) | set(rb)):
        x, y = ra.get(id, {}), rb.get(id, {})
        out.append(f"| {id} | {fmt(x.get('overall'))} → {fmt(y.get('overall'))} | {fmt(x.get('lint'), '{}')} → {fmt(y.get('lint'), '{}')} |")
    return "\n".join(out)


if __name__ == "__main__":
    runs = sys.argv[1:]
    if not runs:
        sys.exit(__doc__)
    rows = [load(r) for r in runs]
    print(table(runs[0], rows[0]))
    if len(runs) > 1:
        print()
        print(table(runs[1], rows[1]))
        print()
        print(compare(runs[0], rows[0], runs[1], rows[1]))
