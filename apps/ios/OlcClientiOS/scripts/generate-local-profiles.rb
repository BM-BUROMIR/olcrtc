#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "uri"

root = File.expand_path("..", __dir__)
options = { output: File.join(root, "App", "BuiltInProfiles.local.json") }
OptionParser.new do |parser|
  parser.on("--output PATH") { |value| options[:output] = value }
  # Retained for compatibility with existing TestFlight automation.
  parser.on("--allow-missing-wb") {}
end.parse!

templates = {
  "telemost" => { "id" => "telemost", "name" => "Telemost" },
  "wb" => { "id" => "wb", "name" => "WB" }
}

managed = {}
if ENV["OLC_MANAGED_PROFILES_JSON"]
  raw = JSON.parse(File.read(ENV.fetch("OLC_MANAGED_PROFILES_JSON")))
  abort("managed profiles must be an array") unless raw.is_a?(Array)
  raw.each do |profile|
    id = profile["id"]
    bootstrap = profile["bootstrap"]
    abort("unsupported managed profile id") unless templates.key?(id)
    abort("duplicate managed profile id") if managed.key?(id)
    abort("managed bootstrap missing") unless bootstrap.is_a?(Hash)
    begin
      bootstrap_url = URI.parse(bootstrap["url"].to_s)
    rescue URI::InvalidURIError
      bootstrap_url = nil
    end
    abort("managed bootstrap URL must use HTTPS") unless bootstrap_url&.is_a?(URI::HTTPS) && bootstrap_url.host
    abort("managed bootstrap key must be hex64") unless bootstrap["client_key"].to_s.match?(/\A[0-9a-fA-F]{64}\z/)
    managed[id] = profile
  end
end

profiles = templates.values.map do |template|
  supplied = managed[template["id"]] || {}
  {
    "id" => template["id"],
    "name" => supplied["name"] || template["name"],
    "subscription" => nil,
    "bootstrap" => supplied["bootstrap"],
    "isBuiltIn" => true
  }
end

output = File.expand_path(options[:output], root)
File.write(output, "#{JSON.pretty_generate(profiles)}\n")
puts("Wrote #{profiles.length} managed profile templates")
