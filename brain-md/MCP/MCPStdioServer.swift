//
//  MCPStdioServer.swift
//  brain-md
//

import Foundation

public final class MCPStdioServer: @unchecked Sendable {
    public static let shared = MCPStdioServer()
    
    public init() {}
    
    public func run() async {
        // Prevent SIGPIPE crashes when the client disconnects unexpectedly
        signal(SIGPIPE, SIG_IGN)
        
        fputs("[brain-md-mcp] Starting native stdio MCP server...\n", stderr)
        fflush(stderr)
        
        let stdinHandle = FileHandle.standardInput
        let stdoutHandle = FileHandle.standardOutput
        
        var buffer = Data()
        
        while true {
            let chunk = stdinHandle.availableData
            if chunk.isEmpty {
                // EOF reached
                fputs("[brain-md-mcp] Stdin closed, shutting down.\n", stderr)
                fflush(stderr)
                break
            }
            
            buffer.append(chunk)
            
            // Process lines (newline-delimited JSON)
            while let newlineRange = buffer.range(of: Data("\n".utf8)) {
                let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
                buffer.removeSubrange(0..<newlineRange.upperBound)
                
                // Strip carriage returns and leading/trailing whitespace
                var clean = lineData
                while let last = clean.last, last == 0x0D || last == 0x20 || last == 0x09 {
                    clean.removeLast()
                }
                while let first = clean.first, first == 0x20 || first == 0x09 {
                    clean.removeFirst()
                }
                
                if clean.isEmpty { continue }
                
                if let responseData = await MCPServer.shared.handleRequest(data: clean) {
                    var out = responseData
                    out.append(contentsOf: "\n".utf8)
                    do {
                        try stdoutHandle.write(contentsOf: out)
                        try? stdoutHandle.synchronize()
                        fflush(Darwin.stdout)
                    } catch {
                        fputs("[brain-md-mcp] Error writing to stdout: \(error.localizedDescription)\n", stderr)
                        fflush(stderr)
                        return
                    }
                }
            }
        }
    }
}
