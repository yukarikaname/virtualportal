//
//  MainPageView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/5/25.
//

#if os(visionOS)
import SwiftUI

/// Main content view for visionOS
struct MainPageView: View {
    @Binding var isImmersiveSpaceShown: Bool
    @Binding var firstStart: Bool
    @State private var showSettings: Bool = false
    
    var body: some View {
        Group {
            if isImmersiveSpaceShown {
                ZStack {
                    Color.clear
                    
                    // Toggle button
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ImmersiveToggleButton(isImmersiveSpaceShown: $isImmersiveSpaceShown, compact: true)
                                .padding(20)
                        }
                    }
                }
            } else {
                // Show the main content when not in immersive space
                NavigationStack {
                    if firstStart {
                        VStack(spacing: 24) {
                            // Header
                            VStack(spacing: 8) {
                                Image(systemName: "arkit")
                                    .font(.system(size: 60))
                                    .foregroundStyle(.blue.gradient)
                                
                                Text("Virtual Portal")
                                    .font(.largeTitle)
                                    .fontWeight(.bold)
                                
                                Text("Experience your character in mixed reality")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 40)
                            
                            Spacer()
                            
                            // Quick info
                            VStack(alignment: .leading, spacing: 12) {
                                InfoRow(icon: "square.and.arrow.down", text: "Download a USDZ model in Settings")
                                InfoRow(icon: "slider.horizontal.3", text: "Adjust model scale and shaders")
                                InfoRow(icon: "hand.tap", text: "Tap and drag to reposition")
                            }
                            .padding(.horizontal, 32)
                            .padding(.bottom, 32)
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                ImmersiveToggleButton(isImmersiveSpaceShown: $isImmersiveSpaceShown, compact: true)
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    showSettings = true
                                } label: {
                                    Label("Settings", systemImage: "gearshape")
                                }
                            }
                        }
                        .sheet(isPresented: $showSettings) {
                            NavigationStack {
                                SettingsView()
                                    .toolbar {
                                        ToolbarItem(placement: .cancellationAction) {
                                            Button("Done") {
                                                showSettings = false
                                            }
                                        }
                                    }
                            }
                        }
                        .onAppear {
                            // Start conversation pipeline after onboarding is complete
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1))
                                print("Initializing conversation pipeline...")
                                ConversationManager.shared.start()
                            }
                        }
                    } else {
                        OnboardingView(firstStart: $firstStart)
                    }
                }
            }
        }
    }
}

struct InfoRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 30)
                .foregroundColor(.accentColor)
            Text(text)
                .font(.body)
        }
    }
}
#endif
