import SwiftUI

/// Connects to the selected TV and walks the user through pairing.
///
/// If the device already has a stored client-key, the TV should register
/// silently and we go straight to the remote. Otherwise the TV shows an
/// on-screen prompt that the user must accept.
struct PairingView: View {
    @ObservedObject var lg: LGWebOSService
    let store: PairedTVStore
    let device: TVDevice
    @Binding var path: [RemoteRoute]

    @State private var errorMessage: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            deviceCard
                .padding(.horizontal, 24)
                .padding(.top, 24)

            Spacer()

            Group {
                if let errorMessage {
                    PairingErrorView(message: errorMessage)
                } else {
                    PairingProgressView(lg: lg)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()

            VStack(spacing: 12) {
                if errorMessage != nil {
                    Button {
                        Task { await startPairing() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                }

                Button(role: .cancel) {
                    Task { await cancel() }
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)

                Text("Tip: enable \"Mobile TV On\" / LG Connect Apps on the TV if pairing "
                    + "never prompts.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .navigationTitle("Pair with \(device.name)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task { await startPairing() }
    }

    private var deviceCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "tv").font(.largeTitle)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline)
                Text(device.ip).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func startPairing() async {
        busy = true
        errorMessage = nil

        do {
            let clientKey = try await lg.connectAndRegister(
                ip: device.ip,
                clientKey: device.clientKey
            )

            // Best-effort: learn the TV's MAC so we can Wake-on-LAN it later.
            let mac = try? await lg.fetchMacAddress()

            // Persist the (possibly new) client-key for future silent reconnects.
            let paired = device.copyWith(
                clientKey: clientKey,
                macAddress: mac,
                lastConnectedAt: isoNow()
            )
            await store.savePairedTV(paired)

            // Replace this screen with the remote so Back returns to the scan list.
            if !path.isEmpty { path.removeLast() }
            path.append(.remote(paired))
        } catch {
            errorMessage = friendly(error)
            busy = false
        }
    }

    private func cancel() async {
        await lg.disconnect()
        if !path.isEmpty { path.removeLast() }
    }

    private func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.isEmpty ? "Pairing failed." : text
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}

/// Live pairing progress driven by the service's pairing/status state.
private struct PairingProgressView: View {
    @ObservedObject var lg: LGWebOSService

    var body: some View {
        let promptShown = lg.pairingState == .promptShown
        VStack(spacing: 16) {
            ProgressView()
            Image(systemName: promptShown ? "hand.tap" : "wifi")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(promptShown
                ? "Accept the pairing request on your LG TV."
                : "Connecting to the TV…")
                .font(.headline)
                .multilineTextAlignment(.center)
            if let message = lg.statusMessage {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
    }
}

private struct PairingErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Pairing failed").font(.headline)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }
}
