//
//  ImmersiveToggleButton.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/14/25.
//

#if os(visionOS)
import SwiftUI

/// Toggle button to start/stop the immersive space in visionOS
struct ImmersiveToggleButton: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    
    @Binding var isImmersiveSpaceShown: Bool
    @State private var isLoading: Bool = false
    var compact: Bool = false
    
    var body: some View {
        Button {
            Task {
                await toggleImmersiveSpace()
            }
        } label: {
            if compact {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: isImmersiveSpaceShown ? "xmark.circle.fill" : "arkit")
                    }
                }
                .font(.body)
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(isImmersiveSpaceShown ? Color.red.opacity(0.8) : Color.blue.opacity(0.8))
                .clipShape(Circle())
            } else {
                HStack(spacing: 12) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isImmersiveSpaceShown ? "xmark.circle.fill" : "arkit")
                            .font(.title2)
                    }
                    
                    Text(isImmersiveSpaceShown ? "Stop" : "Start")
                        .font(.headline)
                }
                .padding(12)
                .background(isImmersiveSpaceShown ? Color.red.opacity(0.2) : Color.blue.opacity(0.2))
                .cornerRadius(8)
            }
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
    
    @MainActor
    private func toggleImmersiveSpace() async {
        isLoading = true
        defer { isLoading = false }
        
        if isImmersiveSpaceShown {
            await dismissImmersiveSpace()
            isImmersiveSpaceShown = false
        } else {
            switch await openImmersiveSpace(id: "ImmersiveSpace") {
            case .opened:
                isImmersiveSpaceShown = true
            case .error:
                print("Failed to open immersive space")
            case .userCancelled:
                break
            @unknown default:
                print("Unknown immersive space result")
            }
        }
    }
}

/// Legacy view name for compatibility
struct ImmersiveToggleButtonView: View {
    @Binding var isImmersiveSpaceShown: Bool
    
    var body: some View {
        ImmersiveToggleButton(isImmersiveSpaceShown: $isImmersiveSpaceShown)
    }
}
#endif
