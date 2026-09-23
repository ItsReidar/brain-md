//
//  NoteGraphService.swift
//  brain-md
//

import Foundation
import SceneKit
import SwiftUI

// MARK: - Graph Models

public enum GraphEdgeType: Hashable, Sendable {
    case link
    case folderMember
    case tag(String)
    
    public var isTag: Bool {
        switch self {
        case .link, .folderMember: return false
        case .tag: return true
        }
    }
    
    public var isFolder: Bool {
        switch self {
        case .folderMember: return true
        case .link, .tag: return false
        }
    }
}

public struct GraphNode: Identifiable, Hashable, Sendable {
    public let id: String             // relativePath (e.g., "Projects/Roadmap.md") or "folder:Projects"
    public let title: String          // e.g., "Roadmap" or "Projects"
    public let relativePath: String
    public let tags: [String]
    public var degree: Int            // Total connected edges
    public var position: SIMD3<Float> // 3D coordinates
    public var velocity: SIMD3<Float> // Velocity for physics
    public var group: String          // Folder group or tag cluster for coloring
    public let isFolder: Bool         // True for folder hub nodes
    
    public init(
        id: String,
        title: String,
        relativePath: String,
        tags: [String] = [],
        degree: Int = 0,
        position: SIMD3<Float> = .zero,
        velocity: SIMD3<Float> = .zero,
        group: String = "Root",
        isFolder: Bool = false
    ) {
        self.id = id
        self.title = title
        self.relativePath = relativePath
        self.tags = tags
        self.degree = degree
        self.position = position
        self.velocity = velocity
        self.group = group
        self.isFolder = isFolder
    }
}

public struct GraphEdge: Identifiable, Hashable, Sendable {
    public let id: String
    public let sourceId: String
    public let targetId: String
    public let type: GraphEdgeType
    public let weight: Float
    
    public init(sourceId: String, targetId: String, type: GraphEdgeType, weight: Float = 1.0) {
        self.id = "\(sourceId)->\(targetId):\(type)"
        self.sourceId = sourceId
        self.targetId = targetId
        self.type = type
        self.weight = weight
    }
}

public struct GraphData: Sendable {
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]
    
    public init(nodes: [GraphNode] = [], edges: [GraphEdge] = []) {
        self.nodes = nodes
        self.edges = edges
    }
    
    public var nodeMap: [String: GraphNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }
    
    public var folderNodes: [GraphNode] {
        nodes.filter { $0.isFolder }
    }
    
    public var noteNodes: [GraphNode] {
        nodes.filter { !$0.isFolder }
    }
    
    public func connectedEdges(for nodeId: String) -> [GraphEdge] {
        edges.filter { $0.sourceId == nodeId || $0.targetId == nodeId }
    }
    
    public func neighbors(for nodeId: String) -> [String] {
        var result: Set<String> = []
        for edge in edges {
            if edge.sourceId == nodeId {
                result.insert(edge.targetId)
            } else if edge.targetId == nodeId {
                result.insert(edge.sourceId)
            }
        }
        return Array(result)
    }
}

// MARK: - Graph Service

public final class NoteGraphService: Sendable {
    public static let shared = NoteGraphService()
    
    public init() {}
    
    // MARK: - Link Extraction
    
    /// Extract all wikilinks `[[target]]` and `[[target|alias]]` from text
    public func extractWikilinks(from text: String) -> [String] {
        let pattern = #"\[\[(.*?)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        
        var targets: [String] = []
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let rawContent = nsString.substring(with: match.range(at: 1))
            
            // Handle pipe aliases: [[Target Note|Custom Alias]]
            let noteTarget = rawContent.components(separatedBy: "|")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Handle header anchors: [[Target Note#Section]]
            let cleanTarget = noteTarget.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !cleanTarget.isEmpty {
                targets.append(cleanTarget)
            }
        }
        return targets
    }
    
    /// Extract all local Markdown links `[text](target.md)` from text
    public func extractMarkdownLinks(from text: String) -> [String] {
        let pattern = #"\[(?:[^\]]*)\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        
        var targets: [String] = []
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            var rawLink = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Filter external URLs & anchors
            if rawLink.contains("://") || rawLink.hasPrefix("mailto:") || rawLink.hasPrefix("#") {
                continue
            }
            
            // Strip query or anchor
            if let hashIndex = rawLink.firstIndex(of: "#") {
                rawLink = String(rawLink[..<hashIndex])
            }
            if let queryIndex = rawLink.firstIndex(of: "?") {
                rawLink = String(rawLink[..<queryIndex])
            }
            
            // URL decode spaces
            let decoded = rawLink.removingPercentEncoding ?? rawLink
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !trimmed.isEmpty {
                targets.append(trimmed)
            }
        }
        return targets
    }
    
