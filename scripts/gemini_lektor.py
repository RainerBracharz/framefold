#!/usr/bin/env python3
"""Gemini als Lektor für die FrameFold-Texte (Auftrag Rainer, 03.11.2026).

Gemini liefert nur Vorschläge. Claude prüft jeden gegen Funktionen und Regeln, Rainer gibt frei,
erst dann wird etwas eingesetzt. Ergebnisse landen in lektorat/ (nicht im Repo).

    python3 scripts/gemini_lektor.py app      # alle deutschen App-Texte prüfen → lektorat/app-*.json
    python3 scripts/gemini_lektor.py store    # Store-Texte iOS und Mac neu schreiben → lektorat/store.json

Schlüssel: ~/bracharz-seo/.gemini-key, nur im Header, nie in URLs oder Logs.
"""
import json, os, pathlib, re, sys, time

import requests

REPO = pathlib.Path(__file__).resolve().parent.parent
AUS = REPO / "lektorat"
SCHLUESSEL = pathlib.Path.home() / "bracharz-seo" / ".gemini-key"
MODELL = os.environ.get("GEMINI_MODELL", "gemini-pro-latest")
KATALOGE = ["FrameFold/Localizable.xcstrings", "FrameFold/InfoPlist.xcstrings",
            "FrameFold Watch Watch App/Localizable.xcstrings"]
STAPEL = 150

REGELN = """
Rainers Textregeln (gelten ohne Ausnahme):
- Keine Gedankenstriche (– oder —) als Satzzeichen. Ersatz: Beistrich, Punkt, Doppelpunkt nur für Aufzählungen, oder neuer Satz. Wortbindestriche (Stop-Motion-Kamera) sind richtig.
- Keine Kontrastformeln („nicht X, sondern Y“, „statt X einfach Y“), keine Doppelpunkt-Pointen („Das Ergebnis: …“), keine Dreierlisten nach dem Muster „Titel: Erklärung“.
- Keine Floskeln und Superlative: „nahtlos“, „Hebel“, „ganzheitlich“, „mühelos“, „magisch“, „perfekt“, „das beste“, „revolutionär“, „kinderleicht“, „im Handumdrehen“. Keine Rufzeichen.
- Kurze, direkte Sätze. Fakten statt Wertung.
- Datenschutz nur als Fakt (erhebt keine Daten, kein Konto, alles bleibt auf dem Gerät), keine Rechtsversprechen („DSGVO-konform“, „rechtssicher“).
- Keine Versionszählerei („Neu in 2.7“) und kein „behoben“.
- FrameFold ist kostenlos. Nie von Kauf, Preis oder Abo-Stufen sprechen, außer um zu sagen, dass es keine gibt.
- Nie „Open Source“ oder „frei lizenziert“: Der Code ist nur einsehbar.
- Keine Funktion erfinden. Keine KI-Funktion behaupten, die nicht in der Funktionsliste steht.
"""

BRIEF_APP = """Du bist Lektor für die deutschen Texte der App FrameFold, einer kostenlosen Stop-Motion-App für iPhone, iPad, Mac und Apple Watch.
Du bekommst die Texte der Oberfläche als nummerierte Liste [kennung] text, dahinter in Klammern die Swift-Datei, in der der Text vorkommt (Hinweis auf den Ort: Knopf, Hinweis, Hilfe).
Die App spricht die Nutzer mit „du“ an. Viele Texte sind Knopf- oder Menübeschriftungen und müssen kurz bleiben.

Finde Stellen, die besser werden müssen, und schlage für jede einen Ersatz vor. Weniger, aber treffende Befunde. Was gut ist, bleibt. Nichts gefunden: leere Liste.
- `kennung` ist die Kennung aus der Liste, unverändert.
- `vorschlag` ist der VOLLSTÄNDIGE neue Text für diese Kennung.
- Platzhalter wie %@, %lld, %.1f, %%, %1$@ müssen im Vorschlag genau so oft und in derselben Reihenfolge vorkommen.
- Steht ein anderer Oberflächentext in „…“ (etwa „Erweitert“, „Fertig“), ist das ein Verweis auf einen Knopf. Nicht umbenennen, außer du schlägst den Knopf ebenfalls um und nennst das in der Begründung.
- Einheitliche Begriffe: Melde mit art `begriff`, wenn dieselbe Sache verschieden heißt (z. B. Stopmotion / Stop-Motion, Werk / Projekt, Bild / Frame).
- Knopf-Beschriftungen nicht länger machen.

Arten (`art`): gedankenstrich, ki_merkmal, ton, unklar, tippfehler, begriff, zu_lang, falsch_ansprache.
""" + REGELN

