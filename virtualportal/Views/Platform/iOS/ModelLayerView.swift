//
//  ModelLayerView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/16/25.
//

#if os(iOS)
import SwiftUI
import Photos
import RealityKit
import ARKit
@preconcurrency import CoreVideo
import AVFoundation
import Metal
import Foundation

/// Wrapper to make CVPixelBuffer sendable across concurrency boundaries
/// This is safe because CVPixelBuffer is internally thread-safe for reading
private struct UncheckedSendable<T>: @unchecked Sendable {
    nonisolated(unsafe) let value: T
}

// Add an async snapshotter typealias for clarity
typealias ARSnapshotter = (@escaping (UIImage?) -> Void) -> Void

/// Top-level view for iOS: Camera preview with a USDZ model and camera controls.
struct ModelLayerView: View {
    // MARK: - ViewModels
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var arViewModel = ARViewModel()
    @StateObject private var modelController = CharacterModelController.shared
    
    // MARK: - UI State
    @State private var hideControls: Bool = false
    @State private var thumbnail: UIImage? = nil
    @State private var capturedImage: UIImage? = nil
    @State private var showPhotoPreview: Bool = false
    @State private var showSettings: Bool = false
    @State private var snapshotter: ARSnapshotter?

    var body: some View {
        NavigationStack {
            ZStack {
                // RealityKit view provides both the camera background and the model
                RealityKitARView(
                    modelName: settingsViewModel.usdzModelName,
                    modelScale: settingsViewModel.modelScale,
                    applyCustomShader: settingsViewModel.applyCustomShader,
                    objectOcclusionEnabled: settingsViewModel.objectOcclusionEnabled,
                    snapshotter: $snapshotter,
                    isIndicatorVisible: $arViewModel.isIndicatorVisible,
                    indicatorPosition: $arViewModel.indicatorPosition,
                    indicatorAngle: $arViewModel.indicatorAngle
                )

                // Off-screen indicator
                OffscreenIndicatorView(
                    isVisible: $arViewModel.isIndicatorVisible,
                    position: $arViewModel.indicatorPosition,
                    angle: $arViewModel.indicatorAngle
                )

                // Camera controls
                VStack {
                    Spacer()
                    CameraControlsView(
                        hideControls: $hideControls,
                        thumbnail: thumbnail,
                        showFlip: false,
                        onThumbnailTap: {
                            if capturedImage != nil {
                                showPhotoPreview = true
                            }
                        }
                    )
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .ignoresSafeArea()
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                
                // Start conversation pipeline after onboarding is complete
                Task { @MainActor in
                    // Small delay to allow AR to initialize
                    try? await Task.sleep(for: .seconds(1))
                    print("Initializing conversation pipeline...")
                    ConversationManager.shared.start()
                }
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                // Clean up resources properly
                Task { @MainActor in
                    modelController.reset()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("virtualportal.cameraCaptureRequested"))) { _ in
                // Capture on main actor to avoid crashes
                Task { @MainActor in
                    guard let snapshotter = snapshotter else {
                        print("Snapshotter not ready")
                        return
                    }
                    
                        // Ensure we're not already processing a capture
                        guard thumbnail == nil || !showPhotoPreview else {
                        print("Already processing a capture")
                        return
                    }
                    
                        // Trigger snapshot - wrap in try-catch equivalent
                        snapshotter { capturedImage in
                        // This callback runs on background queue from ARView
                        guard let capturedImage = capturedImage else {
                            print("Snapshot failed (nil image)")
                            return
                        }
                        
                        // Must dispatch to main queue before posting notification
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: Notification.Name("virtualportal.photoCapturerCompleted"),
                                object: nil,
                                userInfo: ["image": capturedImage]
                            )
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("virtualportal.photoCapturerCompleted"))) { notification in
                guard let image = notification.userInfo?["image"] as? UIImage else { return }
                
                Task { @MainActor in
                    await handleCapture(image: image)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showPhotoPreview) {
            if let image = capturedImage {
                PhotoPreviewView(image: image, isPresented: $showPhotoPreview)
            }
        }
    }
    
    @MainActor
    private func handleCapture(image: UIImage) async {
        // Create square thumbnail for display (no black bars)
        self.thumbnail = cropToSquare(image: image)
        // Store full image for preview
        self.capturedImage = image
        // Show photo preview
        self.showPhotoPreview = true
        // Save the full original image to photo library
        await saveToPhotoLibrary(image: image)
    }
    
    @MainActor
    private func cropToSquare(image: UIImage) -> UIImage {
        let originalWidth = image.size.width
        let originalHeight = image.size.height
        let minDimension = min(originalWidth, originalHeight)
        
        let cropRect = CGRect(
            x: (originalWidth - minDimension) / 2,
            y: (originalHeight - minDimension) / 2,
            width: minDimension,
            height: minDimension
        )
        
        guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
            return image
        }
        
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private func saveToPhotoLibrary(image: UIImage) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                if let error = error { print("PhotoLibrary save error: \(error)") }
            }
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                if newStatus == .authorized || newStatus == .limited {
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }) { success, error in
                        if let error = error { print("PhotoLibrary save error: \(error)") }
                    }
                }
            }
        default:
            break
        }
    }
}

