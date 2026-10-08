#!/usr/bin/env python3
"""Preflight the design sheets: lay every row over every column and list what is not done.

    python3 tools/preflight.py          # full report, exit 1 if anything blocks a build
    python3 tools/preflight.py --brief  # counts only

Blocking (exit 1): an empty cell, a cell still holding a guess marked with '?', a wrong type,
a duplicate id, or a reference to another sheet that does not resolve.
Open checkboxes (reported, not blocking until release): rows with verified=false, and rows with
implemented=false. Together these are the build and in-game test checklist.
"""
import json
import sys
from pathlib import Path

SHEETS = Path(__file__).resolve().parent.parent / "sheets"


def load():
    out = {}
    for p in sorted(SHEETS.glob("*.json")):
        d = json.loads(p.read_text(encoding="utf-8"))
        out[d["sheet"]] = d
    return out


def ids(sheet):
    return {r["id"] for r in sheet["rows"]}


def check_cell(sheets, sname, row, col, t, v, errs):
    where = f"{sname}.{row.get('id', '?')}.{col}"
    if v is None or v == "" or v == []:
        if not (sname == "settings" and col == "value"):
            errs.append(f"{where}: empty")
        return
    if isinstance(v, str) and "?" in v:
        errs.append(f"{where}: guess still marked '?' ({v!r})")
    if isinstance(v, list):
        for x in v:
            if isinstance(x, str) and "?" in x:
                errs.append(f"{where}: guess still marked '?' ({x!r})")
    base = t
    if t.startswith("list"):
        if not isinstance(v, list):
            errs.append(f"{where}: expected a list")
            return
        base = t[5:] if t.startswith("list:") else "any"
        vals = v
    else:
        vals = [v]
    for x in vals:
        if base.startswith("ref:"):
            target = base[4:]
            if target not in sheets:
                errs.append(f"{where}: refers to missing sheet {target}")
            elif x not in ids(sheets[target]):
                errs.append(f"{where}: {x!r} not found in {target}")
        elif base.startswith("enum:"):
            if x not in base[5:].split("|"):
                errs.append(f"{where}: {x!r} not one of {base[5:]}")
        elif base == "int" and not (isinstance(x, int) and not isinstance(x, bool)):
            errs.append(f"{where}: expected int")
        elif base == "bool" and not isinstance(x, bool):
            errs.append(f"{where}: expected bool")
        elif base == "string" and not isinstance(x, str):
            errs.append(f"{where}: expected string")


def main():
    brief = "--brief" in sys.argv
    sheets = load()
    errs, unverified, unimplemented = [], [], []
    cells = 0
    for sname, s in sheets.items():
        seen = set()
        for row in s["rows"]:
            rid = row.get("id")
            if rid in seen:
                errs.append(f"{sname}.{rid}: duplicate id")
            seen.add(rid)
            for col in row:
                if col not in s["columns"]:
                    errs.append(f"{sname}.{rid}.{col}: column not declared")
            for col, spec in s["columns"].items():
                cells += 1
                check_cell(sheets, sname, row, col, spec["type"], row.get(col), errs)
            if row.get("verified") is False:
                unverified.append(f"{sname}.{rid}")
            if row.get("implemented") is False:
                unimplemented.append(f"{sname}.{rid}")
        # weapons.fire may name a fire_logic row or class_default
    for r in sheets.get("weapons", {}).get("rows", []):
        if r["fire"] != "class_default" and r["fire"] not in ids(sheets["fire_logic"]):
            errs.append(f"weapons.{r['id']}.fire: {r['fire']!r} not in fire_logic")

    rows = sum(len(s["rows"]) for s in sheets.values())
    print(f"{len(sheets)} sheets, {rows} rows, {cells} cells")
    print(f"blocking: {len(errs)}   unverified rows: {len(unverified)}   unimplemented rows: {len(unimplemented)}")
    if not brief:
        for title, items in (("BLOCKING", errs), ("NOT IMPLEMENTED", unimplemented), ("NOT VERIFIED", unverified)):
            if items:
                print(f"\n== {title} ==")
                for e in items:
                    print("  " + e)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