    // MARK: - Link Target Resolver
    
    /// Resolve a link string to a known note relativePath
    public func resolveLinkTarget(_ rawTarget: String, fromSourcePath sourcePath: String, allNotePaths: [String]) -> String? {
        let normalizedTarget = rawTarget.replacingOccurrences(of: "\\", with: "/")
        let targetWithExt = normalizedTarget.lowercased().hasSuffix(".md") ? normalizedTarget : "\(normalizedTarget).md"
        let targetWithoutExt = normalizedTarget.lowercased().hasSuffix(".md") ? String(normalizedTarget.dropLast(3)) : normalizedTarget
        
        // 1. Direct exact match
        for path in allNotePaths {
            if path.caseInsensitiveCompare(normalizedTarget) == .orderedSame ||
               path.caseInsensitiveCompare(targetWithExt) == .orderedSame {
                return path
            }
        }
        
        // 2. Relative resolution from source note directory
        let sourceDir = (sourcePath as NSString).deletingLastPathComponent
        let resolvedRelative: String
        if sourceDir.isEmpty || sourceDir == "." {
            resolvedRelative = targetWithExt
        } else {
            resolvedRelative = (sourceDir as NSString).appendingPathComponent(targetWithExt)
        }
        
        let standardized = (resolvedRelative as NSString).standardizingPath
        for path in allNotePaths {
            if path.caseInsensitiveCompare(standardized) == .orderedSame {
                return path
            }
        }
        
        // 3. Filename-only match (Obsidian default wikilink behavior)
        let targetName = (targetWithoutExt as NSString).lastPathComponent.lowercased()
        let matchingPaths = allNotePaths.filter { path in
            let pathName = (path as NSString).lastPathComponent
            let baseName = pathName.lowercased().hasSuffix(".md") ? String(pathName.dropLast(3)).lowercased() : pathName.lowercased()
            return baseName == targetName
        }
        
        if matchingPaths.count == 1 {
            return matchingPaths[0]
        } else if matchingPaths.count > 1 {
            // Prioritize closest folder match
            let sourceFolder = (sourcePath as NSString).deletingLastPathComponent
            if let inSameFolder = matchingPaths.first(where: { ($0 as NSString).deletingLastPathComponent == sourceFolder }) {
                return inSameFolder
            }
            return matchingPaths.first
        }
        
        return nil
    }
    
    // MARK: - Build Graph
    
