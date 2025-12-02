//
//  PromptEditorView.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/24/25.
//

import SwiftUI

struct PromptEditorView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var memoryManager = MemoryManager.shared
    @Environment(\.presentationMode) var presentationMode
    @State private var showMemoryEditor: Bool = false
    @State private var editingMemory: MemoryEntry? = nil
    @State private var memoryEditorText: String = ""
    @State private var showClearAllConfirm: Bool = false

    var body: some View {
        Form {
            Section(header: Text("Personality")) {
                TextEditor(text: $viewModel.characterPersonality)
                    .frame(minHeight: 120)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                Text("Describe the character's personality and behavior. This is used by the LLM to shape responses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("Extra Prompt")) {
                TextEditor(text: $viewModel.extraLLMPrompt)
                    .frame(minHeight: 100)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                Text("Optional extra instructions appended to LLM prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("Memories")) {
                if memoryManager.memories.isEmpty {
                    Text("No memories yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(memoryManager.memories) { m in
                        VStack(alignment: .leading) {
                            Text(m.text)
                                .font(.body)
                            Text(m.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button(action: {
                                editingMemory = m
                                memoryEditorText = m.text
                                showMemoryEditor = true
                            }) {
                                Text("Edit")
                                Image(systemName: "pencil")
                            }
                            Button(role: .destructive) {
                                MemoryManager.shared.deleteMemory(id: m.id)
                            } label: {
                                Text("Delete")
                                Image(systemName: "trash")
                            }
                        }
                    }
                    .onDelete { idxSet in
                        for idx in idxSet {
                            let id = memoryManager.memories[idx].id
                            MemoryManager.shared.deleteMemory(id: id)
                        }
                    }
                }

                Button(action: {
                    editingMemory = nil
                    memoryEditorText = ""
                    showMemoryEditor = true
                }) {
                    Label("Add Memory", systemImage: "plus")
                }
                // Delete all memories
                if !memoryManager.memories.isEmpty {
                    Button(role: .destructive) {
                        showClearAllConfirm = true
                    } label: {
                        Label("Delete All Memories", systemImage: "trash")
                    }
                    .confirmationDialog("Delete all memories? This action cannot be undone.", isPresented: $showClearAllConfirm, titleVisibility: .visible) {
                        Button("Delete All", role: .destructive) {
                            MemoryManager.shared.clearMemories()
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
        }
        .navigationTitle("Prompt Editor")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMemoryEditor) {
            NavigationStack {
                VStack(spacing: 16) {
                    TextEditor(text: $memoryEditorText)
                        .frame(minHeight: 200)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)

                    Spacer()
                }
                .padding()
                .navigationTitle(editingMemory == nil ? "Add Memory" : "Edit Memory")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let editing = editingMemory {
                                MemoryManager.shared.updateMemory(id: editing.id, newText: memoryEditorText)
                            } else {
                                MemoryManager.shared.addMemory(memoryEditorText)
                            }
                            showMemoryEditor = false
                        }
                        .disabled(memoryEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showMemoryEditor = false }
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationView { PromptEditorView(viewModel: SettingsViewModel()) }
}
