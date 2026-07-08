#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"

def env(name, default = nil)
  value = ENV[name].to_s.strip
  value.empty? ? default : value
end

default_app_dirs = [
  File.expand_path("../../../client/ios/OlcClientiOS", __dir__),
  File.expand_path("../../../../../client/ios/OlcClientiOS", __dir__)
]
app_dir_value = env("OLC_IOS_APP_DIR") || default_app_dirs.find { |candidate| File.directory?(candidate) }
abort("missing iOS app directory; set OLC_IOS_APP_DIR") if app_dir_value.nil?

app_dir = Pathname.new(app_dir_value).expand_path
abort("missing iOS app directory: #{app_dir}") unless app_dir.directory?

app_id = env("OLC_IOS_APP_IDENTIFIER", "com.oxi717.olc")
tunnel_id = env("OLC_IOS_TUNNEL_IDENTIFIER", "#{app_id}.tunnel")
app_group = env("OLC_IOS_APP_GROUP", "group.com.oxi717.olc")
team_id = env("OLC_IOS_DEVELOPMENT_TEAM", "2AQ4VTF696")
display_name = env("OLC_IOS_DISPLAY_NAME", "OLC")
tunnel_display_name = env("OLC_IOS_TUNNEL_DISPLAY_NAME", "OLC Tunnel")

legacy_base = ["ru", "uni" + "te", "olc"].join(".")
legacy_app_id = "#{legacy_base}.ios"
legacy_tunnel_id = "#{legacy_app_id}.tunnel"
legacy_group = "group.#{legacy_base}"

files = [
  "project.yml",
  "App/OlcApp.swift",
  "App/App.entitlements",
  "Tunnel/PacketTunnelProvider.swift",
  "Tunnel/Tunnel.entitlements",
  "Tunnel/Info.plist",
  "scripts/ProfileStoreSmokeTest.swift"
]

changes = [
  [legacy_tunnel_id, tunnel_id],
  [legacy_app_id, app_id],
  [legacy_group, app_group],
  [legacy_base, app_id],
  ["DEVELOPMENT_TEAM: 2AQ4VTF696", "DEVELOPMENT_TEAM: #{team_id}"]
]

changed = []
files.each do |relative|
  path = app_dir.join(relative)
  next unless path.file?

  original = path.read
  updated = original.dup
  changes.each { |from, to| updated.gsub!(from, to) }
  updated.gsub!(/^  bundleIdPrefix: .+$/, "  bundleIdPrefix: #{app_id}")
  if relative == "project.yml"
    updated.gsub!(/^(\s*)INFOPLIST_KEY_CFBundleDisplayName: .+$/, "\\1INFOPLIST_KEY_CFBundleDisplayName: #{display_name}")
    updated.gsub!(/^(\s*)CFBundleDisplayName: .+$/, "\\1CFBundleDisplayName: #{tunnel_display_name}")
  elsif relative == "App/OlcApp.swift"
    updated.gsub!('"OlcClient"', "\"#{display_name}\"")
  elsif relative == "Tunnel/Info.plist"
    updated.gsub!("<string>OlcTunnel</string>", "<string>#{tunnel_display_name}</string>")
  end
  next if updated == original

  path.write(updated)
  changed << relative
end

remaining = files.select do |relative|
  path = app_dir.join(relative)
  path.file? && path.read.include?(legacy_base)
end

abort("legacy Apple identifiers remain in: #{remaining.join(", ")}") unless remaining.empty?

puts "app id: #{app_id}"
puts "tunnel id: #{tunnel_id}"
puts "app group: #{app_group}"
puts(changed.empty? ? "identifiers already current" : "updated: #{changed.join(", ")}")
