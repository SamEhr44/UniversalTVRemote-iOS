import SwiftUI

/// Placeholder scaffold. Replaced with the full discovery UI in a later commit.
struct ScanView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "tv")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("Universal TV Remote")
                    .font(.title2.bold())
                Text("Project scaffold — functionality coming online.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("TV Remote")
        }
    }
}

#Preview {
    ScanView()
}
