#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "yaml"

ROOT = File.expand_path("..", __dir__)
DEFAULT_OUTPUT = File.join(ROOT, "App", "BuiltInProfiles.local.json")
DEFAULT_TELEMOST_JSON = File.expand_path("../../../.secrets/olc-stand/telemost-subscription.json", ROOT)
DEFAULT_WB_YAML = File.expand_path("../../../.secrets/olc-stand/wb-srv.yaml", ROOT)

options = {
  output: DEFAULT_OUTPUT,
  allow_missing_wb: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: scripts/generate-local-profiles.rb [options]"
  parser.on("--output PATH", "Write generated profile JSON to PATH") { |value| options[:output] = value }
  parser.on("--allow-missing-wb", "Generate only available profiles instead of failing when WB input is absent") do
    options[:allow_missing_wb] = true
  end
end.parse!

def fail_clean(message)
  warn("ERROR: #{message}")
  exit(1)
end

def read_json(path, label)
  fail_clean("#{label} file is missing: #{path}") unless File.file?(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  fail_clean("#{label} JSON is invalid: #{e.message}")
end

def read_yaml(path, label)
  fail_clean("#{label} file is missing: #{path}") unless File.file?(path)
  YAML.load_file(path)
rescue Psych::SyntaxError => e
  fail_clean("#{label} YAML is invalid: #{e.message}")
end

def compact_subscription(raw)
  {
    "carrier" => raw["carrier"],
    "room" => raw["room"],
    "channel" => raw["channel"],
    "crypto_key" => raw["crypto_key"],
    "transport" => raw["transport"] || "vp8channel"
  }
end

def subscription_from_cnc_yaml(path, label)
  data = read_yaml(path, label)
  compact_subscription(
    "carrier" => data.dig("auth", "provider"),
    "room" => data.dig("room", "id"),
    "channel" => data.dig("room", "channel"),
    "crypto_key" => data.dig("crypto", "key"),
    "transport" => data.dig("net", "transport")
  )
end

def validate_subscription!(subscription, label)
  missing = subscription.select { |_key, value| value.nil? || value.to_s.strip.empty? }.keys
  fail_clean("#{label} subscription is missing fields: #{missing.join(", ")}") unless missing.empty?
  fail_clean("#{label} crypto_key must be 64 hex chars") unless subscription["crypto_key"].match?(/\A[0-9a-fA-F]{64}\z/)
end

def profile(id, name, subscription)
  validate_subscription!(subscription, name)
  {
    "id" => id,
    "name" => name,
    "subscription" => subscription,
    "isBuiltIn" => true
  }
end

profiles = []

telemost_json = ENV.fetch("OLC_TELEMOST_SUBSCRIPTION_JSON", DEFAULT_TELEMOST_JSON)
profiles << profile("telemost", "Telemost", compact_subscription(read_json(telemost_json, "Telemost")))

wb_profile =
  if ENV["OLC_WB_SUBSCRIPTION_JSON"]
    compact_subscription(read_json(ENV.fetch("OLC_WB_SUBSCRIPTION_JSON"), "WB"))
  elsif ENV["OLC_WB_SRV_YAML"]
    subscription_from_cnc_yaml(ENV.fetch("OLC_WB_SRV_YAML"), "WB")
  elsif File.file?(DEFAULT_WB_YAML)
    subscription_from_cnc_yaml(DEFAULT_WB_YAML, "WB")
  end

if wb_profile
  profiles << profile("wb", "WB", wb_profile)
elsif !options[:allow_missing_wb]
  fail_clean("WB input is missing; set OLC_WB_SUBSCRIPTION_JSON or OLC_WB_SRV_YAML")
end

output = File.expand_path(options[:output], ROOT)
File.write(output, "#{JSON.pretty_generate(profiles)}\n")
puts("Wrote #{profiles.length} built-in profiles to #{output}")
