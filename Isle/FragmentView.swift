//
//  FragmentView.swift
//  Isle
//

import SwiftUI
import Combine

/// Drives the open/close animation. Toggled by the fn key in AppDelegate.
final class IslandState: ObservableObject {
    @Published var isOpen = false
}

/// A standalone Dynamic Island-style pill that springs out from under the
/// notch, showing a live "listening" indicator while recording.
///
/// The hosting panel is taller than the pill (`topRoom` of empty space above)
/// so the emerge animation can travel upward without being clipped.
struct FragmentView: View {
    @ObservedObject var state: IslandState
    var pillSize: CGSize
    var topRoom: CGFloat
    var onQuit: () -> Void

    var body: some View {
        ListeningIndicator(active: state.isOpen)
            .frame(width: pillSize.width, height: pillSize.height)
            .background(.black, in: Capsule(style: .continuous))
            // Grow downward from the top edge so it reads as emerging from the notch.
            .scaleEffect(state.isOpen ? 1 : 0.3, anchor: .top)
            .offset(y: state.isOpen ? 0 : -20)
            .opacity(state.isOpen ? 1 : 0)
            .padding(.top, topRoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.spring(response: 0.34, dampingFraction: 0.7), value: state.isOpen)
            .contextMenu { Button("Quit Isle", action: onQuit) }
    }
}

/// A pulsing teal dot + "Listening" label, conveying live mic capture.
/// The dot gently breathes while a soft ring pings outward — subtle, not blinky.
private struct ListeningIndicator: View {
    /// Only animates while the island is open (i.e. actually recording).
    var active: Bool

    private let tint = Color(red: 0.20, green: 0.80, blue: 0.80)

    @State private var ping = false

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                // Filled disc that expands outward from the core and fades.
                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)
                    .scaleEffect(ping ? 2.3 : 1)
                    .opacity(ping ? 0 : 0.5)
                // Core dot — constant.
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 9, height: 9)
            .shadow(color: tint.opacity(0.7), radius: 5)

            Text("Listening")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        }
        .onChange(of: active, initial: true) { _, isActive in
            if isActive {
                withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    ping = true
                }
            } else {
                ping = false
            }
        }
    }
}

#Preview {
    let state = IslandState()
    state.isOpen = true
    return FragmentView(
        state: state,
        pillSize: CGSize(width: 150, height: 40),
        topRoom: 30,
        onQuit: {}
    )
    .frame(width: 240, height: 90)
    .background(.gray)
}
