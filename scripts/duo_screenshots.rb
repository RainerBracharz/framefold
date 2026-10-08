#!/usr/bin/env ruby
# frozen_string_literal: true
#
# FrameFold — Screenshots für das iPhone Duo in den App Store laden.
#
#   ruby scripts/duo_screenshots.rb status   # Duo-Screenshots je Sprache zeigen
#   ruby scripts/duo_screenshots.rb upload   # an die bearbeitbare Version hängen
#
# Bilder: fastlane/screenshots-duo/{innen,aussen}/<locale>/duo-*.png
#   innen   2853 × 2007 (aufgeklappt, Querformat)
#   aussen  1398 × 2034 (zugeklappt, Hochformat; duo-aussen-4 ist der Film auf dem
#           Außendisplay bei aufgeklapptem Gerät)
# Erzeugt mit dem UI-Test `testWalkthrough` im Duo-Simulator (Xcode 27.1).
#
# fastlane deliver kennt den Gerätetyp APP_IPHONE_DUO noch nicht – deshalb
# dieser Weg über die API, wie bei scripts/app_preview.rb. Apple nimmt
# Screenshots nur an einer Version an, die noch bearbeitbar ist; sonst bricht
# das Skript mit einem Hinweis ab und ändert nichts.

require "digest"
require "openssl"
require "base64"
require "json"
require "net/http"
require "uri"

KEY_ID    = "RYCY6P77D7"
ISSUER_ID = "2035739a-efc7-450c-8f2f-61f211394113"
APP_ID    = "6801045603"
KEY_PATH  = File.expand_path("~/.appstoreconnect/AuthKey_#{KEY_ID}.p8")
abort("Schlüssel fehlt: #{KEY_PATH}") unless File.exist?(KEY_PATH)

ROOT        = File.expand_path("..", __dir__)
LOCALES     = %w[de-DE en-US fr-FR].freeze
EDITABLE    = %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED INVALID_BINARY].freeze

def b64(data) = Base64.urlsafe_encode64(data).delete("=")

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

def api(method, path, body = nil)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req["Authorization"] = "Bearer #{token}"
  req["Content-Type"] = "application/json"
  req.body = JSON.dump(body) if body
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  data = res.body.to_s.empty? ? {} : JSON.parse(res.body)
  unless res.code.to_i.between?(200, 299)
    errs = (data["errors"] || []).map { |e| "#{e['status']} #{e['code']}: #{e['detail']}" }
    abort "API-Fehler #{res.code} bei #{method.upcase} #{path}\n  " + errs.join("\n  ")
  end
  data
end

def versions
  api(:get, "/v1/apps/#{APP_ID}/appStoreVersions?filter[platform]=IOS&limit=10")["data"]
end

def state(v) = v.dig("attributes", "appVersionState") || v.dig("attributes", "appStoreState")

def localizations(version_id)
  api(:get, "/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=50")["data"]
    .to_h { |l| [l.dig("attributes", "locale"), l["id"]] }
end

def versions
  api(:get, "/v1/apps/#{APP_ID}/appStoreVersions?filter[platform]=IOS&limit=10")["data"]
end

def state(v) = v.dig("attributes", "appVersionState") || v.dig("attributes", "appStoreState")

def localizations(version_id)
  api(:get, "/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=50")["data"]
    .to_h { |l| [l.dig("attributes", "locale"), l["id"]] }
end

DUO_TYPE = "APP_IPHONE_DUO"
# Reihenfolge im Store: zuerst das, was es nur auf dem Duo gibt – der
# geteilte Sucher und der Film auf dem Außendisplay –, dann der Rest innen,
# dann das zugeklappte Gerät.
ORDER = %w[innen/%s/duo-innen-2.png aussen/%s/duo-aussen-4.png
           innen/%s/duo-innen-1.png innen/%s/duo-innen-3.png
           aussen/%s/duo-aussen-2.png aussen/%s/duo-aussen-1.png aussen/%s/duo-aussen-3.png].freeze

def files_for(locale)
  ORDER.map { |p| File.join(ROOT, "fastlane/screenshots-duo", format(p, locale)) }
end

