#!/bin/bash

set -euo pipefail

plugin="$HOME/Library/Plug-Ins/FxPlug/CSTGrade.fxplug"
template="$HOME/Movies/Motion Templates.localized/Effects.localized/FCP Plasma Grader/FCP Plasma Grader"
stamp="$(date +%Y%m%d-%H%M%S)-$$"

if /usr/bin/pgrep -x "Final Cut Pro" >/dev/null 2>&1; then
  /usr/bin/osascript -e 'display dialog "Quit Final Cut Pro, then run the uninstaller again." with title "FCP Plasma Grader" buttons {"OK"} default button "OK"' >/dev/null 2>&1 || true
  exit 1
fi

answer=$(/usr/bin/osascript -e 'button returned of (display dialog "Move the FCP Plasma Grader plug-in and effect template to Trash? Your LUT library metadata will be kept." with title "Uninstall FCP Plasma Grader" buttons {"Cancel", "Move to Trash"} default button "Move to Trash" cancel button "Cancel")' 2>/dev/null || true)
test "$answer" = "Move to Trash" || exit 0

/bin/mkdir -p "$HOME/.Trash"
moved=0
if test -e "$plugin"; then
  /bin/mv "$plugin" "$HOME/.Trash/CSTGrade.fxplug.uninstalled-$stamp"
  moved=1
fi
if test -e "$template"; then
  /bin/mv "$template" "$HOME/.Trash/FCP Plasma Grader template.uninstalled-$stamp"
  moved=1
fi

if test "$moved" -eq 1; then
  message="FCP Plasma Grader was moved to Trash. Your LUT library metadata was kept."
else
  message="FCP Plasma Grader was not installed in the expected user folders."
fi
printf '%s\n' "$message"
/usr/bin/osascript -e "display dialog \"$message\" with title \"FCP Plasma Grader\" buttons {\"OK\"} default button \"OK\"" >/dev/null 2>&1 || true
