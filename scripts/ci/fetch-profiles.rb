#!/usr/bin/env ruby
# frozen_string_literal: true

# Download App Store provisioning profiles by name from the App Store Connect
# API and install them where Xcode looks. Read-only: the Release workflow
# signs manually and never creates certificates or profiles.
#
#   fetch-profiles.rb "Forumind App Store" "Forumind Share App Store"
#
# Env: ASC_KEY_PATH (.p8), APP_STORE_CONNECT_API_KEY_ID,
#      APP_STORE_CONNECT_ISSUER_ID.

require "base64"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "uri"

abort "usage: fetch-profiles.rb <profile name>..." if ARGV.empty?
key_path = ENV.fetch("ASC_KEY_PATH")
key_id = ENV.fetch("APP_STORE_CONNECT_API_KEY_ID")
issuer = ENV.fetch("APP_STORE_CONNECT_ISSUER_ID")

def b64url(data)
  Base64.urlsafe_encode64(data, padding: false)
end

# ES256 JWT; OpenSSL returns a DER signature, JOSE wants raw r||s.
def token(key_path, key_id, issuer)
  header = { alg: "ES256", kid: key_id, typ: "JWT" }
  now = Time.now.to_i
  claims = { iss: issuer, iat: now, exp: now + 600, aud: "appstoreconnect-v1" }
  input = "#{b64url(header.to_json)}.#{b64url(claims.to_json)}"
  key = OpenSSL::PKey::EC.new(File.read(key_path))
  der = key.sign(OpenSSL::Digest.new("SHA256"), input)
  r, s = OpenSSL::ASN1.decode(der).value.map { |n| n.value.to_s(2).rjust(32, "\0") }
  "#{input}.#{b64url(r + s)}"
end

jwt = token(key_path, key_id, issuer)
dirs = [
  File.join(Dir.home, "Library/Developer/Xcode/UserData/Provisioning Profiles"),
  File.join(Dir.home, "Library/MobileDevice/Provisioning Profiles")
]
dirs.each { |dir| FileUtils.mkdir_p(dir) }

ARGV.each do |name|
  uri = URI("https://api.appstoreconnect.apple.com/v1/profiles")
  uri.query = URI.encode_www_form(
    "filter[name]" => name,
    "filter[profileState]" => "ACTIVE",
    "fields[profiles]" => "name,uuid,profileContent,expirationDate"
  )
  request = Net::HTTP::Get.new(uri, "Authorization" => "Bearer #{jwt}")
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  abort "fetch-profiles: #{name}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  # The name filter can match by prefix; take the exact name only.
  matches = JSON.parse(response.body).fetch("data").select { |item| item.dig("attributes", "name") == name }
  abort "fetch-profiles: no active profile named #{name.inspect}" if matches.empty?
  profile = matches.max_by { |item| item.dig("attributes", "expirationDate").to_s }
  attributes = profile.fetch("attributes")
  content = Base64.decode64(attributes.fetch("profileContent"))
  dirs.each { |dir| File.binwrite(File.join(dir, "#{attributes.fetch('uuid')}.mobileprovision"), content) }
  puts "Installed #{name} (expires #{attributes['expirationDate']})"
end
