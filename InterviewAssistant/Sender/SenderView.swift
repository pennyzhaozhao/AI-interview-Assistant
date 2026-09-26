import SwiftUI
import SwiftData

struct SenderView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppPreferenceKey.language) private var language = AppLanguage.english.rawValue
    @State private var server = TCPLineServer()
    @State private var localIP = "检测中..."
    @State private var allAddresses: [LocalNetworkInfo.Address] = []
    @State private var text = ""
    @State private var sentHistory: [SentHistoryItem] = []
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            Color.appBG
                .ignoresSafeArea()

            Group {
                if isCompact {
                    compactBody
                } else {
                    regularBody
                }
            }
        }
        .background(Color.appBG.ignoresSafeArea(.all))
        .environment(\.locale, currentLanguage.locale)
        .onAppear {
            localIP = LocalNetworkInfo.preferredIPAddress()
            allAddresses = LocalNetworkInfo.allAddresses()
            server.start()
        }
        .onDisappear { server.stop() }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            compactConnectionHeader
            compactHistory
        }
        .padding(.horizontal, 16)
        .padding(.top, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom) {
            compactComposer
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button(L.t("Clear")) {
                    text = ""
                }
                Spacer()
                Button(L.t("Done")) {
                    inputFocused = false
                }
                Button(L.t("Send")) {
                    send()
                    inputFocused = false
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var regularBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ipPanel(compact: false)
            historyPanel(minHeight: 150, maxHeight: 200)
            inputPanel(height: 150)
            actionRow
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .premiumCard()
        .padding(32)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L.t("Prompt Sender"))
                .font(.appSection)
                .foregroundStyle(Color.appText)
                .padding(.leading, 16)
            Spacer(minLength: 10)
            statusBadge
        }
        .padding(isCompact ? 14 : 0)
        .background(isCompact ? Color.appPanel : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay {
            if isCompact {
                RoundedRectangle(cornerRadius: AppRadius.card).stroke(Color.appBorder)
            }
        }
    }

    private var compactConnectionHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("Prompt Sender"))
                        .font(.appSection)
                        .foregroundStyle(Color.appText)
                        .padding(.leading, 16)
                    Text(L.t("Enter this IP on the interview receiver."))
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                }
                Spacer()
                statusBadge
            }

            HStack(spacing: 8) {
                ipAddress
                portBadge
            }
            if LocalNetworkInfo.wifiIPAddress() == nil {
                Text(L.t("No Wi-Fi IP detected. Keep iPhone and Mac on the same Wi-Fi and avoid cellular addresses."))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appDanger)
            } else if let other = allAddresses.first(where: { $0.interface != "en0" && $0.ip == localIP }) {
                Text("\(L.t("Currently showing")) \(other.interface). \(L.t("Switch to Wi-Fi and try again."))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appDanger)
            } else if !allAddresses.isEmpty {
                Text("Wi-Fi en0 · \(localIP)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appMuted)
            }
        }
        .premiumCard(padding: 16)
    }

    private var compactHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            historyHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if sentHistory.isEmpty {
                        Text(L.t("No messages sent yet"))
                            .font(.appBodyMedium)
                            .foregroundStyle(Color.appMuted)
                            .frame(maxWidth: .infinity, minHeight: 128, alignment: .center)
                    } else {
                        ForEach(sentHistory) { item in
                            historyRow(item)
                        }
                    }
                }
                .padding(10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: 200, alignment: .top)
        .premiumCard(padding: 0)
    }

    private var compactComposer: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L.t("Enter prompt..."), text: $text, axis: .vertical)
                    .focused($inputFocused)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.appText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(minHeight: 44)
                    .background(Color.appField)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder))
                    .submitLabel(.send)
                    .onSubmit {
                        send()
                        inputFocused = false
                    }

                Button(L.t("Send")) {
                    send()
                    inputFocused = false
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appBG)
                .frame(minWidth: 72, minHeight: 44)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }

            HStack {
                Button(L.t("Clear")) {
                    server.sendLine(" ")
                    text = ""
                    inputFocused = false
                }
                .font(.system(size: 15, weight: .medium))
                .frame(minHeight: 40)
                .buttonStyle(AppButtonStyle())
                Spacer()
                Button(L.t("Dismiss Keyboard")) {
                    inputFocused = false
                }
                .font(.system(size: 15, weight: .medium))
                .frame(minHeight: 40)
                .buttonStyle(AppButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(Color.appPanel)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.appBorder), alignment: .top)
    }

    private func ipPanel(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.t("Receiver IP"))
                .font(.appCaptionMedium)
                .foregroundStyle(Color.appMuted)
                .padding(.leading, 16)
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    ipAddress
                    portBadge
                }
            } else {
                HStack(spacing: 10) {
                    ipAddress
                    portBadge
                }
            }
        }
        .padding(compact ? 14 : 0)
        .background(compact ? Color.appPanel : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay {
            if compact {
                RoundedRectangle(cornerRadius: AppRadius.card).stroke(Color.appBorder)
            }
        }
    }

    private var ipAddress: some View {
        Text(localIP)
            .font(.system(size: isCompact ? 17 : 24, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .allowsTightening(true)
            .foregroundStyle(Color.appYellow)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.appField)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.input))
    }

    private var portBadge: some View {
        Text("\(L.t("Port")) 9999")
            .font(.system(size: isCompact ? 15 : 13, weight: .medium))
            .foregroundStyle(Color.appGreen)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.appField)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.input))
    }

    private func historyPanel(minHeight: CGFloat, maxHeight: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            historyHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if sentHistory.isEmpty {
                        Text(L.t("No messages sent yet"))
                            .foregroundStyle(Color.appMuted)
                            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
                    } else {
                        ForEach(sentHistory) { item in
                            historyRow(item)
                        }
                    }
                }
            }
            .frame(minHeight: minHeight, maxHeight: maxHeight ?? (isCompact ? 150 : nil))
            .background(Color.appField)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.input))
        }
        .padding(isCompact ? 14 : 0)
        .background(isCompact ? Color.appPanel : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay {
            if isCompact {
                RoundedRectangle(cornerRadius: AppRadius.card).stroke(Color.appBorder)
            }
        }
    }

    private var historyHeader: some View {
        HStack {
            Text(L.t("Send History"))
                .font(.appCaptionMedium)
                .foregroundStyle(Color.appMuted)
            Spacer()
            if !sentHistory.isEmpty {
                Button(L.t("Clear History")) {
                    sentHistory.removeAll()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appDanger)
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.appField)
                .clipShape(Capsule())
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
    }

    private func inputPanel(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("Prompt"))
                .font(.appCaptionMedium)
                .foregroundStyle(Color.appMuted)
                .padding(.leading, 16)
            TextEditor(text: $text)
                .focused($inputFocused)
                .scrollContentBackground(.hidden)
                .frame(minHeight: height)
                .darkField()
        }
        .padding(isCompact ? 14 : 0)
        .background(isCompact ? Color.appPanel : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if isCompact {
                RoundedRectangle(cornerRadius: 8).stroke(Color.appBorder)
            }
        }
    }

    private var actionRow: some View {
        HStack {
            Button(L.t("Clear")) {
                server.sendLine(" ")
                text = ""
                inputFocused = false
            }
            .buttonStyle(AppButtonStyle())
            Spacer()
            Button(L.t("Send")) {
                send()
                inputFocused = false
            }
            .buttonStyle(AppButtonStyle(prominent: true))
        }
        .padding(.horizontal, isCompact ? 2 : 0)
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.system(size: isCompact ? 12 : 12, weight: .semibold))
            .foregroundStyle(server.isRunning ? Color.appGreen : Color.appDanger)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.appField)
            .clipShape(Capsule())
    }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var currentLanguage: AppLanguage {
        AppLanguage(rawValue: language) ?? .english
    }

    private var statusText: String {
        if !server.isRunning { return L.t("Not Listening") }
        if server.clientCount > 0 { return "\(server.clientCount) \(L.t("connected"))" }
        return L.t("Waiting for connection")
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard server.clientCount > 0 else {
            sentHistory.insert(SentHistoryItem(text: "\(L.t("Receiver not connected")): \(trimmed)"), at: 0)
            return
        }
        server.sendLine(trimmed)
        sentHistory.insert(SentHistoryItem(text: trimmed), at: 0)
        if sentHistory.count > 50 { sentHistory.removeLast() }
        text = ""
    }

    private func historyRow(_ item: SentHistoryItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.text)
                .font(.system(size: 14))
                .foregroundStyle(Color.appYellow)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.timestamp, format: .dateTime.hour().minute())
                .font(.system(size: 12))
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(10)
        .background(Color.appField)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SentHistoryItem: Identifiable {
    let id = UUID()
    let text: String
    let timestamp = Date()
}
