#!/bin/bash

set -euo pipefail

release_dir="$(cd "$(dirname "$0")" && pwd -P)"
plugin_source="$release_dir/CSTGrade.fxplug"
template_source="$release_dir/Motion Templates.localized/Effects.localized/FCP Plasma Grader/FCP Plasma Grader"
plugin_parent="$HOME/Library/Plug-Ins/FxPlug"
plugin_destination="$plugin_parent/CSTGrade.fxplug"
template_parent="$HOME/Movies/Motion Templates.localized/Effects.localized/FCP Plasma Grader"
template_destination="$template_parent/FCP Plasma Grader"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
plugin_stage="$plugin_parent/.CSTGrade.fxplug.install-$stamp"
template_stage="$template_parent/.FCP Plasma Grader.install-$stamp"

show_message() {
  local title="$1"
  local message="$2"
  /usr/bin/osascript -e "display dialog \"$message\" with title \"$title\" buttons {\"OK\"} default button \"OK\"" >/dev/null 2>&1 || true
}

fail() {
  printf 'Installation failed: %s\n' "$1" >&2
  show_message "FCP Plasma Grader" "Installation failed: $1"
  exit 1
}

cleanup() {
  /bin/rm -rf "$plugin_stage" "$template_stage"
}
trap cleanup EXIT

if /usr/bin/pgrep -x "Final Cut Pro" >/dev/null 2>&1; then
  fail "Quit Final Cut Pro, then run this installer again."
fi

test -d "$plugin_source" || fail "CSTGrade.fxplug is missing from this release folder."
test -f "$plugin_source/Contents/Info.plist" || fail "CSTGrade.fxplug is incomplete."
test -f "$template_source/FCP Plasma Grader.moef" || fail "The Final Cut effect template is missing."

/bin/mkdir -p "$plugin_parent" "$template_parent" "$HOME/.Trash"
/bin/rm -rf "$plugin_stage" "$template_stage"
/usr/bin/ditto "$plugin_source" "$plugin_stage"
/usr/bin/ditto "$template_source" "$template_stage"

if test -e "$plugin_destination"; then
  /bin/mv "$plugin_destination" "$HOME/.Trash/CSTGrade.fxplug.backup-$stamp"
fi
if test -e "$template_destination"; then
  /bin/mv "$template_destination" "$HOME/.Trash/FCP Plasma Grader template.backup-$stamp"
fi

/bin/mv "$plugin_stage" "$plugin_destination"
/bin/mv "$template_stage" "$template_destination"

# GitHub downloads are quarantined by macOS. This unsigned community build is
# ad-hoc signed in CI, so clear quarantine only on the two exact installed
# payloads after their paths and contents have been validated above.
/usr/bin/xattr -dr com.apple.quarantine "$plugin_destination" "$template_destination" 2>/dev/null || true
/usr/bin/pluginkit -a "$plugin_destination" 2>/dev/null || true

printf 'Installed FCP Plasma Grader.\n'
printf 'Plug-in: %s\n' "$plugin_destination"
printf 'Effect template: %s\n' "$template_destination"
printf 'Open Final Cut Pro and search Effects for “FCP Plasma Grader”.\n'
show_message "FCP Plasma Grader" "Installed successfully. Open Final Cut Pro and search Effects for FCP Plasma Grader."
