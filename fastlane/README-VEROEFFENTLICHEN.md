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
cd ~/Desktop/framefold

# 1. Neue Versionsnummer setzen
fastlane bump version:1.0.2

# 2. Release-Notes schreiben
open fastlane/metadata/de-DE/release_notes.txt

# 3. Bauen, hochladen, Version anlegen, einreichen
fastlane release
```

Der letzte Befehl erhöht die Build-Nummer selbst, archiviert, lädt hoch,
wartet auf Apples Verarbeitung, hängt den Build an die Version, überträgt
die Release-Notes und reicht zur Prüfung ein.

Die **Veröffentlichung nach der Freigabe bleibt manuell** — so bestimmst du
selbst, wann eine Version live geht (wichtig, wenn PR und Launch
zusammenpassen sollen). Wer das automatisch will, setzt im `Fastfile`
`automatic_release: true`.

## Weitere Befehle

```
fastlane upload    # nur bauen und hochladen, ohne Einreichung (TestFlight)
fastlane status    # Zustand der letzten Versionen anzeigen
```

## Was fastlane nicht übernimmt

- **Bedienungshilfen-Angaben** — einmalig im Browser setzen, sie gelten
  danach für alle Folgeversionen
- **Screenshots** — ändern sich selten; bei Bedarf über
  `fastlane/screenshots` und `skip_screenshots: false` nachrüsten
- **Erstveröffentlichung einer neuen App** — dafür braucht es weiterhin
  einige Angaben im Browser; Updates laufen vollständig über fastlane

## Sicherheit

Der `.p8`-Schlüssel ist gleichwertig mit einem Passwort für deinen
Entwickler-Account. Er gehört nicht ins Repository, nicht in Backups mit
öffentlichem Zugriff und nicht in Chatverläufe. Geht er verloren oder wird
er kompromittiert: in App Store Connect widerrufen und neu erzeugen.
