import SwiftUI
import AVFoundation
import VisionKit

/// an addon's install QR read in place with the camera (VisionKit's data
/// scanner, QR only). The first readable code ends the scan with its text. Where there is no camera
/// to use (the simulator, an older phone, camera access turned off, a restriction) it says so and
/// points at Settings, and the link can still be pasted.
struct PhoneQRScanner: View {
    let onFound: (String) -> Void
    let close: () -> Void

    private enum Access { case checking, ready, denied, unavailable }
    @State private var access: Access = .checking
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                switch access {
                case .checking:
                    ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    PhoneDataScanner(onFound: onFound)
                        .ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            Text(T("Point the camera at the addon's install QR code."))
                                .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                                .foregroundStyle(BP.ink)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .glassEffect(.regular, in: .capsule)
                                .padding(.bottom, 30)
                        }
                case .denied, .unavailable:
                    unavailable
                }
            }
            .background(PhoneBackground())
            .navigationTitle(T("Scan QR code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(T("Cancel"), action: close).accessibilityIdentifier("addon-scan-cancel")
                }
            }
        }
        .task { access = await Self.checkAccess() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addon-scanner")
    }

    private var unavailable: some View {
        let openSettings: (() -> Void)? = access == .denied ? {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        } : nil
        return VStack {
            EmptyState(title: T("Camera unavailable"),
                       message: access == .denied
                           ? T("Harbor isn't allowed to use the camera. Turn it on in Settings, or paste the addon's link instead.")
                           : T("This device can't scan QR codes here. Paste the addon's link instead."),
                       systemImage: "camera.badge.ellipsis",
                       actionTitle: openSettings == nil ? nil : T("Open Settings"),
                       action: openSettings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addon-scan-unavailable")
    }

    /// Whether the scanner can run: a supported device, camera access granted (asked once), and no
    /// restriction. The simulator has no data scanner.
    private static func checkAccess() async -> Access {
        guard DataScannerViewController.isSupported else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        case .denied: return .denied
        default: return .unavailable
        }
        return DataScannerViewController.isAvailable ? .ready : .unavailable
    }
}

/// VisionKit's DataScannerViewController for QR codes; reports the first code with a text payload.
private struct PhoneDataScanner: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced,
                                                recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var done = false

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            found(in: addedItems)
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            found(in: [item])
        }

        private func found(in items: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                guard case .barcode(let code) = item, let text = code.payloadStringValue, !text.isEmpty else { continue }
                done = true
                PhoneFeedback.shared.success()
                onFound(text)
                return
            }
        }
    }
}
