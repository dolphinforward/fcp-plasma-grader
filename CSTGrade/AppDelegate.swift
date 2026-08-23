//
// AppDelegate.swift
//
// The outer bundle contains the out-of-process PlugInKit XPC service. It also
// provides the optional standalone LUT organizer used when a host does not
// safely allow a large browser window from an embedded custom view. No
// rendering or host parameter API work belongs in this target.

import AppKit

@NSApplicationMain
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var organizerWindowController: CSTLUTLibraryWindowController?
    private var requestToken: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The wrapper is normally started by PlugInKit as a container. When a
        // user launches it explicitly, it is also a safe fallback organizer.
        showOrganizer()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == CSTLUTOrganizerBridge.urlScheme {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            requestToken = queryItems.first(where: { $0.name == "request" })?.value
            let requestedIdentifier = queryItems
                .first(where: { $0.name == "selection" })?.value
                .flatMap { UInt64($0) }
            CSTLUTLibraryStore.shared.load()
            let requestedSelection = requestedIdentifier.flatMap { identifier in
                CSTLUTLibraryStore.shared.displayRecords()
                    .first(where: { $0.identifier == identifier })?.selection()
            } ?? .none()
            showOrganizer(selection: requestedSelection)
        }
    }

    private func showOrganizer(selection: CSTLUTSelection = .none()) {
        if organizerWindowController == nil {
            organizerWindowController = CSTLUTLibraryWindowController(selection: selection) { [weak self] selection in
                guard let self, let requestToken = self.requestToken else { return }
                CSTLUTOrganizerBridge.post(selection: selection, requestToken: requestToken)
            }
        } else {
            organizerWindowController?.setSelection(selection)
        }
        organizerWindowController?.showWindow(self)
        organizerWindowController?.window?.makeKeyAndOrderFront(self)
    }
}
