#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [output-directory]" >&2
  exit 2
fi

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="${1:-$source_dir/../build}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
package="$output_dir/BetterScreenshot.dynamiclakeplugin"

staging="$(mktemp -d "$output_dir/.betterscreenshot.XXXXXX")"
trap 'rmdir "$staging" 2>/dev/null || rm -rf "$staging"' EXIT
cp "$source_dir/plugin.json" "$staging/"
xcrun swiftc -O -target "$(uname -m)-apple-macosx13.0" \
  "$source_dir/BetterScreenshotPlugin.swift" -o "$staging/betterscreenshot-plugin"
chmod +x "$staging/betterscreenshot-plugin"
mkdir -p "$package"
mv "$staging/"* "$package/"
printf '%s\n' "$package"
