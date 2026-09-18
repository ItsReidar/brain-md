//
//  MCPHTTPServer.swift
//  brain-md
//

import Foundation
import Network
import Combine

private actor SSEClientStore {
    private var clients: [String: NWConnection] = [:]
    
    func set(connection: NWConnection, for sessionId: String) {
        clients[sessionId] = connection
    }
    
    func get(sessionId: String) -> NWConnection? {
        if let conn = clients[sessionId] {
            return conn
        }
        // Fallback: if only one client is connected, route to it
        if clients.count == 1 {
            return clients.values.first
        }
        return nil
    }
    
    func remove(sessionId: String) {
        clients.removeValue(forKey: sessionId)
    }
    
    func allConnections() -> [NWConnection] {
        return Array(clients.values)
    }
    
    func closeAll() {
        for (_, conn) in clients {
            conn.cancel()
        }
        clients.removeAll()
    }
}

public final class MCPHTTPServer: ObservableObject, @unchecked Sendable {
    public static let shared = MCPHTTPServer()
    
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var port: UInt16 = 8765
    @Published public private(set) var lastError: String?
    
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.brainmd.mcp.http", qos: .userInitiated)
    private let sseStore = SSEClientStore()
    private var keepAliveTask: Task<Void, Never>?
    
    public init() {}
    
    public func start(preferredPort: UInt16 = 8765) {
        stop()
        startListener(port: preferredPort, retriesRemaining: 5)
    }
    
    private func startListener(port: UInt16, retriesRemaining: Int) {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            
            let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
            let newListener = try NWListener(using: params, on: nwPort)
            
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self.isRunning = true
                        if let actualPort = newListener.port?.rawValue {
                            self.port = actualPort
                        }
                        self.lastError = nil
                        self.startKeepAliveTimer()
                    case .failed(let err):
                        self.isRunning = false
                        self.lastError = err.localizedDescription
                        if retriesRemaining > 0 {
                            // Automatically attempt binding on next port
                            self.startListener(port: port + 1, retriesRemaining: retriesRemaining - 1)
                        }
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            newListener.start(queue: queue)
            self.listener = newListener
            
        } catch {
            if retriesRemaining > 0 {
                startListener(port: port + 1, retriesRemaining: retriesRemaining - 1)
            } else {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }
    
    public func stop() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        
        listener?.cancel()
        listener = nil
        Task {
            await sseStore.closeAll()
        }
        
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }
    
