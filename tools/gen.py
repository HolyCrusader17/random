#!/usr/bin/env python3
"""Preflight the design sheets, then generate code from them.

    python3 tools/gen.py            # preflight + generate
    python3 tools/gen.py --check    # preflight only

Every sheet row becomes one struct: a Lua table in mod/RoNUltrakill/Scripts/sheets.lua and a C#
class instance in helper/UKAudio/Sheets.g.cs. The sheets are the source of truth; never edit the
generated files by hand.

Preflight fails (exit 1) on anything that would break the build: an empty cell, a wrong type, a
duplicate id, a reference that doesn't resolve, a mode without its points/effect columns, a
settings key or hook named in a rule that doesn't exist, or a row the code never uses. It also
lists, without failing, every row still unverified in the running game and every hook not yet
implemented: that is the in-game test checklist.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHEETS = ROOT / "sheets"
LUA_OUT = ROOT / "mod" / "RoNUltrakill" / "Scripts" / "sheets.lua"
CS_OUT = ROOT / "helper" / "UKAudio" / "Sheets.g.cs"
LUA_MAIN = ROOT / "mod" / "RoNUltrakill" / "Scripts" / "main.lua"
CS_DIR = ROOT / "helper" / "UKAudio"
FILE_EXTS = {"cfg", "log", "txt", "json", "lua", "ini"}


def load():
    sheets = {}
    for p in sorted(SHEETS.glob("*.json")):
        d = json.loads(p.read_text(encoding="utf-8"))
        sheets[d["sheet"]] = d
    return sheets


def check_type(t, v):
    if t == "any":
        return v is not None and v != ""
    if t == "string":
        return isinstance(v, str) and v.strip() != ""
    if t == "int":
        return isinstance(v, int) and not isinstance(v, bool)
    if t == "number":
        return isinstance(v, (int, float)) and not isinstance(v, bool)
    if t == "bool":
        return isinstance(v, bool)
    if t == "list":
        return isinstance(v, list) and len(v) > 0 and all(isinstance(x, str) and x for x in v)
    if t.startswith("enum:"):
        return v in t[5:].split("|")
    if t.startswith("ref:"):
        return isinstance(v, str) and v != ""
    raise ValueError(f"unknown column type {t}")


def preflight(sheets):
    errors, unverified, unimplemented = [], [], []
    ids = {}
    for name, s in sheets.items():
        cols = s.get("columns", {})
        seen = set()
        for i, row in enumerate(s.get("rows", [])):
            rid = row.get("id", f"#{i}")
            if rid in seen:
                errors.append(f"{name}.{rid}: duplicate id")
            seen.add(rid)
            for c in row:
                if c not in cols:
                    errors.append(f"{name}.{rid}.{c}: column not declared")
            for c, spec in cols.items():
                if c not in row:
                    errors.append(f"{name}.{rid}.{c}: EMPTY (missing)")
                elif not check_type(spec["type"], row[c]):
                    errors.append(f"{name}.{rid}.{c}: bad value {row[c]!r} for type {spec['type']}")
            if row.get("verified") is False:
                unverified.append(f"{name}.{rid}")
            if row.get("implemented") is False:
                unimplemented.append(f"{name}.{rid} ({row.get('used_by', '')})")
        ids[name] = seen

    # references between sheets
    for name, s in sheets.items():
        for c, spec in s["columns"].items():
            if spec["type"].startswith("ref:"):
                target = spec["type"][4:]
                if target not in ids:
                    errors.append(f"{name}.{c}: refers to missing sheet {target}")
                    continue
                for row in s["rows"]:
                    if row.get(c) not in ids[target]:
                        errors.append(f"{name}.{row.get('id')}.{c}: '{row.get(c)}' not in {target}")

    # every mode needs its points_/effect_ columns in style_events
    ev_cols = sheets["style_events"]["columns"]
    for m in sheets["modes"]["rows"]:
        for pre in ("points_", "effect_"):
            if pre + m["id"] not in ev_cols:
                errors.append(f"style_events: no column {pre}{m['id']} for mode {m['id']}")

    # an effect replaces the points, so a row with an effect must give 0 points in that mode
    for row in sheets["style_events"]["rows"]:
        for m in sheets["modes"]["rows"]:
            if row.get("effect_" + m["id"]) != "none" and row.get("points_" + m["id"]) != 0:
                errors.append(f"style_events.{row['id']}: effect_{m['id']} is set, so points_{m['id']} must be 0")

    # settings.X / hooks.X / ranks.X named in free text must exist
    for name, s in sheets.items():
        for row in s["rows"]:
            for c, v in row.items():
                for ref_sheet, key in re.findall(r"\b(settings|hooks)\.([a-z_]+)", json.dumps(v)):
                    if key in FILE_EXTS:
                        continue  # a file name such as settings.cfg, not a row reference
                    if key not in ids[ref_sheet]:
                        errors.append(f"{name}.{row['id']}.{c}: mentions {ref_sheet}.{key}, which doesn't exist")

    # every row must be used by the code that implements it
    lua = LUA_MAIN.read_text(encoding="utf-8") if LUA_MAIN.exists() else ""
    cs = "".join(p.read_text(encoding="utf-8") for p in CS_DIR.glob("*.cs") if p.name != "Sheets.g.cs")
    for row in sheets["style_events"]["rows"]:
        if f'"{row["id"]}"' not in lua:
            errors.append(f"style_events.{row['id']}: main.lua never fires it")
    for row in sheets["hooks"]["rows"]:
        if row["implemented"] and f'"{row["id"]}"' not in lua:
            errors.append(f"hooks.{row['id']}: marked implemented but main.lua never uses it")
    for row in sheets["settings"]["rows"]:
        if f'"{row["id"]}"' not in lua and f'"{row["id"]}"' not in cs:
            errors.append(f"settings.{row['id']}: no code reads it")
    for row in sheets["hud"]["rows"]:
        if f'"{row["shows"]}"' not in lua:
            errors.append(f"hud.{row['id']}: main.lua never fills '{row['shows']}'")
    for row in sheets["audio"]["rows"]:
        used = any(row["id"] in json.dumps(s["rows"]) for n, s in sheets.items() if n != "audio")
        if not used and f'"{row["id"]}"' not in lua and f'"{row["id"]}"' not in cs:
            errors.append(f"audio.{row['id']}: nothing plays it")
    return errors, unverified, unimplemented


def lua_val(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, list):
        return "{" + ", ".join(lua_val(x) for x in v) + "}"
    return json.dumps(v, ensure_ascii=False)


def gen_lua(sheets):
    out = ["-- GENERATED by tools/gen.py from sheets/*.json. Do not edit; change the sheet.", "local S = {}"]
    for name, s in sheets.items():
        out.append(f"S.{name} = {{")
        for row in s["rows"]:
            fields = ", ".join(f"{k} = {lua_val(row[k])}" for k in s["columns"])
            out.append(f"  {{ {fields} }},")
        out.append("}")
        out.append(f"S.{name}_by_id = {{}}")
        out.append(f"for _, r in ipairs(S.{name}) do S.{name}_by_id[r.id] = r end")
    out.append("return S")
    LUA_OUT.write_text("\n".join(out) + "\n", encoding="utf-8")


def cs_type(t):
    return {"int": "int", "number": "double", "bool": "bool", "list": "string[]"}.get(t, "string")


def cs_val(t, v):
    if t == "bool":
        return "true" if v else "false"
    if t == "int":
        return str(v)
    if t == "number":
        return repr(float(v))
    if t == "list":
        return "new[] { " + ", ".join(json.dumps(x) for x in v) + " }"
    return json.dumps(str(v), ensure_ascii=False)


def gen_cs(sheets):
    want = ["audio", "music_tiers", "ranks", "modes", "settings"]
    out = ["// GENERATED by tools/gen.py from sheets/*.json. Do not edit; change the sheet.",
           "namespace UKAudio", "{", "    internal static class Sheets", "    {"]
    for name in want:
        s = sheets[name]
        cls = "".join(p.capitalize() for p in name.split("_")) + "Row"
        out.append(f"        internal sealed class {cls}")
        out.append("        {")
        for c, spec in s["columns"].items():
            out.append(f"            public {cs_type(spec['type'])} {c};")
        out.append("        }")
        prop = "".join(p.capitalize() for p in name.split("_"))
        out.append(f"        internal static readonly {cls}[] {prop} = new[]")
        out.append("        {")
        for row in s["rows"]:
            fields = ", ".join(f"{c} = {cs_val(spec['type'], row[c])}" for c, spec in s["columns"].items())
            out.append(f"            new {cls} {{ {fields} }},")
        out.append("        };")
    out += ["    }", "}"]
    CS_OUT.write_text("\n".join(out) + "\n", encoding="utf-8")


def main():
    sheets = load()
    errors, unverified, unimplemented = preflight(sheets)
    total = sum(len(s["rows"]) * len(s["columns"]) for s in sheets.values())
    print(f"preflight: {len(sheets)} sheets, {sum(len(s['rows']) for s in sheets.values())} rows, {total} cells")
    if unimplemented:
        print(f"\nNOT IMPLEMENTED in this build ({len(unimplemented)}):")
        for u in unimplemented:
            print("  -", u)
    if unverified:
        print(f"\nUNVERIFIED in the running game ({len(unverified)}) - the in-game test checklist:")
        for u in unverified:
            print("  -", u)
    if errors:
        print(f"\nBLOCKING ({len(errors)}):")
        for e in errors:
            print("  x", e)
        sys.exit(1)
    print("\npreflight: no blocking issues")
    if "--check" not in sys.argv:
        gen_lua(sheets)
        gen_cs(sheets)
        print(f"generated {LUA_OUT.relative_to(ROOT)} and {CS_OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
