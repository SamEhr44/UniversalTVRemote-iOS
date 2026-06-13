import SwiftUI

/// Connects to the selected TV and walks the user through pairing.
///
/// Pairing differs by brand: LG/Samsung show an on-TV approval prompt; Vizio/
/// Android TV show a PIN the user types here. This screen renders whichever the
/// session reports via its `phase`.
struct PairingView: View {
    @ObservedObject var session: TVRemoteSession
    let store: PairedTVStore
    let device: TVDevice
    @Binding var path: [RemoteRoute]

    @State private var started = false
    @State private var code = ""
    @State private var submitting = false

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            ParticleField(count: 30)

            VStack(alignment: .leading, spacing: 0) {
                deviceCard.padding(.horizontal, 24).padding(.top, 24)
                Spacer()
                content.frame(maxWidth: .infinity)
                Spacer()
                footer.padding(24)
            }
        }
        .navigationTitle("Pair with \(device.name)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task {
            guard !started else { return }
            started = true
            await session.connect(to: device)
        }
        .onChange(of: session.phase) {
            if session.phase == .connected { Task { await finishPairing() } }
        }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .failed:
            PairingErrorView(message: session.statusMessage ?? "Pairing failed.")
        case .awaitingCode:
            codeEntry
        default:
            PairingProgressView(session: session)
        }
    }

    private var codeEntry: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard.badge.ellipsis").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Enter the code shown on your TV").font(.headline).foregroundStyle(.white)
            TextField("0000", text: $code)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 180)
                .padding(.vertical, 10)
                .glassCard(corner: 14)
            Button {
                Task { await submitCode() }
            } label: {
                Text(submitting ? "Verifying…" : "Submit code")
            }
            .buttonStyle(AccentButtonStyle(disabled: submitting || code.isEmpty))
            .disabled(submitting || code.isEmpty)
            .frame(maxWidth: 220)
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 12) {
            if session.phase == .failed {
                Button {
                    Task { started = true; await session.connect(to: device) }
                } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .buttonStyle(AccentButtonStyle())
            }
            Button(role: .cancel) { Task { await cancel() } } label: { Text("Cancel") }
                .buttonStyle(GlassButtonStyle())
            Text(tip).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var tip: String {
        switch device.resolvedBrand {
        case .lg: return "Tip: enable \"Mobile TV On\" / LG Connect Apps on the TV if pairing never prompts."
        case .samsung: return "Tip: on the TV, allow the device under General → External Device Manager if asked."
        default: return "Tip: keep the phone and TV on the same Wi-Fi network."
        }
    }

    private var deviceCard: some View {
        HStack(spacing: 16) {
            Image(systemName: device.resolvedBrand.symbol).font(.largeTitle).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(AppTheme.accent.opacity(0.25), in: Circle())
                .overlay(Circle().stroke(AppTheme.edgeHighlight, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline).foregroundStyle(.white)
                Text("\(device.ip) · \(device.resolvedBrand.displayName)")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding().glassCard(corner: 18)
    }

    // MARK: - Actions

    private func finishPairing() async {
        guard let paired = session.currentPairedDevice() else { return }
        await store.savePairedTV(paired)
        Haptics.medium()
        if !path.isEmpty { path.removeLast() }
        path.append(.remote(paired))
    }

    private func submitCode() async {
        submitting = true
        defer { submitting = false }
        do { try await session.submitPairingCode(code) }
        catch { /* phase/status already reflects failure via the session */ }
    }

    private func cancel() async {
        await session.disconnect()
        if !path.isEmpty { path.removeLast() }
    }
}

private struct PairingProgressView: View {
    @ObservedObject var session: TVRemoteSession

    var body: some View {
        let awaiting = session.phase == .awaitingApproval
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.18)).frame(width: 130, height: 130).blur(radius: 24)
                Image(systemName: awaiting ? "hand.tap.fill" : "wifi")
                    .font(.system(size: 52)).foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating)
            }
            ProgressView().tint(AppTheme.accent)
            Text(awaiting ? "Approve the remote on your TV." : "Connecting to the TV…")
                .font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
            if let message = session.statusMessage {
                Text(message).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 24)
    }
}

private struct PairingErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(AppTheme.danger)
            Text("Pairing failed").font(.headline).foregroundStyle(.white)
            Text(message).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 24)
    }
}
