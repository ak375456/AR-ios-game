//
//  AppLog.swift
//  vr
//
//  Unified-log channels, so problems on a real device are diagnosable.
//

import OSLog

/// Logging is limited to things that are genuinely worth knowing after the
/// fact: what the loaded car measured, and every failure the user was shown.
enum AppLog {
    private static let subsystem = "Lexur-Co.vr"

    // Nonisolated so the ARSession delegate, which ARKit calls off the main
    // actor, can log a failure without hopping first. Logger is Sendable.
    nonisolated static let session = Logger(subsystem: subsystem, category: "arsession")
    nonisolated static let asset = Logger(subsystem: subsystem, category: "asset")
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
}
