# Motion Control und Licht im FrameFold-Studio

## Motion Control (Bluetooth)

FrameFold steuert Kameraschlitten, Schwenkköpfe oder Drehteller über Bluetooth Low Energy.
Gesprochen wird ein einfaches Textprotokoll über den **Nordic UART Service**, den fast jedes ESP32- oder nRF-Board kann.

| | UUID |
|---|---|
| Dienst | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| RX (App → Gerät, schreiben) | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| TX (Gerät → App, Benachrichtigung) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |

Jede Zeile endet mit `\n`. Positionen sind ganze Motorschritte, absolut ab dem Nullpunkt.

| App sendet | Bedeutung | Gerät antwortet |
|---|---|---|
| `hi` | Hallo | `hi <Achsen>` (1–8) |
| `mm <Achse> <Position>` | Achse (ab 1) zur Position fahren | `ok <Achse>`, sobald sie steht |
| `zm` | aktuelle Position aller Achsen = 0 | – |
| `pr` | Positionen melden | `pr <p1> <p2> …` |
| | Fehler | `er <Text>` |

Im Studio: Gerät verbinden, Achsen mit den Tasten verfahren, „Position für Bild N merken“.
Zwischen den gemerkten Positionen rechnet FrameFold die Bahn (gleichförmig oder weich).
Mit „Vor dem Auslösen anfahren“ fährt die Anlage vor jedem Bild an ihre Position, wartet auf `ok`, lässt 0,3 s ausschwingen und löst dann aus.

### Beispiel-Firmware (ESP32, Arduino)

Ein Ausgangspunkt, nicht mehr: ein Schrittmotor an STEP/DIR, Bibliotheken *NimBLE-Arduino* und *AccelStepper*.
Mit echter Hardware ist das noch nicht erprobt.

```cpp
#include <NimBLEDevice.h>
#include <AccelStepper.h>

AccelStepper axis1(AccelStepper::DRIVER, 18, 19);   // STEP, DIR
NimBLECharacteristic* tx;
String line;
bool reported = true;

void send(const String& s) { tx->setValue(s + "\n"); tx->notify(); }

void handle(const String& cmd) {
  if (cmd.startsWith("hi")) send("hi 1");
  else if (cmd.startsWith("mm 1 ")) { axis1.moveTo(cmd.substring(5).toInt()); reported = false; }
  else if (cmd == "zm") axis1.setCurrentPosition(0);
  else if (cmd == "pr") send("pr " + String(axis1.currentPosition()));
}

class RX : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    for (char ch : c->getValue()) { if (ch == '\n') { handle(line); line = ""; } else line += ch; }
  }
};

void setup() {
  axis1.setMaxSpeed(800); axis1.setAcceleration(400);
  NimBLEDevice::init("FrameFold Rig");
  auto* server = NimBLEDevice::createServer();
  auto* svc = server->createService("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  svc->createCharacteristic("6E400002-B5A3-F393-E0A9-E50E24DCCA9E", NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR)
     ->setCallbacks(new RX());
  tx = svc->createCharacteristic("6E400003-B5A3-F393-E0A9-E50E24DCCA9E", NIMBLE_PROPERTY::NOTIFY);
  svc->start();
  NimBLEDevice::getAdvertising()->addServiceUUID(svc->getUUID());
  NimBLEDevice::getAdvertising()->start();
}

void loop() {
  axis1.run();
  if (!reported && axis1.distanceToGo() == 0) { send("ok 1"); reported = true; }
}
```

## Licht (DMX über Art-Net)

FrameFold schickt DMX-Werte als **Art-Net** (ArtDMX, Port 6454) an einen Art-Net-Knoten oder ein Lichtpult im lokalen Netz.
Im Studio: IP-Adresse des Knotens, Universum und Kanalzahl eintragen, die Regler für das nächste Bild stellen, „Ab diesem Bild speichern“.
Nach jeder Aufnahme stellt FrameFold das Licht für das folgende Bild, auf Wunsch mit Überblenden zwischen den Stimmungen.

## Datenschutz

Beides ist ausgeschaltet, bis man es im Studio einschaltet.
Art-Net geht nur ins lokale Netz (nie über Mobilfunk, nie ins Internet), Motion Control nur per Bluetooth zum gewählten Gerät.
Es werden keine Daten an den Entwickler oder Dritte übertragen.
