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

NAME = "FrameFold 2.0 – The film grows as you work"

DESCRIPTION = <<~TEXT.strip
  FrameFold turns a working session at the craft table into a stop-motion film: it fires by itself whenever the artist's hands leave the frame, keeps only sharp frames, and assembles the result – entirely on-device, no account, no cloud.

  Version 2.0 adds two things that change how it is used:

  The film grows as you work. From the second frame on, the stop-motion already plays as a loop while the session is still running – small in the viewfinder, and large on a studio monitor (HDMI or AirPlay) next to the live camera feed. In a class or on a studio visit, everyone sees the hands at work and the piece they are making, side by side.

  Flip book. Every work can be printed as a ready-to-cut flip book: A4 sheets with cut lines, a binding edge and numbered leaves. Image, object, image – and back to an object you can hold in your hands.

  FrameFold was built for the Austrian artist Aldo Tolino, who folds printed photographs into objects and photographs them again. Available in English, German and French, with an Apple Watch remote, and support for VoiceOver, larger text and Reduce Motion.
TEXT

NOTES = <<~TEXT.strip
  Made by a one-person studio in Lower Austria. The source code is public, so every claim above can be checked. Flip books and stop-motion loops work well in classrooms – art teachers are a core audience.
TEXT

ATTRIBUTES = {
  name: NAME,
  type: "APP_ENHANCEMENTS",
  description: DESCRIPTION,
  notes: NOTES,
  publishStartDate: "2026-10-06T00:00:00Z",
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
