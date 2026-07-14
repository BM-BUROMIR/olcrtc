#!/usr/bin/env ruby
# frozen_string_literal: true

# ai-generated: encrypts a managed enrollment for one legacy tunnel credential.
require "digest"
require "json"
require "openssl"
require "optparse"
require "securerandom"
require "uri"

options = {}
OptionParser.new do |parser|
  parser.on("--legacy-yaml PATH") { |value| options[:legacy_yaml] = value }
  parser.on("--enrollment PATH") { |value| options[:enrollment] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

abort("--legacy-yaml is required") unless options[:legacy_yaml]
abort("--enrollment is required") unless options[:enrollment]
abort("--output is required") unless options[:output]

legacy_yaml = File.binread(options.fetch(:legacy_yaml))
abort("legacy YAML is empty") if legacy_yaml.empty?
enrollment_data = File.binread(options.fetch(:enrollment))
enrollment = JSON.parse(enrollment_data)
abort("enrollment must be a non-empty array") unless enrollment.is_a?(Array) && !enrollment.empty?

allowed_ids = %w[telemost wb]
abort("managed profile must be an object") unless enrollment.all? { |profile| profile.is_a?(Hash) }
ids = enrollment.map { |profile| profile["id"] }
abort("unsupported or duplicate enrollment profile") unless ids.uniq == ids && (ids - allowed_ids).empty?
enrollment.each do |profile|
  abort("managed profile name is required") if profile["name"].to_s.strip.empty?
  bootstrap = profile["bootstrap"]
  abort("managed bootstrap missing") unless bootstrap.is_a?(Hash)
  url = URI.parse(bootstrap["url"].to_s)
  valid_url = url.is_a?(URI::HTTPS) && url.host && !url.userinfo && !url.query && !url.fragment
  abort("managed bootstrap URL must use plain HTTPS") unless valid_url
  abort("managed bootstrap key must be hex64") unless bootstrap["client_key"].to_s.match?(/\A[0-9a-fA-F]{64}\z/)
end

magic = "OLCM1".b
nonce = SecureRandom.random_bytes(12)
key = Digest::SHA256.digest("OLC legacy enrollment migration v1\0".b + legacy_yaml)
cipher = OpenSSL::Cipher.new("aes-256-gcm")
cipher.encrypt
cipher.key = key
cipher.iv = nonce
cipher.auth_data = magic
ciphertext = cipher.update(enrollment_data) + cipher.final
blob = magic + nonce + ciphertext + cipher.auth_tag

flags = File::WRONLY | File::CREAT | File::EXCL
File.open(options.fetch(:output), flags, 0o600) do |stream|
  stream.write(blob)
  stream.flush
  stream.fsync
end
puts("Wrote encrypted legacy enrollment migration")