def duo_set(loc_id, create: false)
  sets = api(:get, "/v1/appStoreVersionLocalizations/#{loc_id}/appScreenshotSets?limit=50")["data"]
  set = sets.find { |s| s.dig("attributes", "screenshotDisplayType") == DUO_TYPE }
  return set if set || !create

  api(:post, "/v1/appScreenshotSets", { data: {
    type: "appScreenshotSets",
    attributes: { screenshotDisplayType: DUO_TYPE },
    relationships: { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: loc_id } } }
  } })["data"]
end

def shots(set_id)
  api(:get, "/v1/appScreenshotSets/#{set_id}/appScreenshots?limit=20")["data"]
end

def upload_shot(set_id, path)
  bytes = File.binread(path)
  created = api(:post, "/v1/appScreenshots", { data: {
    type: "appScreenshots",
    attributes: { fileName: File.basename(path), fileSize: bytes.bytesize },
    relationships: { appScreenshotSet: { data: { type: "appScreenshotSets", id: set_id } } }
  } })["data"]

  created.dig("attributes", "uploadOperations").each do |op|
    uri = URI(op["url"])
    req = Net::HTTP.const_get(op["method"].capitalize).new(uri)
    (op["requestHeaders"] || []).each { |h| req[h["name"]] = h["value"] }
    req.body = bytes.byteslice(op["offset"], op["length"])
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    abort "Upload-Teil fehlgeschlagen (#{res.code})" unless res.code.to_i.between?(200, 299)
  end

  api(:patch, "/v1/appScreenshots/#{created['id']}", { data: {
    type: "appScreenshots", id: created["id"],
    attributes: { uploaded: true, sourceFileChecksum: Digest::MD5.hexdigest(bytes) }
  } })
  created["id"]
end

def show_version(v)
  puts "#{v.dig('attributes', 'versionString')} — #{state(v)}"
  localizations(v["id"]).each do |locale, loc_id|
    next unless LOCALES.include?(locale)
    set = duo_set(loc_id)
    list = set ? shots(set["id"]).map { |s| "#{s.dig('attributes', 'fileName')} (#{s.dig('attributes', 'assetDeliveryState', 'state') || '?'})" } : []
    puts "  #{locale}: #{list.empty? ? 'keine Duo-Screenshots' : list.join(', ')}"
  end
end

case ARGV.first
when "status"
  LOCALES.each do |l|
    have = files_for(l).count { |f| File.exist?(f) }
    puts "lokal #{l}: #{have} von #{ORDER.size} Bildern"
  end
  versions.first(2).each { |v| show_version(v) }

when "upload"
  missing = LOCALES.flat_map { |l| files_for(l) }.reject { |f| File.exist?(f) }
  abort "Bilder fehlen:\n  " + missing.join("\n  ") unless missing.empty?

  v = versions.find { |x| EDITABLE.include?(state(x)) }
  unless v
    current = versions.first
    abort <<~MSG
      Keine bearbeitbare Version. Neueste: #{current.dig('attributes', 'versionString')} — #{state(current)}.
      Screenshots lassen sich nur an eine Version hängen, die noch nicht in Prüfung ist.
      Mit der nächsten Version (fastlane release) erneut aufrufen – vor dem Einreichen.
    MSG
  end
  puts "Version #{v.dig('attributes', 'versionString')} (#{state(v)})"
  locs = localizations(v["id"])
  LOCALES.each do |locale|
    loc_id = locs[locale] or abort("Sprache #{locale} fehlt an dieser Version.")
    set = duo_set(loc_id, create: true)
    # Eigene frühere Bilder ersetzen, fremde nicht anfassen
    shots(set["id"]).each do |s|
      next unless s.dig("attributes", "fileName").to_s.start_with?("duo-")
      api(:delete, "/v1/appScreenshots/#{s['id']}")
    end
    ids = files_for(locale).map do |path|
      print "  #{locale}: #{File.basename(path)} … "
      id = upload_shot(set["id"], path)
      puts "ok"
      id
    end
    # Reihenfolge festschreiben – Apple sortiert sonst nach Ankunft
    api(:patch, "/v1/appScreenshotSets/#{set['id']}/relationships/appScreenshots",
        { data: ids.map { |id| { type: "appScreenshots", id: id } } })
  end
  show_version(v)

else
  puts "Aufruf: ruby scripts/duo_screenshots.rb status | upload"
end
