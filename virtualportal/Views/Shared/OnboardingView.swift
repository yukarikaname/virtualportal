//
//  OnboardingView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/17/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    
    @Binding var firstStart: Bool
    @StateObject private var onboardingViewModel = OnboardingViewModel()
    @StateObject private var settingsViewModel = SettingsViewModel()
    
    var body: some View {
        VStack {
            switch onboardingViewModel.currentStep {
            case 0:
                Button("Done") {
                    firstStart = true
                }
            case 1:
                PermissionsStep(
                    viewModel: onboardingViewModel,
                    nextStep: { onboardingViewModel.nextStep() }
                )
            case 2:
                ModelSelectionStep(
                    firstStart: $firstStart,
                    viewModel: settingsViewModel
                )
            default:
                Button("Done") {
                    firstStart = true
                }
            }
        }
    }
}

struct WelcomeStep: View {
    var nextStep: () -> Void
    
    var body: some View {
        VStack {
            Text("Welcome to Virtual Portal")
                .font(.largeTitle)
                .padding()
            Text("This app lets you interact with a virtual character using your camera and voice.")
                .padding()
            Button("Continue", action: nextStep)
                .padding()
        }
    }
}

struct PermissionsStep: View {
    
    @ObservedObject var viewModel: OnboardingViewModel
    var nextStep: () -> Void

    var body: some View {
        VStack {
            Text("Permissions")
                .font(.largeTitle)
                .padding()
            Text("The app needs access to your camera and microphone for speech recognition to function.")
                .padding()

            HStack {
                Text("Camera")
                Spacer()
                if viewModel.cameraPermissionGranted {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                } else {
                    Button("Grant") {
                        viewModel.requestCameraPermission()
                    }
                }
            }
            .padding()

            HStack {
                Text("Speech Recognition")
                Spacer()
                if viewModel.speechPermissionGranted {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                } else {
                    Button("Grant") {
                        viewModel.requestSpeechPermission()
                    }
                }
            }
            .padding()

            Button("Continue", action: nextStep)
                .disabled(!viewModel.allPermissionsGranted)
                .padding()
        }
        .onAppear {
            viewModel.checkExistingPermissions()
        }
    }
}

struct ModelSelectionStep: View {
    @Binding var firstStart: Bool
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showUSDZImporter = false

    var body: some View {
        VStack {
            Text("Select a Character Model (USDZ)")
                .font(.headline)
                .padding(.top)
            Button(action: { showUSDZImporter = true }) {
                Label {
                    Text(viewModel.usdzModelName.isEmpty ? "Select USDZ Model" : viewModel.usdzModelName)
                } icon: {
                    Image(systemName: "arkit")
                }
            }
            .foregroundStyle(.primary)
            .fileImporter(
                isPresented: $showUSDZImporter,
                allowedContentTypes: [UTType(filenameExtension: "usdz")!],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        viewModel.importModel(from: url)
                    }
                case .failure(let error):
                    viewModel.importError = "Import failed: \(error.localizedDescription)"
                }
            }
            if let error = viewModel.importError {
                Text(error).foregroundColor(.red)
            }
            Button("Done") {
                firstStart = true
            }
            .padding()
        }
    }
}

#Preview {
    OnboardingView(firstStart: Binding.constant(false))
}
