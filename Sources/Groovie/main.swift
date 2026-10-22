import Foundation
import GroovieKit

if CommandLine.arguments.contains("--self-test") {
    exit(Int32(SelfChecks.run() == 0 ? 0 : 1))
}

// Top-level code in main.swift always runs on the main thread.
MainActor.assumeIsolated {
    AppDelegate.run()
}
