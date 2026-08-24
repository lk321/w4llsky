//
//  ContentView.swift
//  W4llsky
//
//  Created by Antonio Orozco on 22/08/26.
//
//  The About window — the app's only window. Everything you can actually *do*
//  lives in the menu bar, so this is here to say what you're running and who
//  wrote it.
//

import SwiftUI

struct ContentView: View {
    /// Read from the bundle so MARKETING_VERSION stays the single place a release
    /// number is written down.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    private static let author = URL(string: "https://github.com/lk321")

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.rectangle.on.rectangle")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("W4llsky")
                .font(.headline)
            Text(Self.version)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 4)

            Text("Antonio Orozco")
                .font(.callout)
            if let author = Self.author {
                Link("github.com/lk321", destination: author)
                    .font(.caption)
            }

            Text("Controlled from the menu bar icon — Displays, Playback Speed, Lock Screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 320)
    }
}

#Preview {
    ContentView()
}
