//
//  BrainError.swift
//  brain-md
//

import Foundation

public enum BrainError: LocalizedError, Equatable, Sendable {
    case fileNotFound(path: String)
    case fileAlreadyExists(path: String)
    case invalidPath(path: String)
    case directoryTraversalBlocked(path: String)
    case directoryCreationFailed(path: String)
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case deleteFailed(path: String, reason: String)
    case invalidToolArgument(tool: String, argument: String)
    case unknownTool(name: String)
    case resourceNotFound(uri: String)
    case invalidResourceScheme(uri: String)
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found at path: '\(path)'"
        case .fileAlreadyExists(let path):
            return "A file already exists at path: '\(path)'"
        case .invalidPath(let path):
            return "Invalid file path: '\(path)'"
        case .directoryTraversalBlocked(let path):
            return "Security alert: Directory traversal attempt blocked for path '\(path)'"
        case .directoryCreationFailed(let path):
            return "Failed to create directory at path: '\(path)'"
        case .readFailed(let path, let reason):
            return "Failed to read file '\(path)': \(reason)"
        case .writeFailed(let path, let reason):
            return "Failed to write file '\(path)': \(reason)"
        case .deleteFailed(let path, let reason):
            return "Failed to delete file '\(path)': \(reason)"
        case .invalidToolArgument(let tool, let argument):
            return "Missing or invalid argument '\(argument)' for tool '\(tool)'"
        case .unknownTool(let name):
            return "Unknown MCP tool: '\(name)'"
        case .resourceNotFound(let uri):
            return "Resource not found for URI: '\(uri)'"
        case .invalidResourceScheme(let uri):
            return "Invalid resource URI scheme for '\(uri)'. Expected 'note://'"
        }
    }
}
