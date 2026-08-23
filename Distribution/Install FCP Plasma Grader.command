#!/bin/bash

set -euo pipefail

release_dir="$(cd "$(dirname "$0")" && pwd -P)"
plugin_source="$release_dir/CSTGrade.fxplug"
template_source="$release_dir/Motion Templates.localized/Effects.localized/FCP Plasma Grader/FCP Plasma Grader"
plugin_parent="$HOME/Library/Plug-Ins/FxPlug"
plugin_destination="$plugin_parent/CSTGrade.fxplug"
template_parent="$HOME/Movies/Motion Templates.localized/Effects.localized/FCP Plasma Grader"
template_destination="$template_parent/FCP Plasma Grader"
fcp_app="/Applications/Final Cut Pro.app"
fcp_info="$fcp_app/Contents/Info.plist"
fcp_frameworks="$fcp_app/Contents/Frameworks"
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
test -d "$fcp_app" || fail "Final Cut Pro is not installed in /Applications."
test -f "$fcp_info" || fail "Final Cut Pro's version information is missing."

fcp_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$fcp_info" 2>/dev/null || true)"
test "$fcp_version" = "10.6.5" || fail "This compatibility build requires Final Cut Pro 10.6.5; found ${fcp_version:-an unknown version}."

# The hosted compiler uses the newer SDK's headers only. Its macOS 13 runtime
# binaries are deliberately absent from the release. Use the framework version
# already shipped with the user's signed FCP 10.6.5 app so the XPC runtime and
# host are the same legacy generation. The source application is never changed.
/usr/bin/codesign --verify --deep --strict "$fcp_app" || fail "Final Cut Pro's Apple code signature did not verify."
for framework in FxPlug.framework PluginManager.framework; do
  test -d "$fcp_frameworks/$framework" || fail "$framework is missing from Final Cut Pro 10.6.5."
  /usr/bin/codesign --verify --strict "$fcp_frameworks/$framework" || fail "$framework in Final Cut Pro did not verify."
done

/bin/mkdir -p "$plugin_parent" "$template_parent" "$HOME/.Trash"
/bin/rm -rf "$plugin_stage" "$template_stage"
/usr/bin/ditto "$plugin_source" "$plugin_stage"
/usr/bin/ditto "$template_source" "$template_stage"

service_stage="$plugin_stage/Contents/PlugIns/CSTGradeXPC.pluginkit"
framework_stage="$service_stage/Contents/Frameworks"
test -f "$service_stage/Contents/MacOS/CSTGradeXPC" || fail "The staged FxPlug service is incomplete."
/bin/mkdir -p "$framework_stage"
/usr/bin/ditto "$fcp_frameworks/PluginManager.framework" "$framework_stage/PluginManager.framework"
/usr/bin/ditto "$fcp_frameworks/FxPlug.framework" "$framework_stage/FxPlug.framework"

# Adding the matching runtime frameworks changes the nested XPC bundle, so
# ad-hoc sign the staged copy from the inside out using macOS's built-in
# codesign tool. This requires neither Xcode nor Command Line Tools.
/usr/bin/codesign --force --sign - --timestamp=none "$framework_stage/PluginManager.framework" || fail "Could not sign PluginManager.framework."
/usr/bin/codesign --force --sign - --timestamp=none "$framework_stage/FxPlug.framework" || fail "Could not sign FxPlug.framework."
/usr/bin/codesign --force --sign - --timestamp=none "$service_stage" || fail "Could not sign the FxPlug service."
/usr/bin/codesign --force --sign - --timestamp=none "$plugin_stage" || fail "Could not sign the FxPlug bundle."
/usr/bin/codesign --verify --deep --strict "$plugin_stage" || fail "The completed FxPlug bundle did not verify."

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
