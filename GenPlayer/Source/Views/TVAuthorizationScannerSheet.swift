#if os(iOS)
import AVFoundation
import SafariServices
import SwiftUI
import UIKit
import GenPlayerShell

struct TVAuthorizationScannerSheet: View {
    let onPairing: (TVAuthorizationQRCode.Pairing) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraState = CameraState.checking
    @State private var scanning = true
    @State private var message: ScanMessage?
    @State private var plexPage: PlexPage?

    private enum CameraState { case checking, ready, denied, unavailable }
    private struct ScanMessage: Identifiable {
        let id = UUID()
        let text: String
    }
    private struct PlexPage: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Group {
                    switch cameraState {
                    case .checking:
                        ProgressView()
                    case .ready:
                        QRCodeCameraView(isActive: scanning && scenePhase == .active, onCode: handleCode) {
                            cameraState = .unavailable
                        }
                        .accessibilityLabel(NSLocalizedString("Scan the authorization QR code on your TV.", comment: ""))
                    case .denied, .unavailable:
                        VStack(spacing: 16) {
                            Image(systemName: "camera")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text(NSLocalizedString(cameraState == .denied
                                ? "Allow camera access in Settings to scan TV authorization codes."
                                : "Camera unavailable. Please try again.", comment: ""))
                                .multilineTextAlignment(.center)
                            if cameraState == .denied {
                                Button(NSLocalizedString("Open Settings", comment: "")) {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }
                            } else {
                                Button(NSLocalizedString("Retry", comment: ""), action: checkCameraPermission)
                            }
                        }
                        .padding()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(NSLocalizedString("Scan the authorization QR code on your TV.", comment: ""))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(NSLocalizedString("Google Drive, OneDrive and Plex. Use the 115 App for 115 codes.", comment: ""))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .navigationTitle(NSLocalizedString("Scan QR Code", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("Cancel", comment: "")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: checkCameraPermission)
        .onChange(of: scenePhase) { phase in
            if phase == .active { checkCameraPermission() }
        }
        .alert(item: $message) { message in
            Alert(title: Text(NSLocalizedString("Scan QR Code", comment: "")), message: Text(message.text),
                  primaryButton: .default(Text(NSLocalizedString("Scan Again", comment: ""))) { scanning = true },
                  secondaryButton: .cancel(Text(NSLocalizedString("Cancel", comment: ""))) { dismiss() })
        }
        .sheet(item: $plexPage, onDismiss: { scanning = true }) { page in
            PlexAuthorizationBrowser(url: page.url)
                .ignoresSafeArea()
        }
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraState = .ready
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                DispatchQueue.main.async { cameraState = allowed ? .ready : .denied }
            }
        default:
            cameraState = .denied
        }
    }

    private func handleCode(_ code: String) {
        guard scanning else { return }
        scanning = false
        switch TVAuthorizationQRCode.parse(code) {
        case .pairing(let pairing):
            onPairing(pairing)
        case .plex(let url):
            plexPage = PlexPage(url: url)
        case .pan115:
            message = ScanMessage(text: NSLocalizedString("Please scan the QR code with 115 App", comment: ""))
        case nil:
            message = ScanMessage(text: NSLocalizedString("This QR code is not a supported TV authorization code.", comment: ""))
        }
    }
}

private struct PlexAuthorizationBrowser: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(onDone: { dismiss() }) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onDone() }
    }
}

private struct QRCodeCameraView: UIViewControllerRepresentable {
    let isActive: Bool
    let onCode: (String) -> Void
    let onFailure: () -> Void

    func makeUIViewController(context: Context) -> QRCodeCameraController {
        let controller = QRCodeCameraController()
        controller.onCode = onCode
        controller.onFailure = onFailure
        controller.setActive(isActive)
        return controller
    }
    func updateUIViewController(_ controller: QRCodeCameraController, context: Context) {
        controller.onCode = onCode
        controller.onFailure = onFailure
        controller.setActive(isActive)
    }
    static func dismantleUIViewController(_ controller: QRCodeCameraController, coordinator: ()) {
        controller.setActive(false)
    }
}

private final class QRCodeCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onFailure: (() -> Void)?
    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.genplayer.tv-qr-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var isActive = false
    private var isVisible = false
    private var didEmitCode = false
    // Access only on captureQueue.
    private var configured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
        NotificationCenter.default.addObserver(self, selector: #selector(cameraFailed),
            name: AVCaptureSession.runtimeErrorNotification, object: captureSession)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        updateCapture()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        updateCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        if let connection = preview?.connection, connection.isVideoOrientationSupported,
           let orientation = view.window?.windowScene?.interfaceOrientation {
            switch orientation {
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            default: connection.videoOrientation = .portrait
            }
        }
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { didEmitCode = false }
        updateCapture()
    }

    private func updateCapture() {
        let shouldRun = isActive && isVisible
        captureQueue.async { [self] in
            if shouldRun {
                if !configured {
                    guard configureCapture() else {
                        cameraFailed()
                        return
                    }
                    configured = true
                    DispatchQueue.main.async { [weak self] in
                        self?.view.setNeedsLayout()
                    }
                }
                if !captureSession.isRunning { captureSession.startRunning() }
            } else if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    private func configureCapture() -> Bool {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else { return false }
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        guard captureSession.canAddInput(input) else { return false }
        captureSession.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else { return false }
        captureSession.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        return true
    }

    @objc private func cameraFailed() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.isVisible else { return }
            self.onFailure?()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard isActive, isVisible, !didEmitCode,
              let value = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        didEmitCode = true
        setActive(false)
        onCode?(value)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        let session = captureSession
        captureQueue.async { if session.isRunning { session.stopRunning() } }
    }
}
#endif
