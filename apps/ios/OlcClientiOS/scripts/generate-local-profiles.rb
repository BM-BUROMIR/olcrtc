#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

root = File.expand_path("..", __dir__)
options = { output: File.join(root, "App", "BuiltInProfiles.local.json") }
OptionParser.new do |parser|
  parser.on("--output PATH") { |value| options[:output] = value }
  # Retained for compatibility with existing TestFlight automation.
  parser.on("--allow-missing-wb") {}
end.parse!

profiles = [
  { "id" => "telemost", "name" => "Telemost", "subscription" => nil, "bootstrap" => nil, "isBuiltIn" => true },
  { "id" => "wb", "name" => "WB", "subscription" => nil, "bootstrap" => nil, "isBuiltIn" => true }
]

output = File.expand_path(options[:output], root)
File.write(output, "#{JSON.pretty_generate(profiles)}\n")
puts("Wrote #{profiles.length} managed profile templates")