// MARK: - RealityKit AR view using centralized controller
private struct RealityKitARView: UIViewRepresentable {
    let modelName: String
    let modelScale: Double
    let applyCustomShader: Bool
    let objectOcclusionEnabled: Bool
    @Binding var snapshotter: ARSnapshotter?
    @Binding var isIndicatorVisible: Bool
    @Binding var indicatorPosition: CGPoint
    @Binding var indicatorAngle: Angle
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        // Store ARView reference in coordinator for capturing
        context.coordinator.arView = arView
        
        // Keep delegate on main queue to avoid actor isolation issues
        // Throttling in delegate method prevents performance issues
        arView.session.delegate = context.coordinator
        // Note: delegateQueue defaults to main queue when not set
        
        Task { @MainActor in
            CharacterModelController.shared.configureARView(arView)
        }
        
        // Add coaching overlay for user guidance
        let coachingOverlay = ARCoachingOverlayView()
        coachingOverlay.session = arView.session
        coachingOverlay.goal = .horizontalPlane
        coachingOverlay.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(coachingOverlay)
        NSLayoutConstraint.activate([
            coachingOverlay.centerXAnchor.constraint(equalTo: arView.centerXAnchor),
            coachingOverlay.centerYAnchor.constraint(equalTo: arView.centerYAnchor),
            coachingOverlay.widthAnchor.constraint(equalTo: arView.widthAnchor),
            coachingOverlay.heightAnchor.constraint(equalTo: arView.heightAnchor)
        ])
        
        context.coordinator.setup(
            modelName: modelName,
            modelScale: modelScale,
            applyCustomShader: applyCustomShader,
            objectOcclusionEnabled: objectOcclusionEnabled,
            isIndicatorVisible: $isIndicatorVisible,
            indicatorPosition: $indicatorPosition,
            indicatorAngle: $indicatorAngle
        )
        
        DispatchQueue.main.async {
            let coordinator = context.coordinator
            let hdrEnabled = UserDefaults.standard.bool(forKey: "arHDREnabled")
            snapshotter = { [weak coordinator] completion in
                guard let arView = coordinator?.arView else {
                    completion(nil)
                    return
                }
                arView.snapshot(saveToHDR: hdrEnabled) { image in
                    completion(image)
                }
            }
        }
        
        return arView
    }
    
    func updateUIView(_ arView: ARView, context: Context) {
        context.coordinator.arView = arView
        context.coordinator.update(
            modelName: modelName,
            modelScale: modelScale,
            applyCustomShader: applyCustomShader,
            objectOcclusionEnabled: objectOcclusionEnabled,
            isIndicatorVisible: $isIndicatorVisible,
            indicatorPosition: $indicatorPosition,
            indicatorAngle: $indicatorAngle
        )
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    static func dismantleUIView(_ arView: ARView, coordinator: Coordinator) {
        // Pause AR session to release memory
        arView.session.pause()
        
        // Remove all anchors
        arView.scene.anchors.removeAll()
        
        // Clean up coordinator
        coordinator.cleanup()
    }
}

// MARK: - Coordinator for ARView
// Main actor isolated - delegate runs on main queue with throttling to prevent performance issues
@MainActor
class Coordinator: NSObject, ARSessionDelegate {
    var arView: ARView?
    
    // Model state - accessed only from main thread
    private var currentModelName: String = ""
    private var currentModelScale: Double = 1.0
    private var currentApplyCustomShader: Bool = false
    private var currentObjectOcclusionEnabled: Bool = false
    
    // Off-screen indicator bindings
    private var isIndicatorVisible: Binding<Bool>?
    private var indicatorPosition: Binding<CGPoint>?
    private var indicatorAngle: Binding<Angle>?
    
    // Memory warning observer - marked nonisolated for deinit access
    nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?
    
    // VLM frame throttling - match VLM processing interval (5 seconds default)
    private var lastVLMFrameTime: CFTimeInterval = 0
    private let minVLMFrameInterval: CFTimeInterval = 5.0 // Send frames at VLM processing rate
    
