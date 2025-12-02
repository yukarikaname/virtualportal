//
//  SettingsView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/17/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var selectedTab = 0
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        VStack {
            Picker("", selection: $selectedTab) {
                Text("General").tag(0)
                Text("Advanced").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 12)

            TabView(selection: $selectedTab) {
                GeneralSettingsView(viewModel: viewModel).tag(0)
                AdvancedSettingsView(viewModel: viewModel).tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GeneralSettingsView: View {
    // MARK: - ViewModel
    @ObservedObject var viewModel: SettingsViewModel

    // MARK: - State Properties
    @State private var showUSDZImporter = false
    // Alert state moved to view model (safe for async updates)

    private let supportsModelRendering = true

    var body: some View {
        Form {
            // MARK: - Character Section
            Section(header: Text("Character")) {
                // Button to select a USDZ model
                Button(action: { showUSDZImporter = true }) {
                    Label {
                        Text(
                            viewModel.usdzModelName.isEmpty
                                ? "Select USDZ Model" : viewModel.usdzModelName)
                    } icon: {
                        Image(systemName: "arkit")
                            .foregroundColor(.accentColor)
                    }
                }
                .disabled(!supportsModelRendering)

                if !supportsModelRendering {
                    Text("Model selection disabled on this platform.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // Model scale slider
                if supportsModelRendering {
                    VStack {
                        HStack {
                            Label("Model Scale", systemImage: "arrow.up.left.and.arrow.down.right")
                            Spacer()
                            Text("\(Int(viewModel.modelScale * 100))%")
                        }
                        Slider(value: $viewModel.modelScale, in: 0.1...2.0, step: 0.1)
                        HStack {
                            Text("Small").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("Large").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                // Personality prompt editor navigates to a detailed editor
                NavigationLink(destination: PromptEditorView(viewModel: viewModel)) {
                    Label("Prompt", systemImage: "person.text.rectangle")
                }
            }
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

            // Show import error if any
            if let error = viewModel.importError {
                Text(error).foregroundColor(.red)
            }

            // MARK: - TTS Section
            Section(header: Text("TTS")) {

                Toggle(isOn: $viewModel.autoInterruptEnabled) {
                    Label("Interrupt AI on User Speech", systemImage: "hand.raised.fill")
                }

                Toggle(isOn: $viewModel.autoCommentaryEnabled) {
                    Label("Auto Commentary", systemImage: "bubble.left.and.bubble.right")
                }

                VStack(alignment: .leading) {
                    HStack {
                        Label("Speech Rate", systemImage: "speedometer")
                        Spacer()
                        Text(String(format: "%.2f", viewModel.speechRate))
                    }
                    Slider(value: $viewModel.speechRate, in: 0.3...0.7, step: 0.01)
                    HStack {
                        Text("Slow").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Fast").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: - About Section
            Section(header: Text("About")) {
                NavigationLink(destination: AboutView()) {
                    Label("About Virtual Portal", systemImage: "info.circle")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
    }
}

struct AdvancedSettingsView: View {

    // MARK: - ViewModel
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {

        Form {
            #if os(iOS)
                Section(header: Text("Camera")) {
                    Picker(selection: $viewModel.arResolution) {
                        Text("4K (3840×2160)").tag("3840x2160")
                        Text("1080p (1920×1080)").tag("1920x1080")
                        Text("720p (1280×720)").tag("1280x720")
                    } label: {
                        Label("Resolution", systemImage: "rectangle.on.rectangle")
                    }
                    .onChange(of: viewModel.arResolution) { _, _ in
                        viewModel.notifyARConfigurationChanged()
                    }

                    Picker(selection: $viewModel.arFrameRate) {
                        Text("60 FPS").tag(60)
                        Text("30 FPS").tag(30)
                    } label: {
                        Label("Frame Rate", systemImage: "film.stack")
                    }
                    .onChange(of: viewModel.arFrameRate) { _, _ in
                        viewModel.notifyARConfigurationChanged()
                    }
                }
            #endif

            Section(header: Text("VLM")) {
                Picker(selection: $viewModel.vlmDownscaleResolution) {
                    Text("Original").tag(false)
                    Text("480p (Fast)").tag(true)
                } label: {
                    Label("Processing Resolution", systemImage: "cpu")
                }

                VStack(alignment: .leading) {
                    HStack {
                        Label("Minimum Process Interval (s)", systemImage: "timer")
                        Spacer()
                        Text(String(format: "%.1f", viewModel.vlmInterval))
                    }
                    Slider(value: $viewModel.vlmInterval, in: 2.0...8.0, step: 0.1)
                    HStack {
                        Text("Frequent").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Infrequent").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section(header: Text("Model Rendering")) {
                Toggle(isOn: $viewModel.applyCustomShader) {
                    Label("Cel Shading", systemImage: "paintbrush.pointed")
                }

                Toggle(isOn: $viewModel.objectOcclusionEnabled) {
                    Label("Object Occlusion", systemImage: "cube.transparent")
                }
                .onChange(of: viewModel.objectOcclusionEnabled) { _, _ in
                    viewModel.notifyARConfigurationChanged()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
    }
}

#Preview {
    SettingsView()
}
