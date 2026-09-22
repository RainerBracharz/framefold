#!/usr/bin/env python3
"""Trägt die englischen Fassungen in die String Catalogs ein.

    python3 scripts/apply_translations.py            # Probelauf, schreibt nichts
    python3 scripts/apply_translations.py --write    # trägt ein

Die Kataloge werden von Xcode beim Export mit den deutschen Quelltexten
gefüllt. Dieses Skript ergänzt je Eintrag die englische Fassung und meldet,
was ohne Übersetzung bleibt — das ist der eigentliche Zweck: Man sieht schwarz
auf weiß, welche Texte noch fehlen, statt sie erst in der halb englischen App
zu entdecken.

Drei Quellen:
  localization/en.json         einfache Zuordnung deutsch → englisch
  localization/en_plural.json  Texte mit Einzahl-/Mehrzahlform
  NEUTRAL (hier im Skript)     Texte, die in keiner Sprache anders lauten
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOGS = [
    ROOT / "FrameFold" / "Localizable.xcstrings",
    ROOT / "FrameFold Watch Watch App" / "Localizable.xcstrings",
]
WRITE = "--write" in sys.argv

# Bleiben in jeder Sprache gleich: Zahlen mit Einheit, Eigenname, reine
# Platzhalter. Werden als „nicht übersetzen" markiert, damit Xcode sie nicht
# als Lücke führt.
NEUTRAL = {
    "", "%lld", "FrameFold",
    "1 s", "2 s", "3 s",
    "2 fps", "3 fps", "4 fps", "6 fps", "8 fps", "10 fps", "12 fps",
}


def lade(name):
    p = ROOT / "localization" / name
    return {k: v for k, v in json.loads(p.read_text()).items()
            if not k.startswith("_")}


einfach = lade("en.json")
plural = lade("en_plural.json")

gesamt = dict(ergaenzt=0, schon=0, neutral=0, fehlt=[])
genutzt = set()

for catalog_path in CATALOGS:
    if not catalog_path.exists():
        print(f"übersprungen (fehlt): {catalog_path.relative_to(ROOT)}")
        continue

    catalog = json.loads(catalog_path.read_text())
    strings = catalog.setdefault("strings", {})
    if not strings:
        print(f"leer: {catalog_path.relative_to(ROOT)} — erst exportieren")
        continue

    for key, entry in strings.items():
        if key in NEUTRAL:
            if entry.get("shouldTranslate") is not False:
                entry["shouldTranslate"] = False
                gesamt["neutral"] += 1
            continue

        locs = entry.setdefault("localizations", {})
        if "en" in locs:
            gesamt["schon"] += 1
            genutzt.add(key)
            continue

        if key in plural:
            formen = plural[key]
            locs["en"] = {"variations": {"plural": {
                form: {"stringUnit": {"state": "translated", "value": wert}}
                for form, wert in formen.items()
            }}}
            gesamt["ergaenzt"] += 1
            genutzt.add(key)
        elif key in einfach:
            locs["en"] = {"stringUnit": {"state": "translated",
                                         "value": einfach[key]}}
            gesamt["ergaenzt"] += 1
            genutzt.add(key)
        else:
            gesamt["fehlt"].append(key)

    if WRITE:
        catalog_path.write_text(json.dumps(catalog, ensure_ascii=False,
                                           indent=2, sort_keys=True) + "\n")

print(f"englisch ergänzt:   {gesamt['ergaenzt']}")
print(f"war schon da:       {gesamt['schon']}")
print(f"neutral markiert:   {gesamt['neutral']}")
print(f"ohne Übersetzung:   {len(gesamt['fehlt'])}")

if gesamt["fehlt"]:
    print("\nOhne Übersetzung — gehören nach localization/en.json:")
    for k in sorted(gesamt["fehlt"]):
        print("   " + k.replace("\n", "\\n"))

ungenutzt = sorted((set(einfach) | set(plural)) - genutzt)
if ungenutzt:
    print("\nIn den Zuordnungen, aber in keinem Katalog "
          "(Tippfehler oder Text entfernt?):")
    for k in ungenutzt:
        print("   " + k.replace("\n", "\\n"))

print("\nGeschrieben." if WRITE else "\nProbelauf — nichts geschrieben. "
      "Mit --write eintragen.")