    private func startKeepAliveTimer() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s keep-alive
                guard let self = self else { break }
                let pingData = ": keepalive\r\n\r\n".data(using: .utf8)
                let conns = await self.sseStore.allConnections()
                for conn in conns {
                    conn.send(content: pingData, completion: .idempotent)
                }
            }
        }
    }
    
    // MARK: - Connection & HTTP Handling
    
    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHTTPRequest(connection: connection, accumulatedData: Data())
    }
    
    private func readHTTPRequest(connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            
            var buffer = accumulatedData
            if let d = data {
                buffer.append(d)
            }
            
            // Check if full HTTP headers received (\r\n\r\n or \n\n)
            let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) ?? buffer.range(of: Data("\n\n".utf8))
            
            if let headerEndRange = headerEndRange {
                let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    self.sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
                    return
                }
                
                let lines = headerString.components(separatedBy: .newlines).filter { !$0.isEmpty }
                guard let requestLine = lines.first else {
                    self.sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
                    return
                }
                
                let reqParts = requestLine.split(separator: " ")
                guard reqParts.count >= 2 else {
                    self.sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
                    return
                }
                
                let method = String(reqParts[0]).uppercased()
                let fullPath = String(reqParts[1])
                
                // Parse headers
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2 {
                        headers[parts[0].lowercased()] = parts[1]
                    }
                }
                
                let contentLength = Int(headers["content-length"] ?? "") ?? 0
                let host = headers["host"] ?? "127.0.0.1:\(self.port)"
                
                let bodyStartIndex = headerEndRange.upperBound
                let currentBodyLength = buffer.count - bodyStartIndex
                
                if currentBodyLength < contentLength {
                    self.readHTTPBody(
                        connection: connection,
                        method: method,
                        fullPath: fullPath,
                        host: host,
                        expectedLength: contentLength,
                        headerEndIndex: headerEndRange.upperBound,
                        accumulatedData: buffer
                    )
                } else {
                    let bodyData = buffer.subdata(in: bodyStartIndex..<(bodyStartIndex + contentLength))
                    self.routeRequest(connection: connection, method: method, fullPath: fullPath, host: host, body: bodyData)
                }
            } else if !isComplete {
                self.readHTTPRequest(connection: connection, accumulatedData: buffer)
            } else {
                connection.cancel()
            }
        }
    }
    
    private func readHTTPBody(connection: NWConnection, method: String, fullPath: String, host: String, expectedLength: Int, headerEndIndex: Int, accumulatedData: Data) {
        let currentBodyLength = accumulatedData.count - headerEndIndex
        if currentBodyLength >= expectedLength {
            let bodyData = accumulatedData.subdata(in: headerEndIndex..<(headerEndIndex + expectedLength))
            self.routeRequest(connection: connection, method: method, fullPath: fullPath, host: host, body: bodyData)
            return
        }
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var nextBuffer = accumulatedData
            if let d = data {
                nextBuffer.append(d)
            }
            self.readHTTPBody(
                connection: connection,
                method: method,
                fullPath: fullPath,
                host: host,
                expectedLength: expectedLength,
                headerEndIndex: headerEndIndex,
                accumulatedData: nextBuffer
            )
        }
    }
    
    // MARK: - Routing
    
    private func routeRequest(connection: NWConnection, method: String, fullPath: String, host: String, body: Data) {
        if method == "OPTIONS" {
            sendCORSResponse(connection: connection)
            return
        }
        
        let components = URLComponents(string: fullPath)
        let path = components?.path ?? fullPath
        
        if method == "GET" && (path == "/sse" || path == "/events") {
            handleSSEConnection(connection: connection, host: host)
            return
        }
        
        if method == "POST" && (path == "/messages" || path == "/message") {
            let sessionId = components?.queryItems?.first(where: { $0.name == "sessionId" })?.value ?? ""
            handleSSEMessage(connection: connection, sessionId: sessionId, body: body)
            return
        }
        
        if method == "POST" && (path == "/mcp" || path == "/rpc" || path == "/jsonrpc" || path == "/") {
            handleDirectMCP(connection: connection, body: body)
            return
        }
        
        if method == "GET" && (path == "/status" || path == "/health" || path == "/") {
            let json = """
            {
              "status": "running",
              "port": \(port),
              "server": "brain-md",
              "protocolVersion": "2024-11-05",
              "endpoints": {
                "sse": "http://\(host)/sse",
                "messages": "http://\(host)/messages",
                "directMCP": "http://\(host)/mcp"
              }
            }
            """
            sendHTTPResponse(connection: connection, status: 200, contentType: "application/json", body: json)
            return
        }
        
        sendHTTPResponse(connection: connection, status: 404, body: "Not Found")
    }
    
    // MARK: - SSE Implementation
    
    private func handleSSEConnection(connection: NWConnection, host: String) {
        let sessionId = UUID().uuidString
        Task {
            await sseStore.set(connection: connection, for: sessionId)
        }
        
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache, no-transform\r
        Connection: keep-alive\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Headers: *\r
        \r\n
        """
        
        guard let headerData = headers.data(using: .utf8) else { return }
        connection.send(content: headerData, completion: .contentProcessed { [weak self] err in
            guard err == nil, let self = self else { return }
            
            // Standard MCP endpoint event pointing client to absolute /messages?sessionId=...
            let endpointUrl = "http://\(host)/messages?sessionId=\(sessionId)"
            let endpointEvent = "event: endpoint\r\ndata: \(endpointUrl)\r\n\r\n"
            if let eventData = endpointEvent.data(using: .utf8) {
                connection.send(content: eventData, completion: .idempotent)
            }
            
            // Monitor connection closure to promptly free SSE store
            self.monitorSSEConnection(connection: connection, sessionId: sessionId)
        })
    }
    
    private func monitorSSEConnection(connection: NWConnection, sessionId: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self = self else { return }
            if isComplete || error != nil {
                Task {
                    await self.sseStore.remove(sessionId: sessionId)
                }
                connection.cancel()
            } else {
                self.monitorSSEConnection(connection: connection, sessionId: sessionId)
            }
        }
    }
    
    private func handleSSEMessage(connection: NWConnection, sessionId: String, body: Data) {
        Task {
            if let responseData = await MCPServer.shared.handleRequest(data: body) {
                let sseConn = await self.sseStore.get(sessionId: sessionId)
                if let sseConn = sseConn, let str = String(data: responseData, encoding: .utf8) {
                    // Split by lines if any, prefix each line with data: per SSE spec
                    let lines = str.components(separatedBy: "\n")
                    let sseData = lines.map { "data: \($0)" }.joined(separator: "\r\n")
                    let sseMessage = "event: message\r\n\(sseData)\r\n\r\n"
                    if let data = sseMessage.data(using: .utf8) {
                        sseConn.send(content: data, completion: .idempotent)
                    }
                }
            }
            
            // Return 202 Accepted to the POST request as per SSE MCP spec
            self.sendHTTPResponse(connection: connection, status: 202, body: "Accepted")
        }
    }
    
    private func handleDirectMCP(connection: NWConnection, body: Data) {
        Task {
            if let responseData = await MCPServer.shared.handleRequest(data: body) {
                let responseStr = String(data: responseData, encoding: .utf8) ?? "{}"
                self.sendHTTPResponse(connection: connection, status: 200, contentType: "application/json", body: responseStr)
            } else {
                self.sendHTTPResponse(connection: connection, status: 204, body: "")
            }
        }
    }
    
    // MARK: - Helpers
    
    private func sendCORSResponse(connection: NWConnection) {
        let resp = """
        HTTP/1.1 200 OK\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type, Authorization, x-session-id\r
        Access-Control-Expose-Headers: *\r
        Content-Length: 0\r
        \r\n
        """
        connection.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendHTTPResponse(connection: NWConnection, status: Int, contentType: String = "text/plain", body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let resp = """
        HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 202 ? "Accepted" : status == 204 ? "No Content" : status == 404 ? "Not Found" : "Error")\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type, Authorization, x-session-id\r
        Access-Control-Expose-Headers: *\r
        Connection: close\r
        \r\n
        """
        guard var fullData = resp.data(using: .utf8) else {
            connection.cancel()
            return
        }
        fullData.append(bodyData)
        connection.send(content: fullData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
