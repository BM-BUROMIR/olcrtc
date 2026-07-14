#!/usr/bin/env ruby
# frozen_string_literal: true

# ai-generated: verifies the private build-time legacy enrollment ciphertext format.
require "digest"
require "fileutils"
require "json"
require "openssl"
require "rbconfig"
require "tmpdir"

root = ENV.fetch("OLC_TEST_TMPDIR", Dir.tmpdir)
directory = File.join(root, "legacy-enrollment-generator-test-#{Process.pid}")
FileUtils.rm_rf(directory)
FileUtils.mkdir_p(directory)
at_exit { FileUtils.rm_rf(directory) }

legacy_yaml = "mode: cnc\ncrypto:\n  key: \"#{"b" * 64}\"\n"
enrollment = [
  {
    "id" => "telemost",
    "name" => "Telemost",
    "bootstrap" => {
      "url" => "https://example.invalid/device/telemost.olcb",
      "client_key" => "a" * 64
    }
  }
]
legacy_path = File.join(directory, "legacy.yaml")
enrollment_path = File.join(directory, "enrollment.json")
output = File.join(directory, "LegacyEnrollment.test.olcm")
File.binwrite(legacy_path, legacy_yaml)
File.write(enrollment_path, JSON.generate(enrollment))

generator = File.join(__dir__, "generate-legacy-enrollment.rb")
abort("generator failed") unless system(
  RbConfig.ruby,
  generator,
  "--legacy-yaml", legacy_path,
  "--enrollment", enrollment_path,
  "--output", output,
  out: File::NULL
)

blob = File.binread(output)
magic = "OLCM1".b
abort("invalid magic") unless blob.start_with?(magic)
nonce = blob.byteslice(5, 12)
ciphertext = blob.byteslice(17, blob.bytesize - 33)
tag = blob.byteslice(-16, 16)
key = Digest::SHA256.digest("OLC legacy enrollment migration v1\0".b + legacy_yaml.b)
cipher = OpenSSL::Cipher.new("aes-256-gcm")
cipher.decrypt
cipher.key = key
cipher.iv = nonce
cipher.auth_tag = tag
cipher.auth_data = magic
clear = cipher.update(ciphertext) + cipher.final

abort("enrollment mismatch") unless JSON.parse(clear) == enrollment
abort("legacy credential leaked") if blob.include?(legacy_yaml)
abort("bootstrap key leaked") if blob.include?("a" * 64)
abort("output permissions are not private") unless (File.stat(output).mode & 0o077).zero?

invalid_path = File.join(directory, "invalid-enrollment.json")
invalid_output = File.join(directory, "invalid.olcm")
invalid = enrollment.map(&:dup)
invalid[0] = invalid[0].merge(
  "name" => "",
  "bootstrap" => invalid[0]["bootstrap"].merge("url" => "https://example.invalid/device?key=value")
)
File.write(invalid_path, JSON.generate(invalid))
accepted_invalid = system(
  RbConfig.ruby,
  generator,
  "--legacy-yaml", legacy_path,
  "--enrollment", invalid_path,
  "--output", invalid_output,
  out: File::NULL,
  err: File::NULL
)
abort("generator accepted enrollment rejected by iOS") if accepted_invalid

puts("LegacyEnrollmentGeneratorTest passed")
