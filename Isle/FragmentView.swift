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
/// notch, showing the live time with seconds.
///
/// The hosting panel is taller than the pill (`topRoom` of empty space above)
/// so the emerge animation can travel upward without being clipped.
struct FragmentView: View {
    @ObservedObject var state: IslandState
    var pillSize: CGSize
    var topRoom: CGFloat
    var onQuit: () -> Void

    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        timeText
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
            .onReceive(clock) { now = $0 }
    }

    private var timeText: some View {
        Text(now, format: .dateTime
            .hour(.twoDigits(amPM: .omitted))
            .minute(.twoDigits)
            .second(.twoDigits))
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText())
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
