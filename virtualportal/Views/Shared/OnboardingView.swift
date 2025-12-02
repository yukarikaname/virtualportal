//
//  OnboardingView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/17/25.
//

import SwiftUI
import UniformTypeIdentifiers
import SafariServices

struct OnboardingView: View {

    @Binding var firstStart: Bool
    @StateObject private var onboardingViewModel: OnboardingViewModel
    @StateObject private var settingsViewModel: SettingsViewModel
    @State private var showFoundationAlert: Bool = false
    @State private var showSettings: Bool = false

    init(firstStart: Binding<Bool>) {
        self._firstStart = firstStart
        _onboardingViewModel = StateObject(wrappedValue: OnboardingViewModel())
        _settingsViewModel = StateObject(wrappedValue: SettingsViewModel())
    }

    // Alerts for warnings
    private var _alerts: some View {
        EmptyView()
            .alert("Foundation model unavailable", isPresented: $showFoundationAlert) {
                Button("OK", role: .cancel) { }
                Button("Open Settings") { showSettings = true }
            } message: {
                Text("The device does not have the required on-device foundation model. The app will fall back to a simpler response mode. Open Settings to change model preferences.")
            }
    }

    var body: some View {
        VStack {
            HStack {
                if onboardingViewModel.currentStep > 0 {
                    Button("Back") {
                        onboardingViewModel.previousStep()
                    }
                    .padding(.leading)
                }
                Spacer()
            }

            switch onboardingViewModel.currentStep {
            case 0:
                WelcomeStep(
                    nextStep: { onboardingViewModel.nextStep() }
                )
            case 1:
                ModelSelectionStep(
                    firstStart: $firstStart,
                    viewModel: settingsViewModel,
                    onDone: {
                        onboardingViewModel.completeOnboarding {
                            firstStart = true
                        }
                    }
                )
            default:
                Button("Done") {
                    onboardingViewModel.completeOnboarding {
                        firstStart = true
                    }
                }
            }
        }
        .background(_alerts)
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



struct ModelSelectionStep: View {
    @Binding var firstStart: Bool
    @ObservedObject var viewModel: SettingsViewModel
    var onDone: () -> Void
    @State private var showUSDZImporter = false
    @State private var showTutorialSheet = false
    private let aboutVM = AboutViewModel()

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
            HStack {
                Spacer()
                Button(action: { showTutorialSheet = true }) {
                    Label("MMD → USDZ Tutorial", systemImage: "play.rectangle")
                }
                .padding(.top)
                Spacer()
            }
            Button("Done") {
                onDone()
            }
            .padding()
            .sheet(isPresented: $showTutorialSheet) {
                if let url = aboutVM.mmdToUsdzTutorialURL {
                    SafariView(url: url)
                }
            }
        }
    }

    // Simple Safari wrapper for sheet presentation
    struct SafariView: UIViewControllerRepresentable {
        let url: URL

        func makeUIViewController(context: Context) -> SFSafariViewController {
            return SFSafariViewController(url: url)
        }

        func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
    }
}

#Preview {
    OnboardingView(firstStart: Binding.constant(false))
}