    /// Builds nodes and edges from vault notes, creating folder hubs and clustering
    public func buildGraph(
        notePaths: [String],
        noteContents: [String: String],
        noteTags: [String: [String]] = [:],
        includeTags: Bool = true
    ) -> GraphData {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        var edgeSet: Set<String> = []
        var nodeDegrees: [String: Int] = [:]
        
        // 1. Discover all unique folders
        var folderSet: Set<String> = []
        for path in notePaths {
            var dir = (path as NSString).deletingLastPathComponent
            while !dir.isEmpty && dir != "." {
                folderSet.insert(dir)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        
        // 2. Create Folder Hub Nodes
        for folder in folderSet.sorted() {
            let folderId = "folder:\(folder)"
            let folderName = (folder as NSString).lastPathComponent
            let group = folder.components(separatedBy: "/")[0]
            
            nodes.append(GraphNode(
                id: folderId,
                title: folderName,
                relativePath: folder,
                tags: [],
                group: group,
                isFolder: true
            ))
            nodeDegrees[folderId] = 0
            
            // Connect subfolder to parent folder if nested
            let parentDir = (folder as NSString).deletingLastPathComponent
            if !parentDir.isEmpty && parentDir != "." {
                let parentId = "folder:\(parentDir)"
                let edgeKey = "\(parentId)->\(folderId)"
                if !edgeSet.contains(edgeKey) {
                    edgeSet.insert(edgeKey)
                    edges.append(GraphEdge(sourceId: parentId, targetId: folderId, type: .folderMember, weight: 1.8))
                    nodeDegrees[parentId, default: 0] += 1
                    nodeDegrees[folderId, default: 0] += 1
                }
            }
        }
        
        // 3. Create Note Nodes and link them to their parent folder hub
        for path in notePaths {
            let fileName = (path as NSString).lastPathComponent
            let title = fileName.lowercased().hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
            let tags = noteTags[path] ?? []
            
            let components = path.components(separatedBy: "/")
            let group = components.count > 1 ? components[0] : "Root"
            
            nodes.append(GraphNode(
                id: path,
                title: title,
                relativePath: path,
                tags: tags,
                group: group,
                isFolder: false
            ))
            nodeDegrees[path] = 0
            
            let parentFolder = (path as NSString).deletingLastPathComponent
            if !parentFolder.isEmpty && parentFolder != "." {
                let folderId = "folder:\(parentFolder)"
                let edgeKey = "\(folderId)->\(path)"
                if !edgeSet.contains(edgeKey) {
                    edgeSet.insert(edgeKey)
                    edges.append(GraphEdge(sourceId: folderId, targetId: path, type: .folderMember, weight: 2.0))
                    nodeDegrees[folderId, default: 0] += 1
                    nodeDegrees[path, default: 0] += 1
                }
            }
        }
        
        let validPathsSet = Set(notePaths)
        
        // 4. Extract explicit links between notes
        for path in notePaths {
            guard let content = noteContents[path] else { continue }
            
            let wikilinks = extractWikilinks(from: content)
            let mdLinks = extractMarkdownLinks(from: content)
            let allRawLinks = wikilinks + mdLinks
            
            for rawLink in allRawLinks {
                if let targetPath = resolveLinkTarget(rawLink, fromSourcePath: path, allNotePaths: notePaths),
                   targetPath != path,
                   validPathsSet.contains(targetPath) {
                    
                    let edgeKey1 = "\(path)->\(targetPath)"
                    let edgeKey2 = "\(targetPath)->\(path)"
                    
                    if !edgeSet.contains(edgeKey1) && !edgeSet.contains(edgeKey2) {
                        edgeSet.insert(edgeKey1)
                        edges.append(GraphEdge(sourceId: path, targetId: targetPath, type: .link, weight: 1.2))
                        nodeDegrees[path, default: 0] += 1
                        nodeDegrees[targetPath, default: 0] += 1
                    }
                }
            }
        }
        
        // 5. Connect shared tags if enabled
        if includeTags {
            var tagToNotes: [String: [String]] = [:]
            for (path, tags) in noteTags {
                for tag in tags {
                    let cleanTag = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !cleanTag.isEmpty {
                        tagToNotes[cleanTag, default: []].append(path)
                    }
                }
            }
            
            for (tag, paths) in tagToNotes {
                guard paths.count > 1 else { continue }
                let limit = min(paths.count, 6)
                for i in 0..<limit {
                    for j in (i + 1)..<limit {
                        let p1 = paths[i]
                        let p2 = paths[j]
                        let edgeKey1 = "\(p1)->\(p2)"
                        let edgeKey2 = "\(p2)->\(p1)"
                        
                        if !edgeSet.contains(edgeKey1) && !edgeSet.contains(edgeKey2) {
                            edgeSet.insert(edgeKey1)
                            edges.append(GraphEdge(sourceId: p1, targetId: p2, type: .tag(tag), weight: 0.4))
                            nodeDegrees[p1, default: 0] += 1
                            nodeDegrees[p2, default: 0] += 1
                        }
                    }
                }
            }
        }
        
        // 6. Update node degrees
        for i in 0..<nodes.count {
            let id = nodes[i].id
            nodes[i].degree = nodeDegrees[id, default: 0]
        }
        
        // 7. Run 3D Force-Directed Simulation with Center-Outward Clustering
        nodes = simulate3DLayout(nodes: nodes, edges: edges)
        
        return GraphData(nodes: nodes, edges: edges)
    }
    
    // MARK: - 3D Force-Directed Layout Simulation (Center-Outward)
    
    public func simulate3DLayout(
        nodes: [GraphNode],
        edges: [GraphEdge],
        iterations: Int = 130
    ) -> [GraphNode] {
        guard !nodes.isEmpty else { return [] }
        var resultNodes = nodes
        let n = resultNodes.count
        
        var idToIndex: [String: Int] = [:]
        for (idx, node) in resultNodes.enumerated() {
            idToIndex[node.id] = idx
        }
        
        // 1. Separate folders and notes for center-outward seed layout
        let folderIndices = resultNodes.indices.filter { resultNodes[$0].isFolder }
        let numFolders = max(1, folderIndices.count)
        let phi = Float.pi * (3.0 - sqrt(5.0)) // Golden angle
        
        // Folder hubs placed in inner core
        let coreRadius: Float = max(2.5, sqrt(Float(numFolders)) * 2.8)
        for (i, folderIdx) in folderIndices.enumerated() {
            let y = 1.0 - (Float(i) / Float(max(1, numFolders - 1))) * 2.0
            let radiusAtY = sqrt(max(0, 1.0 - y * y))
            let theta = phi * Float(i)
            
            let x = cos(theta) * radiusAtY
            let z = sin(theta) * radiusAtY
            resultNodes[folderIdx].position = SIMD3<Float>(x, y, z) * coreRadius
            resultNodes[folderIdx].velocity = .zero
        }
        
        // Notes initialized radiating outwards from their parent folder hub
        for i in 0..<n {
            guard !resultNodes[i].isFolder else { continue }
            let parentFolder = (resultNodes[i].relativePath as NSString).deletingLastPathComponent
            let folderId = "folder:\(parentFolder)"
            
            let center: SIMD3<Float>
            if let fIdx = idToIndex[folderId] {
                center = resultNodes[fIdx].position
            } else {
                center = .zero
            }
            
            // Random direction outward from folder center
            let u = Float.random(in: 0...1)
            let v = Float.random(in: 0...1)
            let theta = u * 2.0 * Float.pi
            let phiAngle = acos(2.0 * v - 1.0)
            let r = Float.random(in: 1.8...3.8)
            
            let dir = SIMD3<Float>(
                sin(phiAngle) * cos(theta),
                sin(phiAngle) * sin(theta),
                cos(phiAngle)
            )
            resultNodes[i].position = center + dir * r
            resultNodes[i].velocity = .zero
        }
        
        // Simulation physics constants
        let repulsionK: Float = 75.0
        let noteSpringLength: Float = 3.8
        let folderSpringLength: Float = 4.5
        let springK: Float = 0.12
        let centerGravityK: Float = 0.045
        let folderGravityK: Float = 0.08
        let damping: Float = 0.78
        let dt: Float = 0.35
        
        for _ in 0..<iterations {
            var forces = [SIMD3<Float>](repeating: .zero, count: n)
            
            // Repulsion between all node pairs
            for i in 0..<n {
                let p1 = resultNodes[i].position
                for j in (i + 1)..<n {
                    let p2 = resultNodes[j].position
                    let delta = p1 - p2
                    let distSq = max(0.4, delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
                    let dist = sqrt(distSq)
                    
                    // Stronger repulsion for folder hubs
                    let repMultiplier: Float = (resultNodes[i].isFolder || resultNodes[j].isFolder) ? 1.8 : 1.0
                    let forceMag = (repulsionK * repMultiplier) / distSq
                    let forceDir = delta / dist
                    let f = forceDir * forceMag
                    
                    forces[i] += f
                    forces[j] -= f
                }
            }
            
            // Spring attraction along edges
            for edge in edges {
                guard let idx1 = idToIndex[edge.sourceId],
                      let idx2 = idToIndex[edge.targetId] else { continue }
                
                let p1 = resultNodes[idx1].position
                let p2 = resultNodes[idx2].position
                let delta = p2 - p1
                let dist = max(0.1, sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z))
                
                let targetLen = edge.type.isFolder ? folderSpringLength : noteSpringLength
                let displacement = dist - targetLen
                let forceMag = springK * displacement * edge.weight
                let forceDir = delta / dist
                let f = forceDir * forceMag
                
                forces[idx1] += f
                forces[idx2] -= f
            }
            
            // Center gravity (stronger on folder hubs to keep cluster centered)
            for i in 0..<n {
                let gravK = resultNodes[i].isFolder ? folderGravityK : centerGravityK
                forces[i] -= resultNodes[i].position * gravK
            }
            
            // Update velocities and positions
            for i in 0..<n {
                let mass: Float = resultNodes[i].isFolder ? 2.5 : 1.0
                resultNodes[i].velocity = (resultNodes[i].velocity + (forces[i] / mass) * dt) * damping
                resultNodes[i].position += resultNodes[i].velocity * dt
            }
        }
        
        return resultNodes
    }
}
