FCP PLASMA GRADER — INSTALLATION

You do not need Xcode or Motion.
This build targets Final Cut Pro 10.6.5 on an Intel Mac running Monterey.

1. Quit Final Cut Pro.
2. Double-click “Install FCP Plasma Grader.command”.
3. If macOS blocks it, Control-click the installer, choose Open, then confirm.
4. Open Final Cut Pro and search the Effects browser for “FCP Plasma Grader”.

The installer changes only these two user-level locations:

  ~/Library/Plug-Ins/FxPlug/CSTGrade.fxplug
  ~/Movies/Motion Templates.localized/Effects.localized/
    FCP Plasma Grader/FCP Plasma Grader

It does not install Xcode, Motion, a background service, an account, or a
network dependency. Before replacing anything, it confirms that the signed app
at /Applications/Final Cut Pro.app is version 10.6.5 and copies that app's
matching FxPlug runtime frameworks into the staged plug-in. It never modifies
Final Cut Pro. Replaced copies are moved to Trash as timestamped backups.

To uninstall, quit Final Cut Pro and double-click
“Uninstall FCP Plasma Grader.command”. The LUT organizer metadata is retained.
