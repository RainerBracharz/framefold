#!/usr/bin/env ruby
# frozen_string_literal: true
#
# FrameFold — Zahlenbericht aus App Store Connect.
#
#   ruby scripts/asc_report.rb            # Bericht auf die Konsole
#   ruby scripts/asc_report.rb --csv      # zusätzlich eine CSV-Zeile zum Mitschreiben
#
# Braucht:
#   ~/.appstoreconnect/AuthKey_<KEY_ID>.p8   — der API-Schlüssel (liegt bewusst
#                                              ausserhalb des Repositorys)
#   ~/.appstoreconnect/vendor                — die Vendor-Nummer, eine Zeile.
#                                              Steht in App Store Connect unter
#                                              „Zahlungen und Finanzberichte“.
#                                              Alternativ: ASC_VENDOR in der Umgebung.
#
# Keine Gems nötig — JWT wird mit OpenSSL signiert.

require "openssl"
require "base64"
require "json"
require "net/http"
require "uri"
require "zlib"
require "stringio"
require "date"

# Verkaufsberichte brauchen einen Schlüssel mit der Rolle „Finanzen“ oder
# „Verkauf und Berichte“. Der CI-Schlüssel ist App-Manager und reicht dafür
# nicht — Apple lässt Rollen nachträglich nicht erweitern, es braucht also
# einen zweiten Schlüssel. Seine ID kommt aus der Umgebung oder aus
# ~/.appstoreconnect/report_key_id; fehlt sie, wird der CI-Schlüssel versucht.
CI_KEY_ID = "RYCY6P77D7"
KEY_ID    = (ENV["ASC_REPORT_KEY_ID"] || begin
  p = File.expand_path("~/.appstoreconnect/report_key_id")
  File.exist?(p) ? File.read(p).strip : nil
end || CI_KEY_ID)
ISSUER_ID = "2035739a-efc7-450c-8f2f-61f211394113"
APP_ID    = "6801045603"
APP_NAME  = "FrameFold"
# Erster Tag im Store. Davor gibt es nichts zu holen.
LAUNCH    = Date.new(2026, 8, 19)

KEY_PATH  = File.expand_path("~/.appstoreconnect/AuthKey_#{KEY_ID}.p8")
VENDOR    = (ENV["ASC_VENDOR"] || begin
  p = File.expand_path("~/.appstoreconnect/vendor")
  File.exist?(p) ? File.read(p).strip : nil
end)

abort("Schlüssel fehlt: #{KEY_PATH}") unless File.exist?(KEY_PATH)
if VENDOR.nil? || VENDOR.empty?
  abort <<~TEXT
    Vendor-Nummer fehlt.

    Sie steht in App Store Connect unter „Zahlungen und Finanzberichte“,
    links oben neben dem Firmennamen (achtstellig, beginnt meist mit 8).

    Einmalig hinterlegen:
      echo 123456789 > ~/.appstoreconnect/vendor && chmod 600 ~/.appstoreconnect/vendor
  TEXT
end

# ── Anmeldung ────────────────────────────────────────────────────────────────

def b64(data) = Base64.urlsafe_encode64(data).delete("=")

# ES256 von Hand: Die DER-Signatur von OpenSSL muss für JWT in das rohe
# r‖s-Format umgeschrieben werden, sonst weist Apple den Token ab.
def token
  header  = { alg: "ES256", kid: KEY_ID, typ: "JWT" }
  now     = Time.now.to_i
  payload = { iss: ISSUER_ID, iat: now, exp: now + 1200, aud: "appstoreconnect-v1" }
  input   = "#{b64(JSON.dump(header))}.#{b64(JSON.dump(payload))}"

  key = OpenSSL::PKey::EC.new(File.read(KEY_PATH))
  der = key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(input))
  r, s = OpenSSL::ASN1.decode(der).value.map { |v| v.value.to_s(2).rjust(32, "\x00") }

  "#{input}.#{b64(r + s)}"
end

TOKEN = token

def get(path, params = {}, accept: "application/json")
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{TOKEN}"
  req["Accept"] = accept
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
  [res.code.to_i, res.body]
end

# ── Verkaufsberichte ─────────────────────────────────────────────────────────

# Ein Bericht pro Zeitraum. 404 heisst schlicht „an diesem Tag nichts verkauft“
# und ist kein Fehler.
def sales_rows(frequency:, report_date:)
  code, body = get("/v1/salesReports", {
    "filter[frequency]"     => frequency,
    "filter[reportDate]"    => report_date,
    "filter[reportSubType]" => "SUMMARY",
    "filter[reportType]"    => "SALES",
    "filter[vendorNumber]"  => VENDOR
  }, accept: "application/a-gzip")

  return [] if code == 404

  # Sofort abbrechen statt dreissigmal gegen dieselbe Wand zu laufen.
  if code == 401 || code == 403
    $stderr.puts
    abort <<~TEXT

      HTTP #{code} — der Schlüssel #{KEY_ID} darf keine Verkaufsberichte lesen.

      Verkaufsberichte brauchen die Rolle „Finanzen“ oder „Verkauf und Berichte“.
      Der CI-Schlüssel ist App-Manager, und Apple lässt Rollen nachträglich
      nicht erweitern. Also einen zweiten Schlüssel anlegen:

        App Store Connect → Benutzer und Zugriffsrechte → Integration
        → App Store Connect-API → Aktiv → „+“
        Name: FrameFold Reporting, Zugriff: Finanzen

      Die .p8-Datei wird nur einmal zum Download angeboten. Danach:

        mv ~/Downloads/AuthKey_<NEUE_ID>.p8 ~/.appstoreconnect/
        chmod 600 ~/.appstoreconnect/AuthKey_<NEUE_ID>.p8
        echo <NEUE_ID> > ~/.appstoreconnect/report_key_id
    TEXT
  end

  unless code == 200
    warn("  ! #{frequency} #{report_date}: HTTP #{code}")
    return []
  end

  tsv = Zlib::GzipReader.new(StringIO.new(body)).read
  lines = tsv.split("\n")
  return [] if lines.size < 2
  head = lines.shift.split("\t")
  lines.map { |l| head.zip(l.split("\t")).to_h }
       .select { |r| r["Apple Identifier"].to_s == APP_ID }
