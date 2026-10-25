#!/usr/bin/env python3
"""Neue Texte in Localizable.xcstrings und localization/<lang>.json eintragen.

    python3 scripts/add_strings.py batch.json

batch.json: {"deutscher Schlüssel": {"en": "…", "fr": "…", …}, …}
Bestehende Übersetzungen werden überschrieben, andere Sprachen bleiben.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
batch = json.loads(Path(sys.argv[1]).read_text())
catalog_path = ROOT / "FrameFold" / "Localizable.xcstrings"
catalog = json.loads(catalog_path.read_text())
for key, values in batch.items():
    entry = catalog["strings"].setdefault(key, {})
    locs = entry.setdefault("localizations", {})
    for lang, text in values.items():
        locs[lang] = {"stringUnit": {"state": "translated", "value": text}}
        side = ROOT / "localization" / f"{lang}.json"
        if side.exists():
            table = json.loads(side.read_text())
            table[key] = text
            side.write_text(json.dumps(table, indent=2, ensure_ascii=False) + "\n")
catalog_path.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
print(f"{len(batch)} Texte eingetragen")
