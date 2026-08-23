//
// CSTGradeError.swift
//
// Shared error type for the FxPlug service and the optional organizer UI in
// the outer .fxplug application. It has no FxPlug dependency.
//

import Foundation

final class CSTGradeError: NSError {
    init(_ message: String) {
        super.init(domain: "com.example.cstgrade", code: 1,
                   userInfo: [NSLocalizedDescriptionKey: message])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
