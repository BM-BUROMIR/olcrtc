#!/bin/sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
work_dir="$repo_root/build/local-check"
export TMPDIR="$work_dir/tmp"
mkdir -p "$TMPDIR"

ruby_bin=${OLC_RUBY_BIN:-ruby}
if [ -z "${OLC_RUBY_BIN:-}" ] && command -v brew >/dev/null 2>&1; then
  brew_ruby=$(brew --prefix ruby 2>/dev/null)/bin/ruby
  [ ! -x "$brew_ruby" ] || ruby_bin=$brew_ruby
fi

app="$repo_root/apps/ios/OlcClientiOS/App"
tests="$repo_root/apps/ios/OlcClientiOS/scripts"

OLC_TEST_TMPDIR="$TMPDIR" "$ruby_bin" "$tests/ManagedProfilesGeneratorTest.rb"
OLC_TEST_TMPDIR="$TMPDIR" "$ruby_bin" "$tests/LegacyEnrollmentGeneratorTest.rb"
"$repo_root/tools/ios-testflight/test-verify-package.sh"
OLC_TEST_TMPDIR="$TMPDIR" "$repo_root/script/test-ios-post-update-acceptance.sh"

swiftc -parse-as-library -o "$work_dir/app-settings-smoke" \
  "$app/AppSettingsMigration.swift" \
  "$tests/AppSettingsMigrationSmokeTest.swift"
"$work_dir/app-settings-smoke"

swiftc -parse-as-library -o "$work_dir/bootstrap-smoke" \
  "$app/ManagedProfile.swift" \
  "$app/BootstrapResolver.swift" \
  "$tests/BootstrapResolverSmokeTest.swift"
"$work_dir/bootstrap-smoke"

swiftc -parse-as-library -o "$work_dir/legacy-enrollment-migration-smoke" \
  "$app/LegacyEnrollmentMigration.swift" \
  "$tests/LegacyEnrollmentMigrationSmokeTest.swift"
"$work_dir/legacy-enrollment-migration-smoke"

swiftc -parse-as-library -o "$work_dir/bounded-log-smoke" \
  "$app/BoundedLog.swift" \
  "$tests/BoundedLogSmokeTest.swift"
"$work_dir/bounded-log-smoke"

swiftc -parse-as-library -o "$work_dir/profile-store-smoke" \
  "$app/ManagedProfile.swift" \
  "$app/ProfileStore.swift" \
  "$tests/ProfileStoreSmokeTest.swift"
"$work_dir/profile-store-smoke"
