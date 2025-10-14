//
//  SettingsView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 10/17/25.
//

import SwiftUI
import UniformTypeIdentifiers

#if canImport(ARKit)
    import ARKit
#endif
#if canImport(RealityKit)
    import RealityKit
#endif

private let groupedBackgroundColor = Color(.systemGroupedBackground)

struct SettingsView: View {
    @State private var selectedTab = 0
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        VStack {
            Picker("", selection: $selectedTab) {
                Text("General").tag(0)
                Text("Memory").tag(1)
//                Text("Training").tag(2)
                Text("Advanced").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 12)

            TabView(selection: $selectedTab) {
                GeneralSettingsView(viewModel: viewModel).tag(0)
                MemorySettingsView().tag(1)
//                TrainView().tag(2)
                AdvancedSettingsView(viewModel: viewModel).tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(groupedBackgroundColor)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(.all, edges: .bottom)
    }
}

struct GeneralSettingsView: View {
    // MARK: - ViewModel
    @ObservedObject var viewModel: SettingsViewModel

    // MARK: - State Properties
    @State private var showUSDZImporter = false

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

                // Personality prompt editor
                VStack {
                    HStack {
                        Label("Prompt", systemImage: "person.text.rectangle")
                        Spacer()
                        Button(action: {
                            viewModel.generateDescription(
                                supportsModelRendering: supportsModelRendering)
                        }) {
                            HStack {
                                if viewModel.isGeneratingDescription {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Generate One")
                                }
                            }
                        }
                        .disabled(
                            viewModel.isGeneratingDescription || viewModel.usdzModelName.isEmpty
                                || !supportsModelRendering)
                    }

                    TextEditor(text: $viewModel.promptText)
                        .frame(minHeight: 100, maxHeight: 150)
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

            #if os(iOS)
                // MARK: - Capture Section
                Section(header: Text("Capture")) {
                    Toggle(isOn: $viewModel.saveLocationEnabled) {
                        Label("Save Location", systemImage: "location")
                    }
                    Toggle(isOn: $viewModel.livePhotoEnabled) {
                        Label("Live Photo", systemImage: "livephoto")
                    }
                }
            #endif

            // MARK: - About Section
            Section(header: Text("About")) {
                NavigationLink(destination: AboutView()) {
                    Label("About Virtual Portal", systemImage: "info.circle")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(groupedBackgroundColor)
        .ignoresSafeArea(.all, edges: .bottom)
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
                    .onChange(of: viewModel.arResolution) {
                        viewModel.notifyARConfigurationChanged()
                    }

                    Picker(selection: $viewModel.arFrameRate) {
                        Text("60 FPS").tag(60)
                        Text("30 FPS").tag(30)
                    } label: {
                        Label("Frame Rate", systemImage: "film.stack")
                    }
                    .onChange(of: viewModel.arFrameRate) {
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

                VStack(alignment: .leading, spacing: 8) {
                    Label("Prompt", systemImage: "text.quote")
                    TextEditor(text: $viewModel.vlmPrompt)
                        .frame(minHeight: 60)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Prompt Suffix", systemImage: "text.append")
                    TextEditor(text: $viewModel.vlmPromptSuffix)
                        .frame(minHeight: 60)
                }

                Button(action: { viewModel.resetVLMSettings() }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset to Defaults")
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Section(header: Text("Model Rendering")) {
                Toggle(isOn: $viewModel.applyCustomShader) {
                    Label("Cel Shading", systemImage: "paintbrush.pointed")
                }

                Toggle(isOn: $viewModel.objectOcclusionEnabled) {
                    Label("Object Occlusion", systemImage: "cube.transparent")
                }
                .onChange(of: viewModel.objectOcclusionEnabled) {
                    viewModel.notifyARConfigurationChanged()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(groupedBackgroundColor)
        .ignoresSafeArea(.all, edges: .bottom)
    }
}

struct MemorySettingsView: View {
    @StateObject private var memoryManager = MemoryManager.shared
    @State private var searchText = ""
    @State private var selectedTag: String? = nil
    @State private var editingMemory: Memory? = nil
    @State private var showAddMemory = false

    private var allTags: [String] {
        let tagSet = memoryManager.memories.flatMap { $0.tags }
        return Array(Set(tagSet)).sorted()
    }

    private var filteredMemories: [Memory] {
        var memories = memoryManager.memories

        // Filter by tag
        if let tag = selectedTag {
            memories = memoryManager.getMemories(byTags: [tag])
        }

        // Filter by search
        if !searchText.isEmpty {
            memories = memoryManager.searchMemories(query: searchText)
            if let tag = selectedTag {
                memories = memories.filter { $0.tags.contains(tag) }
            }
        }

        return memories
    }

    var body: some View {
        Form {
            // Search bar
            Section {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search memories...", text: $searchText)
                }
            }

            // Tag filter
            Section(header: Text("Filter by Tag")) {
                if allTags.isEmpty {
                    Text("No tags yet - memories will be tagged by the LLM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            Button(action: { selectedTag = nil }) {
                                Text("All")
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        selectedTag == nil
                                            ? Color.accentColor : Color.gray.opacity(0.2)
                                    )
                                    .foregroundColor(selectedTag == nil ? .white : .primary)
                                    .cornerRadius(16)
                            }

                            ForEach(allTags, id: \.self) { tag in
                                Button(action: { selectedTag = tag }) {
                                    Text(tag)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            selectedTag == tag
                                                ? Color.accentColor : Color.gray.opacity(0.2)
                                        )
                                        .foregroundColor(selectedTag == tag ? .white : .primary)
                                        .cornerRadius(16)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            // Statistics
            Section(header: Text("Statistics")) {
                HStack {
                    Label("Total Memories", systemImage: "brain.head.profile")
                    Spacer()
                    Text("\(memoryManager.memories.count)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Label("High Importance", systemImage: "star.fill")
                    Spacer()
                    Text("\(memoryManager.memories.filter { $0.importance >= 4 }.count)")
                        .foregroundColor(.secondary)
                }
            }

            // Memories list
            Section(
                header: HStack {
                    Text("Memories")
                    Spacer()
                    Button(action: { showAddMemory = true }) {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            ) {
                if filteredMemories.isEmpty {
                    Text("No memories found")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(filteredMemories) { memory in
                        MemoryRow(
                            memory: memory,
                            onEdit: {
                                editingMemory = memory
                            },
                            onDelete: {
                                memoryManager.deleteMemory(memory)
                            })
                    }
                }
            }

            // Clear all button
            Section {
                Button(
                    role: .destructive,
                    action: {
                        memoryManager.clearAllMemories()
                    }
                ) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear All Memories")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(groupedBackgroundColor)
        .ignoresSafeArea(.all, edges: .bottom)
        .sheet(item: $editingMemory) { memory in
            MemoryEditView(memory: memory)
        }
        .sheet(isPresented: $showAddMemory) {
            MemoryAddView()
        }
    }
}

struct MemoryRow: View {
    let memory: Memory
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Display tags as chips
                if !memory.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(memory.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.2))
                                    .cornerRadius(8)
                            }
                        }
                    }
                }

                Spacer()

                // Importance stars
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { index in
                        Image(systemName: index <= memory.importance ? "star.fill" : "star")
                            .font(.caption2)
                            .foregroundColor(index <= memory.importance ? .yellow : .gray)
                    }
                }
            }

            Text(memory.content)
                .font(.body)

            HStack {
                Text(memory.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if !memory.associatedEntities.isEmpty {
                    Spacer()
                    Text("About: \(memory.associatedEntities.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .italic()
                        .lineLimit(1)
                }
            }
        }
        .contextMenu {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

struct MemoryEditView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var memoryManager = MemoryManager.shared

    @State var memory: Memory
    @State private var content: String
    @State private var tags: String
    @State private var entities: String
    @State private var importance: Int

    init(memory: Memory) {
        self.memory = memory
        _content = State(initialValue: memory.content)
        _tags = State(initialValue: memory.tags.joined(separator: ", "))
        _entities = State(initialValue: memory.associatedEntities.joined(separator: ", "))
        _importance = State(initialValue: memory.importance)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Content")) {
                    TextEditor(text: $content)
                        .frame(minHeight: 100)
                }

                Section(header: Text("Tags"), footer: Text("Comma-separated keywords")) {
                    TextField("e.g., preference, food, hobby", text: $tags)
                }

                Section(header: Text("Entities"), footer: Text("People, places, things mentioned"))
                {
                    TextField("e.g., Alice, coffee shop, Monday", text: $entities)
                }

                Section(header: Text("Importance")) {
                    Picker("Importance", selection: $importance) {
                        ForEach(1...5, id: \.self) { level in
                            HStack {
                                ForEach(1...level, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                }
                            }
                            .tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Edit Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = memory
                        updated.content = content
                        updated.tags = tags.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }.filter { !$0.isEmpty }
                        updated.associatedEntities = entities.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }.filter { !$0.isEmpty }
                        updated.importance = importance
                        memoryManager.updateMemory(updated)
                        dismiss()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct MemoryAddView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var memoryManager = MemoryManager.shared

    @State private var content: String = ""
    @State private var tags: String = ""
    @State private var entities: String = ""
    @State private var importance: Int = 3

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Content")) {
                    TextEditor(text: $content)
                        .frame(minHeight: 100)
                }

                Section(
                    header: Text("Tags"),
                    footer: Text("Comma-separated keywords (e.g., preference, food, hobby)")
                ) {
                    TextField("Tags", text: $tags)
                }

                Section(
                    header: Text("Entities"),
                    footer: Text("People, places, things mentioned (e.g., Alice, coffee shop)")
                ) {
                    TextField("Entities", text: $entities)
                }

                Section(header: Text("Importance")) {
                    Picker("Importance", selection: $importance) {
                        ForEach(1...5, id: \.self) { level in
                            HStack {
                                ForEach(1...level, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                }
                            }
                            .tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Add Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let tagArray = tags.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }.filter { !$0.isEmpty }
                        let entityArray = entities.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }.filter { !$0.isEmpty }

                        memoryManager.addMemory(
                            content: content,
                            importance: importance,
                            tags: tagArray,
                            entities: entityArray
                        )
                        dismiss()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
