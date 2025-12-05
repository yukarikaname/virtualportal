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
@preconcurrency import AVFoundation
import CoreLocation
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
    @StateObject private var modelController = ModelRenderer.shared
    @Environment(\.scenePhase) private var scenePhase

    // Show a blur overlay when the app becomes inactive/multitasking menu appears
    @State private var showBlurOverlay: Bool = false
    
    // MARK: - UI State
    @State private var hideControls: Bool = false
    @State private var thumbnail: UIImage? = nil
    @State private var capturedImage: UIImage? = nil
    @State private var showPhotoPreview: Bool = false
    @State private var showSettings: Bool = false
    @State private var snapshotter: ARSnapshotter?
    // Availability warning UI
    @State private var showFoundationWarningButton: Bool = false
    // Rate app prompt
    // Permission sheet
    @State var showPermissionSheet: Bool = false
    @State private var hasCheckedPermissions: Bool = false
    @State private var hasRequestedLocationPermission: Bool = false
    @State private var locationPermissionGranted: Bool = false

    // Managers
    private let cameraSessionManager = CameraSessionManager()
    private let photoCaptureHandler = PhotoCaptureHandler()

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
                // Blur overlay shown when the scene is inactive (multitask menu/app switcher)
                if showBlurOverlay {
                    Color.clear
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // Camera controls
                VStack {
                    Spacer()
                    CameraControlsView(
                        hideControls: $hideControls,
                        thumbnail: thumbnail,
                        onThumbnailTap: {
                            if capturedImage != nil {
                                showPhotoPreview = true
                            }
                        }
                    )
                }
            }
            .ignoresSafeArea()
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                
                // Check if permissions need to be requested
                if !hasCheckedPermissions {
                    hasCheckedPermissions = true
                    checkAndShowPermissionSheet()
                }
                
                // Start conversation pipeline after onboarding is complete
                // Load the VLM model explicitly here (lazy load) to avoid
                // starting heavy model work during onboarding or transient views.
                Task {
                    await settingsViewModel.loadVLMModel()
                }

                Task { @MainActor in
                    // Small delay to allow AR to initialize
                    try? await Task.sleep(for: .seconds(1))
                    print("Initializing conversation pipeline...")
                    ConversationManager.shared.start()
                }

                // Start a minimal AVCaptureSession to enable Camera Control interactions
                cameraSessionManager.startCameraSession()
                
                // Setup iPhone 15+ capture button handler
                CaptureButtonHandler.shared.setup { 
                    NotificationCenter.default.post(name: Notification.Name("virtualportal.cameraCaptureRequested"), object: nil)
                }
                
                // Register launch for rate prompt logic (RateManager will invoke in-app review when threshold reached)
                Task { @MainActor in
                    RateManager.shared.registerLaunch()
                }
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                // Clean up resources properly
                Task { @MainActor in
                    modelController.reset()
                }
                // Tear down minimal capture session used for Camera Control
                cameraSessionManager.stopCameraSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("virtualportal.captureButtonPressed"))) { _ in
                // iPhone 15+ capture button was pressed
                NotificationCenter.default.post(name: Notification.Name("virtualportal.cameraCaptureRequested"), object: nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("virtualportal.cameraCaptureRequested"))) { _ in
                // Capture: check camera permission first to avoid crashes when access is denied
                print("[ModelLayerView] Capture requested; snapshotter is \(snapshotter == nil ? "nil" : "ready")")
                PermissionManager.checkCameraPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            // Show permission sheet so user can enable camera
                            showPermissionSheet = true
                            print("Camera permission not granted - showing permission sheet")
                            return
                        }

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
                        print("[ModelLayerView] Triggering snapshot")
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
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("virtualportal.photoCapturerCompleted"))) { notification in
                guard let image = notification.userInfo?["image"] as? UIImage else { return }
                
                Task { @MainActor in
                    await handleCapture(image: image)
                }
            }
            .toolbar {
                // Settings button
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("virtualportal.foundationModelUnavailable"))) { _ in
                Task { @MainActor in
                    showFoundationWarningButton = true
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Show blur when not active; hide when active again
            withAnimation(.easeInOut(duration: 0.2)) {
                showBlurOverlay = (newPhase != .active)
            }
        }
        .sheet(isPresented: $showPermissionSheet) {
            PermissionSheetView(isPresented: $showPermissionSheet)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
            .background(Color(.systemGroupedBackground))
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showPhotoPreview) {
            if let image = capturedImage {
                ZStack {
                    Color.black.ignoresSafeArea()

                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .ignoresSafeArea()

                    VStack {
                        HStack {
                            Button(action: { showPhotoPreview = false }) {
                                Image(systemName: "xmark")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                    .padding(12)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(Circle())
                            }
                            .padding(.leading, 20)

                            Spacer()

                            Button(action: { shareImage(image: image) }) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                    .padding(12)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(Circle())
                            }
                            .padding(.trailing, 20)
                        }
                        .padding(.top, 50)

                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Permission Checking

    private func shareImage(image: UIImage) {
        photoCaptureHandler.shareImage(image: image)
    }
    
    @MainActor
    private func handleCapture(image: UIImage) async {
        let result = await photoCaptureHandler.handleCapture(image: image)
        // Create square thumbnail for display (no black bars)
        self.thumbnail = result.thumbnail
        // Store full image but don't show preview - just save to library
        self.capturedImage = result.fullImage

        // Save the full original image to photo library. Location metadata is attached only
        // if the user granted location permission. We will request location permission at
        // the first capture only; subsequent captures won't prompt again.
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
        // Normal device behavior: request permissions when needed and save the image.
        // Location permission flow: request once on first capture. If granted, attach location metadata.
        var location: CLLocation? = nil

        if !hasRequestedLocationPermission {
            hasRequestedLocationPermission = true
            // Ask PermissionManager to request location. This will show the system prompt if needed.
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                PermissionManager.requestLocationPermission { granted in
                    cont.resume(returning: granted)
                }
            }
            locationPermissionGranted = granted
        }

        if locationPermissionGranted {
            let mgr = CLLocationManager()
            location = mgr.location
        }

        // Delegate photo permission checks and save logic to PermissionManager, passing location metadata (may be nil)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            PermissionManager.requestPhotoLibraryAddPermission(andSave: image, location: location) { success in
                if !success {
                    print("PhotoLibrary: permission denied or save failed")
                }
                cont.resume()
            }
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
            ModelRenderer.shared.configureARView(arView)
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
            snapshotter = { [weak coordinator] completion in
                guard let arView = coordinator?.arView else {
                    completion(nil)
                    return
                }
                arView.snapshot(saveToHDR: true) { image in
                    // Ensure completion is called on main thread to avoid concurrency issues
                    DispatchQueue.main.async {
                        completion(image)
                    }
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
    
    // Managers
    private let arVlmPipeline = ARVLMPipeline()
    
    // Model state - accessed only from main thread
    private var currentModelName: String = ""
    private var currentModelScale: Double = 1.0
    private var currentApplyCustomShader: Bool = false
    private var currentObjectOcclusionEnabled: Bool = false
    
    // Off-screen indicator bindings
    private var isIndicatorVisible: Binding<Bool>?
    private var indicatorPosition: Binding<CGPoint>?
    private var indicatorAngle: Binding<Angle>?
    
    override init() {
        super.init()
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
        
        ModelRenderer.shared.updateModel(modelName: modelName, modelScale: modelScale, applyCustomShader: applyCustomShader)
        ModelRenderer.shared.updateObjectOcclusion(enabled: objectOcclusionEnabled)
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
            
            ModelRenderer.shared.updateModel(modelName: modelName, modelScale: modelScale, applyCustomShader: applyCustomShader)
        } else if scaleChanged {
            currentModelScale = modelScale
            ModelRenderer.shared.updateModelScale(modelScale)
        }
        
        if shaderChanged {
            currentApplyCustomShader = applyCustomShader
            ModelRenderer.shared.updateShader(applyCustomShader)
        }
        
        if occlusionChanged {
            currentObjectOcclusionEnabled = objectOcclusionEnabled
            ModelRenderer.shared.updateObjectOcclusion(enabled: objectOcclusionEnabled)
        }
    }
    
    func captureSnapshot() -> UIImage? {
        guard let arView = arView else {
            print("ARView is nil, cannot capture snapshot")
            return nil
        }
        
        // Must be called on main thread
        guard Thread.isMainThread else {
            print("captureSnapshot called off main thread - returning nil")
            return nil
        }
        
        let renderer = UIGraphicsImageRenderer(bounds: arView.bounds)
        let image = renderer.image { context in
            arView.drawHierarchy(in: arView.bounds, afterScreenUpdates: true)
        }
        print("Captured snapshot: \(image.size)")
        return image
    }
    
    // MARK: - ARSessionDelegate (runs on main queue)
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // Process plane anchors - already on main queue
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                ModelRenderer.shared.handlePlaneDetection(
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
                ModelRenderer.shared.updatePlaneAnchor(
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
        arVlmPipeline.processARFrame(frame)
        
        updateOffscreenIndicator()
    }
    
    private func updateOffscreenIndicator() {
        guard let arView = arView,
              let modelEntity = ModelRenderer.shared.modelEntity,
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