SCHEMA_APP = {
    "type": "object",
    "properties": {"befunde": {"type": "array", "items": {
        "type": "object",
        "properties": {
            "kennung": {"type": "string"},
            "art": {"type": "string", "enum": ["gedankenstrich", "ki_merkmal", "ton", "unklar", "tippfehler",
                                               "begriff", "zu_lang", "falsch_ansprache"]},
            "vorschlag": {"type": "string"},
            "begruendung": {"type": "string"},
            "sicherheit": {"type": "string", "enum": ["hoch", "mittel", "niedrig"]},
        },
        "required": ["kennung", "art", "vorschlag", "begruendung", "sicherheit"],
    }}},
    "required": ["befunde"],
}

BRIEF_STORE = """Du schreibst die deutschen App-Store-Texte der App FrameFold neu, einmal für iPhone/iPad (iOS) und einmal für den Mac.
Du bekommst die heutigen Texte und eine Funktionsliste. Die Funktionsliste ist die EINZIGE Quelle für Funktionen. Was nicht drinsteht, kommt nicht vor.
Ziel: Menschen, die im App Store nach Stop-Motion suchen (Familien, Schulen, Trickfilm-Hobby, Künstler), verstehen in den ersten zwei Zeilen, was FrameFold anders macht: Es löst selbst aus, sobald die Hände aus dem Bild sind. Und es ist komplett kostenlos, ohne Wasserzeichen, ohne Konto.

Längen (Zeichen, hart): Name höchstens 30, Untertitel höchstens 30, Werbetext höchstens 170, Beschreibung höchstens 4000, Keywords höchstens 100 (durch Beistrich getrennt, ohne Leerzeichen, keine Wörter, die schon im Namen oder Untertitel stehen, keine Mehrzahl zusätzlich zur Einzahl).
Ansprache: „du“. Abschnitte der Beschreibung dürfen Überschriften in GROSSBUCHSTABEN haben, darunter Fließtext in kurzen Sätzen, keine Aufzählung „Titel: Erklärung“.
Die Mac-Fassung beschreibt den Mac (Dokumentenkamera oder iPhone als Kamera, Studio mit Tastatur, ProRes). Die iOS-Fassung beschreibt iPhone und iPad (Stativ, Apple Watch, Lautstärketasten, Klatschen).
Liefere zum Untertitel zwei Alternativen und begründe jede Entscheidung kurz.
""" + REGELN

FELD = {"type": "string"}
SCHEMA_STORE = {
    "type": "object",
    "properties": {p: {"type": "object", "properties": {
        "name": FELD, "untertitel": FELD, "untertitel_alternativen": {"type": "array", "items": FELD},
        "werbetext": FELD, "keywords": FELD, "beschreibung": FELD, "begruendung": FELD},
        "required": ["name", "untertitel", "untertitel_alternativen", "werbetext", "keywords", "beschreibung", "begruendung"]}
        for p in ("ios", "mac")},
    "required": ["ios", "mac"],
}


def gemini(brief, text, schema):
    k = SCHLUESSEL.read_text().strip()
    body = {
        "systemInstruction": {"parts": [{"text": brief}]},
        "contents": [{"role": "user", "parts": [{"text": text}]}],
        "generationConfig": {"responseMimeType": "application/json", "responseSchema": schema, "temperature": 0.3},
    }
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{MODELL}:generateContent"
    for versuch in range(4):
        r = requests.post(url, headers={"x-goog-api-key": k}, json=body, timeout=600)
        if r.status_code in (429, 500, 503) and versuch < 3:
            time.sleep(20 * (versuch + 1))
            continue
        if r.status_code != 200:
            sys.exit(f"Gemini HTTP {r.status_code}: {r.text[:300]}")
        d = r.json()
        return json.loads(d["candidates"][0]["content"]["parts"][0]["text"]), d.get("usageMetadata", {}), d.get("modelVersion")


def protokoll(was, nutzung, version):
    with open(AUS / "lauf.log", "a", encoding="utf-8") as log:
        log.write(f"{time.strftime('%Y-%m-%d %H:%M')} {was} {version} ein={nutzung.get('promptTokenCount')} "
                  f"aus={nutzung.get('candidatesTokenCount')} denk={nutzung.get('thoughtsTokenCount')}\n")


