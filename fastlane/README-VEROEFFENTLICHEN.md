# Veröffentlichen ohne Browser

Einmalig eingerichtet, danach ist jedes Update ein Befehl.

## Voraussetzungen (schon erledigt)

- API-Schlüssel liegt unter `~/.appstoreconnect/AuthKey_RYCY6P77D7.p8`
- Key-ID und Issuer-ID stehen im `Fastfile`
- Der Schlüssel ist über `.gitignore` vom Repository ausgeschlossen

Noch zu tun, falls fastlane fehlt:

```
brew install fastlane
```

## Ein Update veröffentlichen

```
cd ~/Desktop/05_Projekte/framefold

# 1. Neue Versionsnummer setzen
fastlane bump version:2.11

# 2. Release-Notes schreiben
open fastlane/metadata/de-DE/release_notes.txt

# 3. Bauen, hochladen, Version anlegen, einreichen
fastlane release
```

Der letzte Befehl erhöht die Build-Nummer selbst, archiviert, lädt hoch,
wartet auf Apples Verarbeitung, hängt den Build an die Version, überträgt
Texte und Screenshots und reicht zur Prüfung ein.

Nach Apples Freigabe geht die Version **von selbst in den Store**
(`automatic_release: true` im `Fastfile`). Wer den Zeitpunkt selbst bestimmen
will, setzt dort `automatic_release: false`.

Wartet noch eine andere Version auf die Prüfung, bricht `fastlane release`
ab. `fastlane resubmit` zieht die wartende Einreichung zurück und reicht die
aktuelle Version ein.

## Mac-Fassung

```
fastlane mac_release   # bauen, hochladen, Texte + Screenshots, einreichen
fastlane mac_upload    # nur bauen und hochladen (TestFlight)
fastlane mac_metadata  # nur Texte und Screenshots
fastlane mac_submit    # jüngsten gültigen Mac-Build einreichen
```

Texte liegen in `fastlane/metadata-mac`, Screenshots in
`fastlane/screenshots-mac`.

## Weitere Befehle

```
fastlane upload     # nur bauen und hochladen, ohne Einreichung (TestFlight)
fastlane submit     # neuesten Build der aktuellen Version einreichen
fastlane metadata   # nur Texte hochladen
fastlane status     # Zustand der letzten Versionen je Plattform
fastlane shots      # welche Screenshots je Gerätetyp im Store liegen
fastlane check      # Prüfbericht nach fastlane/bericht.txt
fastlane creative_assets step:probe   # Creative Assets: probe | upload | submit | place
```

## Screenshots und Vorschauvideos

- Screenshots liegen in `fastlane/screenshots/<Sprache>` und gehen bei jedem
  `fastlane release` mit. Neue Bilder ersetzen die alten nur mit
  `fastlane release overwrite_shots:true`.
- Vorschauvideos (`fastlane/previews`) und Duo-Screenshots
  (`fastlane/screenshots-duo`) lädt `fastlane release` über
  `scripts/app_preview.rb` und `scripts/duo_screenshots.rb`, sobald Dateien
  dort liegen.

## Was fastlane nicht übernimmt

- **Bedienungshilfen-Angaben**: einmalig im Browser setzen, sie gelten
  danach für alle Folgeversionen
- **Erstveröffentlichung einer neuen App**: dafür braucht es weiterhin
  einige Angaben im Browser; Updates laufen vollständig über fastlane

## Sicherheit

Der `.p8`-Schlüssel ist gleichwertig mit einem Passwort für deinen
Entwickler-Account. Er gehört nicht ins Repository, nicht in Backups mit
öffentlichem Zugriff und nicht in Chatverläufe. Geht er verloren oder wird
er kompromittiert: in App Store Connect widerrufen und neu erzeugen.
