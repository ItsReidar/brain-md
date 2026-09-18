//
//  MCPServerModalView.swift
//  brain-md
//

import SwiftUI

public struct MCPServerModalView: View {
    @ObservedObject var httpServer = MCPHTTPServer.shared
    @ObservedObject var vault = VaultManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var copiedClaude: Bool = false
    @State private var copiedCursor: Bool = false
    @State private var copiedStdio: Bool = false
    @State private var selectedTab = 0
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(httpServer.isRunning ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model Context Protocol (MCP) Server")
                            .font(.headline)
                        Text(httpServer.isRunning ? "Online & Listening on 127.0.0.1:\(String(httpServer.port))" : "Server Stopped")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button(action: {
                    if httpServer.isRunning {
                        httpServer.stop()
                    } else {
                        httpServer.start()
                    }
                }) {
                    Label(httpServer.isRunning ? "Stop Server" : "Start Server", systemImage: httpServer.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Picker
            Picker("", selection: $selectedTab) {
                Text("Agent Integrations").tag(0)
                Text("Live Activity Logs (\(vault.recentActivities.count))").tag(1)
                Text("Available MCP Tools").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            
            Divider()
            
            // Content
            if selectedTab == 0 {
                integrationsTab
            } else if selectedTab == 1 {
                activityLogsTab
            } else {
                toolsTab
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
    
    // MARK: - Tab 1: Agent Integrations
    
    private var integrationsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Claude Desktop Config (Stdio mode)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundColor(.accentColor)
                        Text("Claude Desktop Setup (Stdio)")
                            .font(.subheadline).bold()
                        Spacer()
                        Button(copiedClaude ? "Copied!" : "Copy JSON") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(claudeConfigString, forType: .string)
                            copiedClaude = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedClaude = false }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Text("Add to ~/Library/Application Support/Claude/claude_desktop_config.json:")
                        .font(.caption).foregroundColor(.secondary)
                    
                    Text(claudeConfigString)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                }
                .padding(14)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                // Cursor / SSE Setup
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "curlybraces")
                            .foregroundColor(.purple)
                        Text("Cursor / Windsurf / SSE Client")
                            .font(.subheadline).bold()
                        Spacer()
                        Button(copiedCursor ? "Copied!" : "Copy JSON") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cursorConfigString, forType: .string)
                            copiedCursor = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedCursor = false }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Text("Add to Cursor Settings -> Features -> MCP Servers (Type: SSE):")
                        .font(.caption).foregroundColor(.secondary)
                    
                    Text(cursorConfigString)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                }
                .padding(14)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                // Stdio CLI Setup
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "terminal.fill")
                            .foregroundColor(.orange)
                        Text("Terminal CLI Stdio Mode")
                            .font(.subheadline).bold()
                        Spacer()
                        Button(copiedStdio ? "Copied!" : "Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(stdioConfigString, forType: .string)
                            copiedStdio = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedStdio = false }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Text("You can test or pipe JSON-RPC requests via stdio:")
                        .font(.caption).foregroundColor(.secondary)
                    
                    Text(stdioConfigString)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                }
                .padding(14)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            .padding(18)
        }
    }
    
    // MARK: - Tab 2: Activity Logs
    
    private var activityLogsTab: some View {
        VStack(spacing: 0) {
            if vault.recentActivities.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No Agent Calls Yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("When an AI agent (Claude, Cursor, etc.) invokes tools, calls will appear here in real time.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vault.recentActivities) { log in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(log.isError ? Color.red : Color.green)
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(log.action)
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(log.timestamp, style: .time)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(log.detail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    // MARK: - Tab 3: Tools
    
    private var toolsTab: some View {
        List {
            toolRow(name: "list_notes", desc: "Lists all markdown notes with relative paths and file metadata.")
            toolRow(name: "read_note", desc: "Reads the full content of a specified note.")
            toolRow(name: "create_note", desc: "Creates a new markdown note in the vault with given content.")
            toolRow(name: "update_note", desc: "Updates or appends content to an existing note.")
            toolRow(name: "delete_note", desc: "Deletes a note from the vault.")
            toolRow(name: "search_notes", desc: "Searches all notes for keywords or regex patterns.")
            toolRow(name: "get_vault_stats", desc: "Returns note count, word count, and vault metadata.")
        }
    }
    
    private func toolRow(name: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.accentColor)
            Text(desc)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Snippets
    
    private var claudeConfigString: String {
        let binaryPath = Bundle.main.executablePath ?? "/Applications/brain-md.app/Contents/MacOS/brain-md"
        return """
        {
          "mcpServers": {
            "brain-md": {
              "command": "\(binaryPath)",
              "args": ["--stdio"]
            }
          }
        }
        """
    }
    
    private var cursorConfigString: String {
        return """
        {
          "mcpServers": {
            "brain-md": {
              "url": "http://127.0.0.1:\(httpServer.port)/sse"
            }
          }
        }
        """
    }
    
    private var stdioConfigString: String {
        let binaryPath = Bundle.main.executablePath ?? "brain-md"
        return "\"\(binaryPath)\" --stdio"
    }
}
