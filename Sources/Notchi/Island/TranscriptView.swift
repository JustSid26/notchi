import SwiftUI

/// The selected terminal tab's recent conversation, under the island's cards.
struct TranscriptPanel: View {
    let tab: TermTab
    @ObservedObject var store: TranscriptStore
    @ObservedObject var terminals: TerminalTabs

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.06))
            content
        }
        .background(CardBackground())
    }

    private var header: some View {
        HStack(spacing: 7) {
            ClaudeStatusGlyph(state: terminals.state(of: tab)).frame(width: 13, height: 13)
            Text(tab.displayName).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
            Text(sourceLabel)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.white.opacity(0.08)))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { terminals.focus(tab) } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .help("Open in \(tab.app)")
            Button { withAnimation(.easeOut(duration: 0.15)) { terminals.selectedID = nil } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .help("Close the conversation")
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.leading, 11).padding(.trailing, 6)
        .frame(height: 32)
    }

    private var sourceLabel: String {
        switch store.source {
        case .claude: "Claude Code · last \(Self.k(store.chars)) chars"
        case .screen: "Screen"
        case .none: store.loading ? "Loading…" : "No conversation"
        }
    }

    static func k(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    @ViewBuilder private var content: some View {
        if store.items.isEmpty {
            VStack(spacing: 6) {
                if store.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "text.bubble").font(.system(size: 18)).foregroundStyle(.white.opacity(0.3))
                    Text("Nothing to show yet").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.items) { item in
                            ChatItemView(item: item).id(item.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: store.version) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }
}

struct ChatItemView: View {
    let item: ChatItem

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.95))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.islandAccent.opacity(0.3)))
            }
        case .assistant:
            Text(markdown(item.text))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.88))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            HStack(spacing: 5) {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 8.5, weight: .semibold))
                Text(item.text).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(.white.opacity(0.38))
        case .note:
            HStack(spacing: 6) {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                Text(item.text).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.35)).fixedSize()
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            }
        case .screen:
            Text(item.text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