    // UI indicator throttling - update every 10 frames (~6 FPS at 60 FPS)
    private var indicatorFrameCounter: Int = 0
    private let indicatorFrameSkip: Int = 10
    
    override init() {
        super.init()
        
        // Listen for memory warnings and pause AR session to free resources
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }
    
    deinit {
        // Remove observer first - safe because memoryWarningObserver is nonisolated(unsafe)
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Cleanup will be handled by SwiftUI when coordinator is deallocated
        // No need to explicitly call cleanup in deinit
    }
    
    nonisolated private func handleMemoryWarning() {
        print("⚠️ Memory warning received - aggressively freeing resources")
        Task { @MainActor in
            // Pause AR session immediately
            self.arView?.session.pause()
            
            // Free VLM cached textures and resources
            await VLMModelManager.shared.clearCache()
            
            // Force garbage collection
            autoreleasepool { }
            
            // Resume after memory is freed
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            guard let arView = self.arView else { return }
            let config = CharacterModelController.shared.createARConfiguration()
            arView.session.run(config, options: [])
            print("✅ AR session resumed after memory warning")
        }
    }
    
    func cleanup() {
        if let arView = arView {
            arView.session.pause()
        }
        arView = nil
        isIndicatorVisible = nil
        indicatorPosition = nil
        indicatorAngle = nil
    }
    
    func setup(
        modelName: String,
        modelScale: Double,
        applyCustomShader: Bool,
        objectOcclusionEnabled: Bool,
        isIndicatorVisible: Binding<Bool>,
        indicatorPosition: Binding<CGPoint>,
        indicatorAngle: Binding<Angle>
    ) {
        currentModelName = modelName
        currentModelScale = modelScale
        currentApplyCustomShader = applyCustomShader
        currentObjectOcclusionEnabled = objectOcclusionEnabled
        
        self.isIndicatorVisible = isIndicatorVisible
        self.indicatorPosition = indicatorPosition
        self.indicatorAngle = indicatorAngle
        
        CharacterModelController.shared.updateModel(modelName: modelName, modelScale: modelScale, applyCustomShader: applyCustomShader)
        CharacterModelController.shared.updateObjectOcclusion(enabled: objectOcclusionEnabled)
    }
    
    func update(
        modelName: String,
        modelScale: Double,
        applyCustomShader: Bool,
        objectOcclusionEnabled: Bool,
        isIndicatorVisible: Binding<Bool>,
        indicatorPosition: Binding<CGPoint>,
        indicatorAngle: Binding<Angle>
    ) {
        self.isIndicatorVisible = isIndicatorVisible
        self.indicatorPosition = indicatorPosition
        self.indicatorAngle = indicatorAngle
        
        let modelChanged = currentModelName != modelName
        let scaleChanged = currentModelScale != modelScale
        let shaderChanged = currentApplyCustomShader != applyCustomShader
        let occlusionChanged = currentObjectOcclusionEnabled != objectOcclusionEnabled
        
        if modelChanged {
            currentModelName = modelName
            currentModelScale = modelScale
            currentApplyCustomShader = applyCustomShader
            
            CharacterModelController.shared.updateModel(modelName: modelName, modelScale: modelScale, applyCustomShader: applyCustomShader)
        } else if scaleChanged {
            currentModelScale = modelScale
            CharacterModelController.shared.updateModelScale(modelScale)
        }
        
        if shaderChanged {
            currentApplyCustomShader = applyCustomShader
            CharacterModelController.shared.updateShader(applyCustomShader)
        }
        
        if occlusionChanged {
            currentObjectOcclusionEnabled = objectOcclusionEnabled
            CharacterModelController.shared.updateObjectOcclusion(enabled: objectOcclusionEnabled)
        }
    }
    
    func captureSnapshot() -> UIImage? {
        guard let arView = arView else {
            print("⚠️ ARView is nil, cannot capture snapshot")
            return nil
        }
        
        // Must be called on main thread
        guard Thread.isMainThread else {
            print("⚠️ captureSnapshot called off main thread - returning nil")
            return nil
        }
        
        let renderer = UIGraphicsImageRenderer(bounds: arView.bounds)
        let image = renderer.image { context in
            arView.drawHierarchy(in: arView.bounds, afterScreenUpdates: true)
        }
        print("✅ Captured snapshot: \(image.size)")
        return image
    }
    
