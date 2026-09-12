import Combine
import SwiftUI
import UIKit

struct ManuscriptView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var conversation = MobileConversation()
    @State private var draft = ""
    @State private var isComposerFocused = true
    @State private var followsLatestResponse = true

    var body: some View {
        Group {
            if conversation.turns.isEmpty {
                VStack(alignment: .leading) {
                    ComposerInput(
                        text: $draft,
                        isFocused: $isComposerFocused,
                        placeholder: "Ask anything…",
                        fontSize: 20,
                        onSubmit: submit
                    )

                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.top, 32)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(conversation.turns) { turn in
                                ManuscriptTurn(
                                    turn: turn,
                                    activity: turn.id == conversation.turns.last?.id && turn.answer == nil
                                        ? conversation.activity
                                        : nil
                                )
                                .padding(.bottom, 42)
                            }

                            ComposerInput(
                                text: $draft,
                                isFocused: $isComposerFocused,
                                placeholder: "Follow up…",
                                fontSize: 20,
                                onSubmit: submit
                            )

                            Color.clear
                                .frame(height: 36)
                                .id("bottom")
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 32)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        let distanceFromBottom = geometry.contentSize.height
                            - geometry.contentOffset.y
                            - geometry.containerSize.height
                        return distanceFromBottom < 96
                    } action: { _, isNearBottom in
                        followsLatestResponse = isNearBottom
                    }
                    .onChange(of: conversation.turns.count) {
                        followsLatestResponse = true
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: conversation.turns.last?.answer) {
                        guard followsLatestResponse else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: UIResponder.keyboardWillShowNotification
                        )
                    ) { notification in
                        guard isComposerFocused else { return }
                        withAnimation(keyboardAnimation(for: notification)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isComposerFocused = false
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { isComposerFocused = true }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            conversation.startNewThreadIfIdle()
        }
    }

    private func submit() {
        guard conversation.submit(draft) else { return }
        draft = ""
    }

    private func keyboardAnimation(for notification: Notification) -> Animation {
        let userInfo = notification.userInfo
        let duration = (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
            .doubleValue ?? 0.25
        let curveValue = (userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?
            .intValue ?? UIView.AnimationCurve.easeInOut.rawValue

        switch UIView.AnimationCurve(rawValue: curveValue) {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        case .linear:
            return .linear(duration: duration)
        default:
            return .easeInOut(duration: duration)
        }
    }
}

private struct ManuscriptTurn: View {
    let turn: ConversationTurn
    let activity: MobileAgentActivity?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(turn.question)
                .font(.system(size: 20, weight: .regular, design: .serif))
                .foregroundStyle(.white)
                .lineSpacing(5)

            Group {
                if let answer = turn.answer {
                    MarkdownText(markdown: answer)
                        .contentTransition(.opacity)
                } else {
                    AgentActivityRow(
                        activity: activity ?? MobileAgentActivity(
                            id: 0,
                            icon: "ellipsis",
                            label: "Thinking…"
                        )
                    )
                    .id(activity?.id ?? 0)
                    .transition(.blurReplace)
                }
            }
        }
    }
}

private struct AgentActivityRow: View {
    let activity: MobileAgentActivity

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: activity.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16)
                .symbolEffect(.variableColor.iterative, options: .repeating)

            Text(activity.label)
                .font(.system(size: 14, weight: .regular, design: .serif))
                .foregroundStyle(.white.opacity(0.7))

            Spacer(minLength: 0)
        }
    }
}

private struct ComposerInput: View {
    @Binding var text: String
    @Binding var isFocused: Bool

    let placeholder: String
    let fontSize: CGFloat
    let onSubmit: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            SubmitTextView(
                text: $text,
                isFocused: $isFocused,
                fontSize: fontSize,
                onSubmit: onSubmit
            )

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize, design: .serif))
                    .foregroundStyle(.white.opacity(0.35))
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct SubmitTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    let fontSize: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.tintColor = .white
        textView.font = serifFont(size: fontSize)
        textView.isScrollEnabled = false
        textView.returnKeyType = .send
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        if textView.text != text {
            textView.text = text
        }

        textView.font = serifFont(size: fontSize)

        if isFocused, !textView.isFirstResponder {
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
            }
        } else if !isFocused, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: min(max(fittingSize.height, fontSize + 8), 180))
    }

    private func serifFont(size: CGFloat) -> UIFont {
        let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
        return descriptor.map { UIFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SubmitTextView

        init(parent: SubmitTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText: String
        ) -> Bool {
            guard replacementText == "\n" else { return true }
            parent.onSubmit()
            return false
        }
    }
}
