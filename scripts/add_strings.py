#!/usr/bin/env python3
"""Neue Texte in FrameFold/Localizable.xcstrings eintragen oder den Katalog prüfen.

    python3 scripts/add_strings.py batch.json   # eintragen
    python3 scripts/add_strings.py --check      # Lücken und falsche Platzhalter melden

batch.json: {"deutscher Schlüssel": {"en": "…", "fr": "…", …}, …}
Bestehende Übersetzungen werden überschrieben, andere Sprachen bleiben.
Der Katalog ist die einzige Quelle der Übersetzungen.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "FrameFold" / "Localizable.xcstrings"
SPEC = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|\.?\d*f|lf|u|llu|s)")


def units(entry):
    if "stringUnit" in entry:
        yield entry["stringUnit"]
    for group in entry.get("variations", {}).values():
        for variant in group.values():
            yield from units(variant)
    for part in entry.get("substitutions", {}).values():
        yield from units(part)


def check(catalog):
    strings = catalog["strings"]
    langs = sorted({lang for e in strings.values() for lang in e.get("localizations", {})} - {catalog["sourceLanguage"]})
    problems = 0
    for key, entry in strings.items():
        if entry.get("shouldTranslate") is False:
            continue
        locs = entry.get("localizations", {})
        wanted = sorted(re.sub(r"\d\$", "", m) for m in SPEC.findall(key))
        for lang in langs:
            if lang not in locs:
                print(f"fehlt  {lang}: {key!r}")
                problems += 1
                continue
            plain = "stringUnit" in locs[lang]
            for unit in units(locs[lang]):
                if unit["state"] != "translated" or not unit["value"].strip():
                    print(f"offen  {lang}: {key!r}")
                    problems += 1
                elif plain and sorted(re.sub(r"\d\$", "", m) for m in SPEC.findall(unit["value"])) != wanted:
                    print(f"Platzhalter {lang}: {key!r} → {unit['value']!r}")
                    problems += 1
    print(f"{len(strings)} Texte, {len(langs)} Sprachen, {problems} Auffälligkeiten")
    return problems


catalog = json.loads(CATALOG.read_text())
if len(sys.argv) < 2:
    sys.exit(__doc__)
if sys.argv[1] == "--check":
    sys.exit(1 if check(catalog) else 0)
batch = json.loads(Path(sys.argv[1]).read_text())
for key, values in batch.items():
    locs = catalog["strings"].setdefault(key, {}).setdefault("localizations", {})
    for lang, text in values.items():
        locs[lang] = {"stringUnit": {"state": "translated", "value": text}}
CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
print(f"{len(batch)} Texte eingetragen")