    // MARK: - ARSessionDelegate (runs on main queue)
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // Process plane anchors - already on main queue
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                CharacterModelController.shared.handlePlaneDetection(
                    planeAnchor,
                    modelName: currentModelName,
                    modelScale: currentModelScale,
                    applyCustomShader: currentApplyCustomShader
                )
            }
        }
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Process plane updates - already on main queue
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                CharacterModelController.shared.updatePlaneAnchor(
                    planeAnchor,
                    modelName: currentModelName,
                    modelScale: currentModelScale,
                    applyCustomShader: currentApplyCustomShader
                )
            }
        }
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Every frame: VLM and occlusion processing
        // Object occlusion runs at full frame rate automatically via RealityKit
        // CRITICAL: Don't retain ARFrame - extract and convert immediately
        let currentTime = CACurrentMediaTime()
        
        // Skip VLM processing while loading model to reduce resource contention
        guard !CharacterModelController.shared.isLoadingModel else { return }
        
        // VLM frame processing - throttled to prevent ARFrame retention
        if currentTime - lastVLMFrameTime >= minVLMFrameInterval {
            // CRITICAL: Skip if VLM is still processing to prevent frame buildup
            guard !VLMModelManager.shared.isProcessing else {
                // VLM is busy - skip this frame entirely to prevent retention
                return
            }
            
            lastVLMFrameTime = currentTime
            
            // CRITICAL: Convert to CGImage immediately within autoreleasepool
            // This breaks the reference to ARFrame before any async work
            let pixelBuffer = frame.capturedImage
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

            // Downscale immediately to reduce memory footprint
            let scale = 480.0 / max(ciImage.extent.width, ciImage.extent.height)
            let scaledImage = scale < 1.0 ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ciImage

            // If the app is backgrounded, skip processing to avoid submitting GPU work
            #if os(iOS)
            if UIApplication.shared.applicationState != .active {
                // Skip heavy work while backgrounded
                return
            }
            #endif

            // Create CGImage on main actor so any Metal-backed CIContext work runs from the main thread
            let extent = scaledImage.extent
            Task {
                let cgImage = await Task { @MainActor in
                    let context = CIContext()
                    return context.createCGImage(scaledImage, from: extent)
                }.value
                
                guard let cgImage else {
                    return
                }

                let finalImage = CIImage(cgImage: cgImage)
                await VLMModelManager.shared.processImage(finalImage)
            }
        }
        
        // Off-screen indicator: Update every 10 frames (~6 FPS)
        indicatorFrameCounter += 1
        if indicatorFrameCounter >= indicatorFrameSkip {
            indicatorFrameCounter = 0
            updateOffscreenIndicator()
        }
    }
    
    private func updateOffscreenIndicator() {
        guard let arView = arView,
              let modelEntity = CharacterModelController.shared.modelEntity,
              modelEntity.isAnchored,
              let isIndicatorVisible = isIndicatorVisible,
              let indicatorPosition = indicatorPosition,
              let indicatorAngle = indicatorAngle
        else {
            self.isIndicatorVisible?.wrappedValue = false
            return
        }
        
        let modelPosition = modelEntity.position(relativeTo: nil)
        let projectedPoint = arView.project(modelPosition)
        let viewBounds = arView.bounds
        
        if let projectedPoint = projectedPoint, !viewBounds.contains(projectedPoint) {
            // Model is off-screen
            isIndicatorVisible.wrappedValue = true
            
            let viewCenter = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
            let angle = atan2(projectedPoint.y - viewCenter.y, projectedPoint.x - viewCenter.x)
            indicatorAngle.wrappedValue = Angle(radians: Double(angle))
            
            let intersection = screenEdgeIntersection(for: angle, in: viewBounds)
            indicatorPosition.wrappedValue = intersection
        } else {
            // Model is on-screen
            isIndicatorVisible.wrappedValue = false
        }
    }
    
    private func screenEdgeIntersection(for angle: CGFloat, in bounds: CGRect) -> CGPoint {
        let viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        var x: CGFloat = 0
        var y: CGFloat = 0
        
        let tanAngle = tan(angle)
        
        if abs(tanAngle) * bounds.width / 2 < bounds.height / 2 {
            // Intersects with left or right edge
            x = (angle > -CGFloat.pi / 2 && angle < CGFloat.pi / 2) ? bounds.maxX - 20 : bounds.minX + 20
            y = viewCenter.y + tanAngle * (x - viewCenter.x)
        } else {
            // Intersects with top or bottom edge
            y = (angle > 0) ? bounds.maxY - 20 : bounds.minY + 20
            x = viewCenter.x + (y - viewCenter.y) / tanAngle
        }
        
        return CGPoint(x: x, y: y)
    }
}
#endif