def app_texte():
    """[(kennung, katalog, schlüssel, deutscher text)] aus allen Katalogen."""
    swift = {p: p.read_text(encoding="utf-8") for p in REPO.glob("FrameFold*/**/*.swift")}
    aus = []
    for kat in KATALOGE:
        d = json.loads((REPO / kat).read_text(encoding="utf-8"))
        for schl, v in d["strings"].items():
            if v.get("shouldTranslate") is False or not re.search(r"[A-Za-zÄÖÜäöüß]{2}", schl):
                continue
            de = v.get("localizations", {}).get("de", {}).get("stringUnit", {}).get("value", schl)
            muster = re.sub(r"%(\d\$)?(lld|@|\.\d?f|d)", "\0", schl).split("\0")[0][:40]
            orte = sorted({p.name for p, t in swift.items() if muster and muster in t})[:3]
            aus.append((f"t{len(aus) + 1}", kat, schl, de, orte))
    return aus


def app():
    texte = app_texte()
    (AUS / "app-texte.json").write_text(json.dumps(
        [{"kennung": k, "katalog": kat, "schluessel": s, "text": t, "orte": o} for k, kat, s, t, o in texte],
        ensure_ascii=False, indent=1), encoding="utf-8")
    nach = {k: t for k, _, _, t, _ in texte}
    for n in range(0, len(texte), STAPEL):
        teil = texte[n:n + STAPEL]
        ziel = AUS / f"app-{n // STAPEL + 1}.json"
        if ziel.exists():
            continue
        liste = "\n".join(f"[{k}] {t}" + (f"   ({', '.join(o)})" if o else "") for k, _, _, t, o in teil)
        erg, nutzung, version = gemini(BRIEF_APP, f"Heute ist der {time.strftime('%d.%m.%Y')}.\n\n{liste}", SCHEMA_APP)
        for f in erg["befunde"]:
            f["alt"] = nach.get(f["kennung"])
        ziel.write_text(json.dumps({"modell": version, "nutzung": nutzung, "befunde": erg["befunde"]},
                                   ensure_ascii=False, indent=1), encoding="utf-8")
        protokoll(ziel.name, nutzung, version)
        print(f"{ziel.name}: {len(erg['befunde'])} Befunde")


def store():
    m = REPO / "fastlane"
    lies = lambda p: p.read_text(encoding="utf-8").strip() if p.exists() else ""
    heute = []
    for plattform, ordner in (("iOS", "metadata"), ("Mac", "metadata-mac")):
        d = m / ordner / "de-DE"
        heute.append(f"## Heutige Texte {plattform}\nName: {lies(d / 'name.txt') or lies(m / 'metadata/de-DE/name.txt')}\n"
                     f"Untertitel: {lies(d / 'subtitle.txt') or lies(m / 'metadata/de-DE/subtitle.txt')}\n"
                     f"Werbetext: {lies(d / 'promotional_text.txt')}\nKeywords: {lies(d / 'keywords.txt')}\n"
                     f"Beschreibung:\n{lies(d / 'description.txt')}")
    fakten = (REPO / "lektorat" / "funktionen.md").read_text(encoding="utf-8")
    text = f"Heute ist der {time.strftime('%d.%m.%Y')}.\n\n# Funktionsliste\n{fakten}\n\n" + "\n\n".join(heute)
    erg, nutzung, version = gemini(BRIEF_STORE, text, SCHEMA_STORE)
    (AUS / "store.json").write_text(json.dumps({"modell": version, "nutzung": nutzung, **erg},
                                               ensure_ascii=False, indent=1), encoding="utf-8")
    protokoll("store", nutzung, version)
    for p in ("ios", "mac"):
        e = erg[p]
        print(p, {f: len(e[f]) for f in ("name", "untertitel", "werbetext", "keywords", "beschreibung")})


SPRACHEN = {"cs": "cs", "da": "da", "en-US": "en", "es-ES": "es", "fr-FR": "fr", "it": "it", "ja": "ja", "ko": "ko",
            "nl-NL": "nl", "pl": "pl", "pt-BR": "pt-BR", "ru": "ru", "sv": "sv", "tr": "tr", "uk": "uk", "zh-Hans": "zh-Hans"}
