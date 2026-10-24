# FrameFold Studio (Mac)

Die Profi-Arbeitsfläche der Mac-Fassung. Sie erscheint in der Kamera, sobald der Modus **Erweitert** oder **Atelier** eingestellt ist.
Im Modus **Einfach** bleibt es beim schlichten Sucher.

Die Arbeitsfläche besteht aus vier Teilen:

- **Betrachter** in der Mitte
- **Transportleiste** darunter
- **Zeitleiste** mit allen Bildern des Werks
- **Inspektor** rechts

Der automatische Auslöser (Hände weg, Szene ruhig) läuft wie gewohnt weiter und lässt sich im Inspektor abschalten.

## Betrachter

- **Live oder Aufnahme**: Der Betrachter zeigt das Kamerabild oder ein aufgenommenes Bild.
  Oben links steht, was gerade zu sehen ist, zum Beispiel „LIVE · BILD 25“ oder „BILD 12 / 24“.
- **Zwiebelhaut über bis zu sechs Bilder**: Das jüngste Bild ist am deutlichsten zu sehen.
- **Differenz**: Live-Bild minus letztes Bild.
  Wo nichts verrutscht ist, bleibt es schwarz. Damit lässt sich ein angestoßenes Set wieder genau ausrichten.
- **Belichtung**: Ausgefressene Lichter erscheinen rot, abgesoffene Schatten blau.
- **Formatmasken**: 2,39:1, 1,85:1, 16:9, 4:3, 1:1 und 9:16, mit einstellbarer Deckkraft.
- **Sicherheitsrahmen**: Aktionsbereich 93 % und Titelbereich 90 %.
- **Raster**: frei wählbar, bis 12 × 12.
- **Referenzebene**: ein Bild oder ein Film mit Deckkraft, Größe, Versatz und Chroma-Key (Grün oder Blau).
  Ein Film läuft Bild für Bild mit: Bild n zeigt die Stelle n ÷ Bildrate.
- **Notizen**: Eine Notiz zu Bild n erscheint, wenn genau dieses Bild als Nächstes aufgenommen wird.

## Zeitleiste

- Ein Klick zeigt das Bild, die Kachel „LIVE“ führt zurück zum Kamerabild.
- Ziehen ordnet Bilder um.
- Das Kontextmenü bietet Verdoppeln, Notiz, Schleifenanfang und -ende sowie Entfernen.
  Entfernte Bilder liegen 30 Tage im Papierkorb des Werks.
- Eine Linie unter den Kacheln markiert die Schleife.

## Aufnahme

- **Automatik (Hände weg)**: Lässt sich abschalten. Dann lösen nur noch Taste, Apple Watch, Fernbedienung oder Zeitraffer aus.
- **Mitteln**: Nach dem Auslösen werden 2 bis 16 Kamerabilder gemittelt. Das senkt das Rauschen bei wenig Licht.
- **Beim Auslösen abdunkeln**: Der Bildschirm wird kurz schwarz, damit sein Licht nicht aufs Set fällt.
- **Testaufnahme**: Ein Bild, das nicht ins Werk geht. Es dient nur zum Prüfen von Licht und Bildausschnitt.
- **Zeitraffer**: Intervall von 1 Sekunde bis 1 Stunde. Optional mit Startzeit, Endzeit und Höchstzahl an Bildern.

## Ton und Dialog

- **Tonspuren**: Im Inspektor unter „Ton“ fügt „Tonspur hinzufügen …“ beliebig viele Spuren hinzu.
  Jede Spur hat ein Einsatzbild („Ab Bild“), eine Lautstärke und einen Stummschalter.
  Die Musik aus der Werkansicht erscheint hier als erste Spur.
- **Wellenform**: Der Pegel aller Spuren liegt unter den Kacheln der Zeitleiste, Bild für Bild.
- **Abspielen mit Ton**: Abspielen und Kurz abspielen laufen synchron mit dem Ton.
  Beim Blättern mit ← und → erklingt der Ton genau dieses Bilds („Ton beim Blättern“).
- **X-Sheet** (⇧X): Das Belichtungsblatt hat eine Zeile je Bild, mit Tonpegel, Mundform und Wort je Figur sowie Notiz.
  Figuren legt man mit „Figur hinzufügen …“ an.
  Eine Mundform gilt so lange, bis eine neue eingetragen ist.
- **Mundformen** nach Preston Blair: AI, E, O, U, etc, FV, L, MBP, WQ, Ruhe.
  Im Betrachter zeigt eine Anzeige für jede Figur die Mundform des gezeigten Bilds.
- **Wörter erkennen**: Spur, Figur und Sprache wählen. FrameFold erkennt die gesprochenen Wörter, legt sie auf die Bilder und schlägt Mundformen vor.
  Die Erkennung läuft nur auf dem Gerät. Ist sie für eine Sprache ohne Netz nicht verfügbar, bricht FrameFold ab, statt Ton zu verschicken.
  Die Vorschläge sind ein Anfang, korrigiert wird im X-Sheet.
- **Export**: Alle hörbaren Spuren werden zum Film gemischt.

## Export

Den Export gibt es in der Werkansicht ab dem Modus Erweitert.

- **Codec**: HEVC oder H.264 als MP4, ProRes 422 oder ProRes 422 HQ als QuickTime für den Schnitt.
- **Bildsequenz**: PNG, TIFF oder JPEG in voller Auflösung, nummeriert als „Werk_0001.png“ und so weiter.
  JPEG wird verlustfrei kopiert.
- **Bilder im Finder zeigen**: im Inspektor unter „Werk“.

## Tasten

Alle Befehle stehen auch im Menü **Studio**.
Sie sind nur aktiv, solange die Arbeitsfläche offen ist, damit einfache Tasten keine Textfelder stören.

| Taste | Befehl |
|---|---|
| Leertaste oder ⏎ | Auslösen |
| ⌥⇧T | Testaufnahme |
| ← / → | Bild zurück / vor |
| L | Live-Bild |
| P | Abspielen / Stopp (in der Schleife, falls gesetzt) |
| K | Kurz abspielen (die letzten 12 Bilder, einstellbar) |
| T | Umschalten zwischen Live-Bild und letzter Aufnahme |
| ⇧T | Auto-Umschalten |
| I / O | Schleifenanfang / -ende |
| X | Schleife aufheben |
| D | Bild verdoppeln |
| ⌫ | Bild entfernen |
| N | Notiz |
| ⇧X | X-Sheet |
| [ / ] | Weniger / mehr Zwiebelhaut |
| M | Ansicht wechseln (Normal, Differenz, Belichtung) |
| ⌘⏎ | Fertig |
| ⌘⌫ | Letztes Bild zurücknehmen |
| Bild ab / Bild auf | Auslösen / zurücknehmen (Präsentations-Fernbedienung) |
