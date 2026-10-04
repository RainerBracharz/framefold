#!/usr/bin/env ruby
# frozen_string_literal: true
#
# FrameFold — App-Vorschau (Video) für den App Store hochladen, je Sprache eine.
#
#   ruby scripts/app_preview.rb status   # Versionen und vorhandene Vorschauen zeigen
#   ruby scripts/app_preview.rb upload   # Videos an die bearbeitbare Version hängen
#
# Videos: fastlane/previews/<locale>/framefold-preview.mp4 (886 × 1920, 6,9").
# fastlane deliver kann keine Vorschauvideos – deshalb dieser Weg über die API.
#
# Apple nimmt Vorschauen nur an einer Version an, die noch bearbeitbar ist
# („Vorbereitung für Einreichung" oder abgelehnt). Ist gerade eine Version in
# Prüfung, bricht das Skript mit einem Hinweis ab und ändert nichts.
# Die Vorschau wird mit der nächsten Einreichung mitgeprüft.

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
FILE_NAME   = "framefold-preview.mp4"
PREVIEW     = "IPHONE_67"                 # 6,9" (886 × 1920), wird auf kleinere iPhones skaliert
POSTER_TIME = "00:00:08:00"               # Standbild, wenn Autoplay aus ist: Film wächst im Sucher
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

def preview_set(loc_id, create: false)
  sets = api(:get, "/v1/appStoreVersionLocalizations/#{loc_id}/appPreviewSets?limit=50")["data"]
  set = sets.find { |s| s.dig("attributes", "previewType") == PREVIEW }
  return set if set || !create

  api(:post, "/v1/appPreviewSets", { data: {
    type: "appPreviewSets",
    attributes: { previewType: PREVIEW },
    relationships: { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: loc_id } } }
  } })["data"]
end

def previews(set_id)
  api(:get, "/v1/appPreviewSets/#{set_id}/appPreviews?limit=10")["data"]
end

def upload_file(set_id, path)
  bytes = File.binread(path)
  created = api(:post, "/v1/appPreviews", { data: {
    type: "appPreviews",
    attributes: { fileName: FILE_NAME, fileSize: bytes.bytesize, mimeType: "video/mp4",
                  previewFrameTimeCode: POSTER_TIME },
    relationships: { appPreviewSet: { data: { type: "appPreviewSets", id: set_id } } }
  } })["data"]

  created.dig("attributes", "uploadOperations").each do |op|
    uri = URI(op["url"])
    req = Net::HTTP.const_get(op["method"].capitalize).new(uri)
    (op["requestHeaders"] || []).each { |h| req[h["name"]] = h["value"] }
    req.body = bytes.byteslice(op["offset"], op["length"])
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    abort "Upload-Teil fehlgeschlagen (#{res.code})" unless res.code.to_i.between?(200, 299)
  end

  api(:patch, "/v1/appPreviews/#{created['id']}", { data: {
    type: "appPreviews", id: created["id"],
    attributes: { uploaded: true, sourceFileChecksum: Digest::MD5.hexdigest(bytes) }
  } })
  created["id"]
end

def show_version(v)
  puts "#{v.dig('attributes', 'versionString')} — #{state(v)}"
  localizations(v["id"]).each do |locale, loc_id|
    next unless LOCALES.include?(locale)
    set = preview_set(loc_id)
    list = set ? previews(set["id"]) : []
    desc = list.map do |p|
      a = p["attributes"]
      "#{a['fileName']} (#{a.dig('assetDeliveryState', 'state') || '?'})"
    end
    puts "  #{locale.ljust(6)} #{desc.empty? ? '– keine Vorschau' : desc.join(', ')}"
  end
end

case ARGV.first
when "status"
  versions.first(2).each { |v| show_version(v) }

when "upload"
  files = LOCALES.to_h { |l| [l, File.join(ROOT, "fastlane/previews/#{l}/#{FILE_NAME}")] }
  missing = files.values.reject { |f| File.exist?(f) }
  abort "Videos fehlen:\n  " + missing.join("\n  ") unless missing.empty?

  v = versions.find { |x| EDITABLE.include?(state(x)) }
  unless v
    current = versions.first
    abort <<~MSG
      Keine bearbeitbare Version. Neueste: #{current.dig('attributes', 'versionString')} — #{state(current)}.
      Vorschauen lassen sich nur an eine Version hängen, die noch nicht in Prüfung ist.
      Mit der nächsten Version (fastlane release) erneut aufrufen – vor dem Einreichen.
    MSG
  end
  puts "Version #{v.dig('attributes', 'versionString')} (#{state(v)})"
  locs = localizations(v["id"])
  files.each do |locale, path|
    loc_id = locs[locale] or abort("Sprache #{locale} fehlt an dieser Version.")
    set = preview_set(loc_id, create: true)
    # Eigene frühere Vorschau ersetzen, fremde nicht anfassen
    previews(set["id"]).each do |p|
      next unless p.dig("attributes", "fileName") == FILE_NAME
      api(:delete, "/v1/appPreviews/#{p['id']}")
    end
    print "  #{locale}: lade #{File.size(path) / 1024} KB … "
    upload_file(set["id"], path)
    puts "ok"
  end
  puts "\nApple verarbeitet die Videos jetzt (einige Minuten). Stand: ruby scripts/app_preview.rb status"
  show_version(v)

else
  puts "Aufruf: ruby scripts/app_preview.rb status | upload"
end