BEGRIFFE = ["Einfach", "Erweitert", "Atelier", "Werk", "Werke", "Zwiebelhaut", "Fröhlich", "Traum", "Plopp", "Tadaa",
            "Stop-Motion exportieren", "Auto-Auslöser", "X-Sheet"]

BRIEF_UEBERSETZEN = """Du übersetzt die deutschen App-Store-Texte der kostenlosen Stop-Motion-App FrameFold in eine andere Sprache.
Inhalt in allen Sprachen gleich: nichts weglassen, nichts dazuerfinden, gleiche Abschnitte, gleiche Reihenfolge, Absätze und Zeilenumbrüche wie im Original.
Schreib so, wie Muttersprachler einen guten App-Store-Text schreiben: natürlich, kurz, direkt, informelle Anrede, wo sie in dieser Sprache für Apps üblich ist.
Begriffe aus der App (Modusnamen, Musikstücke, Geräusche) übernimmst du genau so, wie sie in der Begriffsliste in dieser Sprache stehen.
Keywords: Nimm die bisherigen Keywords dieser Sprache als Grundlage. Ersetze das Wort für „Zeitraffer“ durch das gängige Suchwort für „automatisch“. Streiche Wörter, die schon in Name oder neuem Untertitel stehen. Höchstens 100 Zeichen, durch Beistrich getrennt.
Längen hart: Untertitel höchstens 30 Zeichen, Werbetext höchstens 170, Beschreibung höchstens 4000.
""" + REGELN

SCHEMA_UEBERSETZEN = {"type": "object", "properties": {f: FELD for f in (
    "untertitel", "werbetext_ios", "werbetext_mac", "keywords", "beschreibung_ios", "beschreibung_mac")},
    "required": ["untertitel", "werbetext_ios", "werbetext_mac", "keywords", "beschreibung_ios", "beschreibung_mac"]}


def uebersetzen():
    from concurrent.futures import ThreadPoolExecutor
    m, de = REPO / "fastlane", REPO / "fastlane/metadata/de-DE"
    lies = lambda p: p.read_text(encoding="utf-8").strip() if p.exists() else ""
    kat = json.loads((REPO / "FrameFold/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]
    quelle = (f"Untertitel: {lies(de / 'subtitle.txt')}\n\nWerbetext iOS: {lies(de / 'promotional_text.txt')}\n\n"
              f"Werbetext Mac: {lies(m / 'metadata-mac/de-DE/promotional_text.txt')}\n\n"
              f"Keywords (Deutsch, nur zur Orientierung): {lies(de / 'keywords.txt')}\n\n"
              f"# Beschreibung iOS\n{lies(de / 'description.txt')}\n\n# Beschreibung Mac\n{lies(m / 'metadata-mac/de-DE/description.txt')}")

    def eine(ordner):
        ziel = AUS / "uebersetzung" / f"{ordner}.json"
        if ziel.exists():
            return
        sp, d = SPRACHEN[ordner], m / "metadata" / ordner
        begriffe = "\n".join(f"{b} = {kat.get(b, {}).get('localizations', {}).get(sp, {}).get('stringUnit', {}).get('value', '?')}"
                             for b in BEGRIFFE)
        text = (f"Zielsprache: {ordner}\n\n# Begriffsliste (Deutsch = {ordner})\n{begriffe}\n\n"
                f"# Bisher in dieser Sprache\nName: {lies(d / 'name.txt')}\nUntertitel alt: {lies(d / 'subtitle.txt')}\n"
                f"Keywords alt: {lies(d / 'keywords.txt')}\n\n# Deutsches Original\n{quelle}")
        erg, nutzung, version = gemini(BRIEF_UEBERSETZEN, text, SCHEMA_UEBERSETZEN)
        ziel.write_text(json.dumps(erg, ensure_ascii=False, indent=1), encoding="utf-8")
        protokoll(f"uebersetzen {ordner}", nutzung, version)
        print(ordner, {k: len(v) for k, v in erg.items()})

    (AUS / "uebersetzung").mkdir(exist_ok=True)
    with ThreadPoolExecutor(4) as pool:
        list(pool.map(eine, SPRACHEN))


if __name__ == "__main__":
    AUS.mkdir(exist_ok=True)
    {"app": app, "store": store, "uebersetzen": uebersetzen}.get(
        sys.argv[1] if sys.argv[1:] else "", lambda: sys.exit(__doc__))()
