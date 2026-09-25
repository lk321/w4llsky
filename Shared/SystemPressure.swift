//
//  SystemPressure.swift
//  W4llsky — shared by the app and the screen saver bundle.
//
//  The one guarantee that holds however many displays, videos or saver processes
//  there are: when the Mac runs short of memory or runs hot, the wallpaper yields
//  before the Mac chokes. Event-driven (a dispatch memory-pressure source and the
//  thermal-state notification), so it costs nothing while nothing is wrong.
//

import Foundation

final class SystemPressure {
    nonisolated enum Level: Comparable {
        case normal
        /// Stop decoding (rate 0). Keeps the pipelines, so coming back is instant.
        case throttle
        /// Release every decoder. Rate 0 does not free one — only dropping the player
        /// does — and critical memory pressure is exactly when that memory is needed.
        case release
    }

    /// Pure so every combination can be checked without starving the machine.
    nonisolated static func level(memory: DispatchSource.MemoryPressureEvent, thermal: ProcessInfo.ThermalState) -> Level {
        if memory.contains(.critical) { return .release }
        // A memory *warning* is deliberately not here. Rate 0 frees no memory (only dropping
        // the player does), and macOS can sit at "warn" for hours with a third of RAM free:
        // throttling on it froze the desktop and blacked out the lock screen for nothing.
        if thermal == .serious || thermal == .critical { return .throttle }
        return .normal
    }

    private(set) var level: Level
    private var memory: DispatchSource.MemoryPressureEvent = .normal
    // `.main` on purpose: the teardown this drives ends in deinits that assume the main actor.
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    private var thermalToken: NSObjectProtocol?
    private let onChange: (Level) -> Void

    init(onChange: @escaping (Level) -> Void) {
        self.onChange = onChange
        level = Self.level(memory: .normal, thermal: ProcessInfo.processInfo.thermalState)

        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.memory = self.source.data
                self.update()
            }
        }
        source.activate()

        thermalToken = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    deinit {
        source.cancel()
        if let thermalToken { NotificationCenter.default.removeObserver(thermalToken) }
    }

    private func update() {
        let new = Self.level(memory: memory, thermal: ProcessInfo.processInfo.thermalState)
        guard new != level else { return }
        level = new
        onChange(new)
    }
}