end

# Apples Produktcodes, vollständig aus der offiziellen Tabelle übernommen:
# developer.apple.com/help/app-store-connect/reference/reporting/product-type-identifiers
# Unbekannte Codes erscheinen als „Code X“ — lieber keine Beschriftung als
# eine falsche.
ARTEN = {
  "1"    => "Erstinstallation", "1F"   => "Erstinstallation",
  "1T"   => "Erstinstallation", "F1"   => "Erstinstallation",
  "1E"   => "Erstinstallation", "1EP"  => "Erstinstallation",
  "1EU"  => "Erstinstallation", "1-B"  => "Erstinstallation (Bundle)",
  "F1-B" => "Erstinstallation (Bundle)",
  "3"    => "Erneut geladen",   "3F"   => "Erneut geladen",
  "7"    => "Aktualisierung",   "7F"   => "Aktualisierung",
  "7T"   => "Aktualisierung",   "F7"   => "Aktualisierung",
  "IA1"  => "In-App-Kauf",      "IA1-M" => "In-App-Kauf",
  "FI1"  => "In-App-Kauf",      "IA3"  => "In-App-Kauf (wiederhergestellt)",
  "IA9"  => "Abo (nicht verlängernd)", "IA9-M" => "Abo (nicht verlängernd)",
  "IAY"  => "Abo (automatisch)", "IAY-M" => "Abo (automatisch)"
}.freeze

def summe(rows) = rows.sum { |r| r["Units"].to_i }

def gruppiert(rows, key)
  rows.each_with_object(Hash.new(0)) { |r, h| h[r[key].to_s] += r["Units"].to_i }
      .sort_by { |_, v| -v }
end

# ── Einsammeln ───────────────────────────────────────────────────────────────

heute = Date.today
$stderr.print "Hole Berichte"

# Tagesberichte werden zwischengespeichert: Der laufende Monat und das
# 30-Tage-Fenster überschneiden sich, jeder Tag soll aber nur einmal geholt
# und nur einmal gezählt werden.
tage = {}
hole_tag = lambda do |tag|
  tage[tag.iso8601] ||= begin
    $stderr.print "."
    sales_rows(frequency: "DAILY", report_date: tag.iso8601)
  end
end

# Abgeschlossene Monate als Monatsbericht — spart Abfragen. Den laufenden
# Monat gibt es als Monatsbericht noch nicht: Apple erstellt ihn erst nach
# Monatsende. Er muss deshalb tageweise dazu, sonst fehlt er in der
# Gesamtsumme und „letzte 30 Tage“ wäre grösser als „gesamt“.
alle = []
monatsanfang = Date.new(heute.year, heute.month, 1)
monat = Date.new(LAUNCH.year, LAUNCH.month, 1)
while monat < monatsanfang
  alle.concat(sales_rows(frequency: "MONTHLY", report_date: monat.strftime("%Y-%m")))
  $stderr.print "."
  monat = monat.next_month
end
(monatsanfang..heute).each { |t| alle.concat(hole_tag.call(t)) if t >= LAUNCH }

letzte30 = []
letzte7  = []
(0..29).each do |back|
  tag = heute - back
  next if tag < LAUNCH
  rows = hole_tag.call(tag)
  letzte30.concat(rows)
  letzte7.concat(rows) if back < 7
end
$stderr.puts

# Versionen
versionen = begin
  code, body = get("/v1/apps/#{APP_ID}/appStoreVersions", { "limit" => 5 })
  code == 200 ? JSON.parse(body)["data"] : []
rescue StandardError
  []
end

# ── Ausgabe ──────────────────────────────────────────────────────────────────

def zeile(label, wert, breite = 26)
  puts "  #{label.ljust(breite)}#{wert.to_s.rjust(6)}"
end

puts
puts "#{APP_NAME} · Bericht vom #{heute.strftime('%d.%m.%Y')}"
puts "─" * 46
puts
puts "DOWNLOADS"
zeile "Gesamt seit #{LAUNCH.strftime('%d.%m.%Y')}", summe(alle)
zeile "Letzte 30 Tage", summe(letzte30)
zeile "Letzte 7 Tage",  summe(letzte7)

unless alle.empty?
  puts
  puts "NACH ART"
  gruppiert(alle, "Product Type Identifier").each do |code, n|
    zeile(ARTEN[code] || "Code #{code}", n)
  end

  puts
  puts "NACH LAND"
  gruppiert(alle, "Country Code").first(10).each { |land, n| zeile(land, n) }

  versionsspalte = alle.first.key?("Version") ? "Version" : nil
  if versionsspalte
    puts
    puts "NACH VERSION"
    gruppiert(alle, versionsspalte).each { |v, n| zeile(v.empty? ? "—" : v, n) }
  end
end

unless versionen.empty?
  puts
  puts "IM STORE"
  versionen.each do |v|
    a = v["attributes"]
    zeile(a["versionString"], a["appStoreState"], 26)
  end
end

puts
if ARGV.include?("--csv")
  # Eine Zeile zum Anhängen an eine eigene Tabelle – so sieht man den Verlauf.
  puts [heute.iso8601, summe(alle), summe(letzte30), summe(letzte7)].join(",")
end
