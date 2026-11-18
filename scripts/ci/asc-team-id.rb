#!/usr/bin/env ruby
# frozen_string_literal: true
# Print the Apple team ID (App ID prefix) of a bundle ID, read from App Store Connect with an API
# key, so CI needs no separate team-ID setting. Used by .github/workflows/release-ios.yml when the
# APPLE_TEAM_ID repository variable is not set.
#
#   ruby scripts/ci/asc-team-id.rb <AuthKey.p8> <key id> <issuer id> <bundle id>
#   ruby scripts/ci/asc-team-id.rb --jwt <AuthKey.p8> <key id> <issuer id>   (print the token only)
#
# The team ID is the bundle ID's seedId (GET /v1/bundleIds). Ruby's own openssl/net-http only, so
# it runs on a stock macOS runner without gems. Any key role that can read Identifiers works.
require "openssl"
require "json"
require "base64"
require "net/http"
require "uri"

def b64url(bytes)
  Base64.urlsafe_encode64(bytes, padding: false)
end

# ES256 JWT for the App Store Connect API (20-minute maximum lifetime; 10 used).
def asc_token(p8_path, key_id, issuer)
  key = OpenSSL::PKey.read(File.read(p8_path))
  now = Time.now.to_i
  head = b64url(JSON.generate({ alg: "ES256", kid: key_id, typ: "JWT" }))
  body = b64url(JSON.generate({ iss: issuer, iat: now, exp: now + 600, aud: "appstoreconnect-v1" }))
  der = key.sign(OpenSSL::Digest.new("SHA256"), "#{head}.#{body}")
  # OpenSSL returns an ASN.1 (r, s) pair; a JWS wants the two 32-byte integers back to back.
  raw = OpenSSL::ASN1.decode(der).value.map { |i| i.value.to_s(2).rjust(32, "\0".b) }.join
  "#{head}.#{body}.#{b64url(raw)}"
end

if ARGV[0] == "--jwt"
  abort "usage: #{$PROGRAM_NAME} --jwt <p8> <key id> <issuer id>" unless ARGV.size == 4
  puts asc_token(*ARGV[1, 3])
  exit
end
abort "usage: #{$PROGRAM_NAME} <p8> <key id> <issuer id> <bundle id>" unless ARGV.size == 4
p8, key_id, issuer, bundle = ARGV

uri = URI("https://api.appstoreconnect.apple.com/v1/bundleIds")
uri.query = URI.encode_www_form("filter[identifier]" => bundle, "fields[bundleIds]" => "identifier,seedId",
                                "limit" => "200")
req = Net::HTTP::Get.new(uri, "Authorization" => "Bearer #{asc_token(p8, key_id, issuer)}")
res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 30) { |h| h.request(req) }
abort "App Store Connect answered HTTP #{res.code}: #{res.body.to_s[0, 400]}" unless res.is_a?(Net::HTTPSuccess)
# The filter also matches longer identifiers that start with this one; keep the exact match.
hit = JSON.parse(res.body).fetch("data", []).find { |d| d.dig("attributes", "identifier") == bundle }
abort "bundle ID #{bundle} is not registered for this team" unless hit
seed = hit.dig("attributes", "seedId").to_s
abort "unexpected seedId #{seed.inspect}" unless seed.match?(/\A[A-Z0-9]{10}\z/)
puts seed
