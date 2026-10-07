#!/usr/bin/env ruby
# frozen_string_literal: true
#
# FrameFold — Featuring-Nominierung für App Store Connect über die API.
#
#   ruby scripts/nomination.rb draft    # Entwurf anlegen oder aktualisieren (nicht eingereicht)
#   ruby scripts/nomination.rb show     # vorhandene Nominierungen anzeigen
#   ruby scripts/nomination.rb submit   # den Entwurf an Apples Redaktion schicken
#
# Ein Entwurf ist in App Store Connect unter Featuring → Nominierungen
# sichtbar und dort noch änderbar. Erst `submit` schickt ihn ab.
#
# Schlüssel: der CI-Schlüssel (Rolle App-Manager – laut Apple für
# Nominierungen ausreichend), liegt ausserhalb des Repositorys.

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
# Apple begrenzt Beschreibung und Notiz auf je 1000 Zeichen.

NAME = "FrameFold 2.1 – Folds open on iPhone Duo"

DESCRIPTION = <<~TEXT.strip
  FrameFold turns a session at the craft table into a stop-motion film. It fires by itself whenever the hands leave the frame and keeps only sharp frames – all on-device, no account, no cloud.

  Version 2.1 is optimized for iPhone Duo. Unfolded, the viewfinder opens like a book: the camera on the left page, the film so far looping on the right, with the split exactly on the fold. Fold the phone mid-session and the capture simply carries on, on either display. An app for artists who fold paper, on a phone that folds.

  2.1 also reworks the auto-shutter: it waits until fingertips have left the frame, works in low and flickering light, skips duplicate frames and tells a plainer subject from a real loss of focus.

  Built for Austrian artist Aldo Tolino. In English, German and French, with an Apple Watch remote and VoiceOver support.
TEXT

# „Helpful Details": Apple bittet, die Duo-Optimierung hier zu nennen.
NOTES = <<~TEXT.strip
  Optimized for iPhone Duo: built with the iOS 27.1 SDK, tested on both displays and across folding and unfolding in the simulator, with iPhone Duo screenshots in all three languages. Made by a one-person studio in Lower Austria. The source code is public, including the evaluation behind the new auto-shutter.
TEXT

ATTRIBUTES = {
  name: NAME,
  type: "APP_ENHANCEMENTS",
  description: DESCRIPTION,
  notes: NOTES,
  publishStartDate: "2026-10-23T00:00:00Z",   # Verkaufsstart des iPhone Duo
  deviceFamilies: %w[IPHONE APPLE_WATCH],
  locales: %w[en-US de-DE fr-FR],
  supplementalMaterialsUris: [
    "https://github.com/RainerBracharz/framefold",
    "https://www.bracharz.com/en/niche-app-marketing/"
  ],
  hasInAppEvents: false,
  launchInSelectMarketsFirst: false,
  preOrderEnabled: false
}.freeze

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

def existing
  # Apple verlangt den Status-Filter und nimmt nur einen Wert pro Abfrage
  %w[DRAFT SUBMITTED].flat_map do |state|
    api(:get, "/v1/nominations?filter[relatedApps]=#{APP_ID}&filter[state]=#{state}&limit=50")["data"] || []
  end
end

def ours
  existing.find { |n| n.dig("attributes", "name") == NAME }
end

def print_nomination(n)
  a = n["attributes"] || {}
  puts "#{a['name']}"
  puts "  Status:  #{a['state'] || (a['submitted'] ? 'eingereicht' : 'Entwurf')}"
  puts "  Typ:     #{a['type']} · ab #{a['publishStartDate']}"
  puts "  ID:      #{n['id']}"
end

case ARGV.first
when "show"
  list = existing
  puts(list.empty? ? "Keine Nominierungen." : "")
  list.each { |n| print_nomination(n) }

when "draft"
  if (n = ours)
    a = n.dig("attributes") || {}
    abort "Bereits eingereicht – nicht mehr änderbar." if a["submitted"] || a["state"] == "SUBMITTED"
    api(:patch, "/v1/nominations/#{n['id']}",
        { data: { type: "nominations", id: n["id"], attributes: ATTRIBUTES } })
    puts "Entwurf aktualisiert."
  else
    api(:post, "/v1/nominations", { data: {
      type: "nominations",
      attributes: ATTRIBUTES.merge(submitted: false),
      relationships: { relatedApps: { data: [{ type: "apps", id: APP_ID }] } }
    } })
    puts "Entwurf angelegt."
  end
  print_nomination(ours)

when "submit"
  n = ours or abort("Kein Entwurf gefunden – erst `ruby scripts/nomination.rb draft`.")
  api(:patch, "/v1/nominations/#{n['id']}",
      { data: { type: "nominations", id: n["id"], attributes: { submitted: true } } })
  puts "Eingereicht."
  print_nomination(ours)

else
  puts "Aufruf: ruby scripts/nomination.rb draft | show | submit"
end
