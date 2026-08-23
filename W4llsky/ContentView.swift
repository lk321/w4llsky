     //
//  ContentView.swift
//  W4llsky
//
//  Created by Antonio Orozco on 22/08/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.rectangle.on.rectangle")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("W4llsky")
                .font(.headline)
            Text("Controlled from the menu bar icon — Displays, Playback Speed, Lock Screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(width: 320)
    }
}

#Preview {
    ContentView()
}
