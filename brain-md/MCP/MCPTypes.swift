//
//  MCPTypes.swift
//  brain-md
//

import Foundation

// MARK: - JSON-RPC Base Types

public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: AnyCodableValue?
    public let method: String
    public let params: [String: AnyCodableValue]?
    
    public init(jsonrpc: String = "2.0", id: AnyCodableValue? = nil, method: String, params: [String: AnyCodableValue]? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: AnyCodableValue?
    public let result: AnyCodableValue?
    public let error: JSONRPCError?
    
    public init(jsonrpc: String = "2.0", id: AnyCodableValue?, result: AnyCodableValue? = nil, error: JSONRPCError? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct JSONRPCError: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: AnyCodableValue?
    
    public init(code: Int, message: String, data: AnyCodableValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
    
    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    public static let internalError = JSONRPCError(code: -32603, message: "Internal error")
}

// MARK: - AnyCodableValue

public enum AnyCodableValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])
    case null
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
            return
        }
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let i = try? container.decode(Int.self) {
            self = .int(i)
            return
        }
        if let d = try? container.decode(Double.self) {
            self = .double(d)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        if let arr = try? container.decode([AnyCodableValue].self) {
            self = .array(arr)
            return
        }
        if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(dict)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported AnyCodableValue")
        )
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .bool(let b):
            try container.encode(b)
        case .array(let a):
            try container.encode(a)
        case .dictionary(let d):
            try container.encode(d)
        case .null:
            try container.encodeNil()
        }
    }
    
    public subscript(key: String) -> AnyCodableValue? {
        if case .dictionary(let dict) = self {
            return dict[key]
        }
        return nil
    }
    
    public subscript(index: Int) -> AnyCodableValue? {
        if case .array(let arr) = self, index >= 0 && index < arr.count {
            return arr[index]
        }
        return nil
    }
    
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    
    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }
    
    public var doubleValue: Double? {
        if case .double(let d) = self { return d }
        return nil
    }
    
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    
    public var dictValue: [String: AnyCodableValue]? {
        if case .dictionary(let d) = self { return d }
        return nil
    }
    
    public var arrayValue: [AnyCodableValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

// MARK: - ExpressibleBy Literals

extension AnyCodableValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension AnyCodableValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension AnyCodableValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension AnyCodableValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension AnyCodableValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, AnyCodableValue)...) {
        self = .dictionary(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension AnyCodableValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: AnyCodableValue...) {
        self = .array(elements)
    }
}

// MARK: - MCP Tool & Resource Types

public struct MCPTool: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: AnyCodableValue
    
    public init(name: String, description: String, inputSchema: AnyCodableValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPContent: Codable, Sendable, Equatable {
    public let type: String
    public let text: String
    
    public init(type: String = "text", text: String) {
        self.type = type
        self.text = text
    }
}

public struct MCPToolResult: Codable, Sendable, Equatable {
    public let content: [MCPContent]
    public let isError: Bool
    
    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
    
    public init(text: String, isError: Bool = false) {
        self.content = [MCPContent(text: text)]
        self.isError = isError
    }
}

public struct MCPResource: Codable, Sendable, Equatable {
    public let uri: String
    public let name: String
    public let description: String?
    public let mimeType: String?
    
    public init(uri: String, name: String, description: String? = nil, mimeType: String? = "text/markdown") {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }
}

public struct NoteListingItem: Codable, Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let lastModified: String
    
    public init(path: String, sizeBytes: Int64, lastModified: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
    }
}

public struct SearchResultItem: Codable, Sendable {
    public let path: String
    public let title: String
    public let snippet: String
    public let line: Int?
    
    public init(path: String, title: String, snippet: String, line: Int?) {
        self.path = path
        self.title = title
        self.snippet = snippet
        self.line = line
    }
}

public struct VaultStatsItem: Codable, Sendable {
    public let vaultPath: String
    public let totalNotes: Int
    public let totalWords: Int
    public let recentNotes: [String]
    
    public init(vaultPath: String, totalNotes: Int, totalWords: Int, recentNotes: [String]) {
        self.vaultPath = vaultPath
        self.totalNotes = totalNotes
        self.totalWords = totalWords
        self.recentNotes = recentNotes
    }
}
