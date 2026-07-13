#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

Dir.mktmpdir("managed-profiles-", ENV.fetch("OLC_TEST_TMPDIR")) do |dir|
  source = File.join(dir, "cohort.json")
  output = File.join(dir, "BuiltInProfiles.local.json")
  File.write(source, JSON.generate([
    {
      "id" => "telemost",
      "name" => "Telemost",
      "bootstrap" => {
        "url" => "https://example.invalid/internal/telemost.olcb",
        "client_key" => "a" * 64
      }
    }
  ]))
  env = { "OLC_MANAGED_PROFILES_JSON" => source }
  command = [File.join(__dir__, "generate-local-profiles.rb"), "--output", output]
  _stdout, stderr, status = Open3.capture3(env, *command)
  abort(stderr) unless status.success?
  profiles = JSON.parse(File.read(output))
  abort("telemost bootstrap missing") unless profiles.dig(0, "bootstrap", "client_key") == "a" * 64
  abort("ephemeral subscription embedded") unless profiles[0]["subscription"].nil?
  abort("WB template missing") unless profiles.any? { |profile| profile["id"] == "wb" }

  invalid_source = File.join(dir, "invalid.json")
  File.write(invalid_source, JSON.generate([
    {
      "id" => "telemost",
      "bootstrap" => { "url" => "https://", "client_key" => "a" * 64 }
    }
  ]))
  _stdout, stderr, status = Open3.capture3(
    { "OLC_MANAGED_PROFILES_JSON" => invalid_source },
    *command
  )
  abort("invalid bootstrap URL accepted") if status.success?
  abort("unexpected invalid URL error: #{stderr}") unless stderr.include?("URL must use HTTPS")
end

puts "ManagedProfilesGeneratorTest passed"
