//
//  BrainGraphModalView.swift
//  brain-md
//

import SwiftUI
import AppKit

public struct BrainGraphModalView: View {
    @ObservedObject var vault: VaultManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var graphData: GraphData = GraphData()
    @State private var searchQuery: String = ""
    @State private var includeTags: Bool = true
    @State private var selectedNode: GraphNode? = nil
    @State private var isLoading: Bool = true
    
    public init(vault: VaultManager) {
        self.vault = vault
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar
            
            Divider()
            
            // Graph Viewport Area
            ZStack(alignment: .topTrailing) {
                if isLoading {
                    loadingView
                } else if graphData.nodes.isEmpty {
                    emptyView
                } else {
                    Graph3DSceneView(
                        graphData: graphData,
                        searchFilter: searchQuery,
                        selectedNodeId: selectedNode?.id,
                        onNodeSelected: { node in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selectedNode = node
                            }
                        }
                    )
                    .edgesIgnoringSafeArea(.all)
                    
                    // Floating Node Detail Card (Pop-up Inspector)
                    if let node = selectedNode {
                        NodeDetailCard(
                            node: node,
                            graphData: graphData,
                            onOpenInEditor: {
                                vault.selectNote(byRelativePath: node.relativePath)
                                dismiss()
                            },
                            onClose: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedNode = nil
                                }
                            },
                            onSelectNeighbor: { neighborId in
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    selectedNode = graphData.nodeMap[neighborId]
                                }
                            }
                        )
                        .padding(20)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 850, idealWidth: 1050, maxWidth: .infinity, minHeight: 600, idealHeight: 750, maxHeight: .infinity)
        .task {
            await reloadGraph()
        }
    }
    
    // MARK: - Header Bar
    
    private var headerBar: some View {
        HStack(spacing: 16) {
            // Title & Brain Icon
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Visual Brain Graph")
                        .font(.headline)
                    Text("\(graphData.noteNodes.count) notes • \(graphData.folderNodes.count) folders • \(graphData.edges.count) connections")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Search Bar Filter
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("Search notes or tags...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .frame(width: 220)
            
            // Include Tags Toggle
            Toggle(isOn: $includeTags) {
                Label("Tags", systemImage: "tag.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.checkbox)
            .onChange(of: includeTags) { _, _ in
                Task {
                    await reloadGraph()
                }
            }
            
            // Re-simulate / Refresh Button
            Button(action: {
                Task {
                    await reloadGraph()
                }
            }) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .help("Re-calculate 3D layout simulation")
            
            // Done Button
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Loading & Empty States
    
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Mapping vault brain synapses...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.6))
            Text("No notes found in vault")
                .font(.title3.bold())
            Text("Create notes and link them using [[wikilinks]] or tags to build your brain graph.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Graph Generation
    
    private func reloadGraph() async {
        isLoading = true
        let notePaths = vault.getAllNotePaths()
        
        var contents: [String: String] = [:]
        for path in notePaths {
            if let noteContent = try? vault.readFile(relativePath: path) {
                contents[path] = noteContent
            }
        }
        
        var tagMap: [String: [String]] = [:]
        collectTags(from: vault.rootItems, map: &tagMap)
        
        let builtGraph = NoteGraphService.shared.buildGraph(
            notePaths: notePaths,
            noteContents: contents,
            noteTags: tagMap,
            includeTags: includeTags
        )
        
        await MainActor.run {
            self.graphData = builtGraph
            self.isLoading = false
            // Keep selected node if still exists
            if let sel = selectedNode, let updated = builtGraph.nodeMap[sel.id] {
                self.selectedNode = updated
            } else {
                self.selectedNode = nil
            }
        }
    }
    
    private func collectTags(from items: [NoteItem], map: inout [String: [String]]) {
        for item in items {
            if item.isDirectory, let children = item.children {
                collectTags(from: children, map: &map)
            } else if !item.isDirectory {
                map[item.relativePath] = item.tags
            }
        }
    }
}
