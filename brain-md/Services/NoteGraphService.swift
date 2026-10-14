//
//  NoteGraphService.swift
//  brain-md
//

import Foundation
import SceneKit
import SwiftUI

// MARK: - Graph Models

nonisolated public enum GraphEdgeType: Hashable, Sendable {
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

nonisolated public struct GraphNode: Identifiable, Hashable, Sendable {
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

nonisolated public struct GraphEdge: Identifiable, Hashable, Sendable {
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

nonisolated public struct GraphData: Sendable {
    public var nodes: [GraphNode] {
        didSet {
            nodeMap = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    public var edges: [GraphEdge]
    public private(set) var nodeMap: [String: GraphNode]
    
    public init(nodes: [GraphNode] = [], edges: [GraphEdge] = []) {
        self.nodes = nodes
        self.edges = edges
        self.nodeMap = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

nonisolated public struct LinkResolutionIndex: Sendable {
    let exactPathMap: [String: String]
    let basenameToPaths: [String: [String]]
    
    public init(allNotePaths: [String]) {
        var exact: [String: String] = [:]
        exact.reserveCapacity(allNotePaths.count)
        var byBase: [String: [String]] = [:]
        byBase.reserveCapacity(allNotePaths.count)
        
        for path in allNotePaths {
            let lowerPath = path.lowercased()
            if exact[lowerPath] == nil {
                exact[lowerPath] = path
            }
            let fileName = (path as NSString).lastPathComponent
            let lowerFile = fileName.lowercased()
            let base = lowerFile.hasSuffix(".md") ? String(lowerFile.dropLast(3)) : lowerFile
            byBase[base, default: []].append(path)
        }
        self.exactPathMap = exact
        self.basenameToPaths = byBase
    }
}

nonisolated public final class NoteGraphService: Sendable {
    public static let shared = NoteGraphService()
    
    private static let wikilinkRegex = try! NSRegularExpression(pattern: #"\[\[(.*?)\]\]"#)
    private static let markdownLinkRegex = try! NSRegularExpression(pattern: #"\[(?:[^\]]*)\]\(([^)]+)\)"#)
    
    public init() {}
    
    // MARK: - Link Extraction
    
    /// Extract all wikilinks `[[target]]` and `[[target|alias]]` from text
    public func extractWikilinks(from text: String) -> [String] {
        guard text.contains("[[") else { return [] }
        let nsString = text as NSString
        let matches = Self.wikilinkRegex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
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
        guard text.contains("](") else { return [] }
        let nsString = text as NSString
        let matches = Self.markdownLinkRegex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
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
        let index = LinkResolutionIndex(allNotePaths: allNotePaths)
        return resolveLinkTarget(rawTarget, fromSourcePath: sourcePath, index: index)
    }
    
    /// Resolve a link string in O(1) using a precomputed `LinkResolutionIndex`.
    public func resolveLinkTarget(_ rawTarget: String, fromSourcePath sourcePath: String, index: LinkResolutionIndex) -> String? {
        let normalizedTarget = rawTarget.replacingOccurrences(of: "\\", with: "/")
        let lowerTarget = normalizedTarget.lowercased()
        let hasMdSuffix = lowerTarget.hasSuffix(".md")
        let targetWithExt = hasMdSuffix ? normalizedTarget : "\(normalizedTarget).md"
        let lowerTargetWithExt = hasMdSuffix ? lowerTarget : "\(lowerTarget).md"
        let targetWithoutExt = hasMdSuffix ? String(normalizedTarget.dropLast(3)) : normalizedTarget
        
        // 1. Direct exact match (O(1))
        if let exact = index.exactPathMap[lowerTarget] ?? index.exactPathMap[lowerTargetWithExt] {
            return exact
        }
        
        // 2. Relative resolution from source note directory (O(1))
        let sourceDir = (sourcePath as NSString).deletingLastPathComponent
        let resolvedRelative: String
        if sourceDir.isEmpty || sourceDir == "." {
            resolvedRelative = targetWithExt
        } else {
            resolvedRelative = (sourceDir as NSString).appendingPathComponent(targetWithExt)
        }
        
        let standardizedLower = (resolvedRelative as NSString).standardizingPath.lowercased()
        if let relativeMatch = index.exactPathMap[standardizedLower] {
            return relativeMatch
        }
        
        // 3. Filename-only match (Obsidian default wikilink behavior, O(1) bucket lookup)
        let targetName = (targetWithoutExt as NSString).lastPathComponent.lowercased()
        guard let matchingPaths = index.basenameToPaths[targetName], !matchingPaths.isEmpty else {
            return nil
        }
        
        if matchingPaths.count == 1 {
            return matchingPaths[0]
        } else {
            let sourceFolder = (sourcePath as NSString).deletingLastPathComponent
            if let inSameFolder = matchingPaths.first(where: { ($0 as NSString).deletingLastPathComponent == sourceFolder }) {
                return inSameFolder
            }
            return matchingPaths[0]
        }
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
        let linkIndex = LinkResolutionIndex(allNotePaths: notePaths)
        
        // 4. Extract explicit links between notes
        for path in notePaths {
            guard let content = noteContents[path] else { continue }
            
            let wikilinks = extractWikilinks(from: content)
            let mdLinks = extractMarkdownLinks(from: content)
            let allRawLinks = wikilinks + mdLinks
            
            for rawLink in allRawLinks {
                if let targetPath = resolveLinkTarget(rawLink, fromSourcePath: path, index: linkIndex),
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
        
        // Extract flat contiguous arrays for SIMD speed and zero ARC traffic inside the hot loop
        var positions = resultNodes.map { $0.position }
        var velocities = resultNodes.map { $0.velocity }
        let isFolderFlags = resultNodes.map { $0.isFolder }
        let masses: [Float] = isFolderFlags.map { $0 ? 2.5 : 1.0 }
        let gravities: [Float] = isFolderFlags.map { $0 ? folderGravityK : centerGravityK }
        
        // Pre-resolve edge endpoint indices once outside the iteration loop
        struct ResolvedEdge {
            let idx1: Int
            let idx2: Int
            let targetLen: Float
            let weight: Float
        }
        var resolvedEdges: [ResolvedEdge] = []
        resolvedEdges.reserveCapacity(edges.count)
        for edge in edges {
            guard let idx1 = idToIndex[edge.sourceId],
                  let idx2 = idToIndex[edge.targetId] else { continue }
            let targetLen = edge.type.isFolder ? folderSpringLength : noteSpringLength
            resolvedEdges.append(ResolvedEdge(idx1: idx1, idx2: idx2, targetLen: targetLen, weight: edge.weight))
        }
        
        let effectiveIterations: Int
        if n > 2000 {
            effectiveIterations = min(iterations, 45)
        } else if n > 600 {
            effectiveIterations = min(iterations, 75)
        } else {
            effectiveIterations = iterations
        }
        
        var forces = [SIMD3<Float>](repeating: .zero, count: n)
        let maxRepulsionWindow = 96
        
        for iter in 0..<effectiveIterations {
            for i in 0..<n { forces[i] = .zero }
            
            if n <= 350 {
                // Exact all-pairs repulsion for small/medium graphs
                for i in 0..<n {
                    let p1 = positions[i]
                    let isF1 = isFolderFlags[i]
                    for j in (i + 1)..<n {
                        let p2 = positions[j]
                        let delta = p1 - p2
                        let distSq = max(0.4, delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
                        let dist = sqrt(distSq)
                        let repMultiplier: Float = (isF1 || isFolderFlags[j]) ? 1.8 : 1.0
                        let f = (delta / dist) * ((repulsionK * repMultiplier) / distSq)
                        forces[i] += f
                        forces[j] -= f
                    }
                }
            } else {
                // 1. Exact folder-hub repulsion against all nodes (preserves global cluster separation)
                for fIdx in folderIndices {
                    let pf = positions[fIdx]
                    for j in 0..<n where j != fIdx {
                        if isFolderFlags[j] && j < fIdx { continue }
                        let pj = positions[j]
                        let delta = pf - pj
                        let distSq = max(0.4, delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
                        let dist = sqrt(distSq)
                        let f = (delta / dist) * ((repulsionK * 1.8) / distSq)
                        forces[fIdx] += f
                        forces[j] -= f
                    }
                }
                
                // 2. Bounded-window + strided sampling repulsion for note nodes (O(N) per iteration)
                let strideStep = max(1, n / maxRepulsionWindow)
                let offset = iter % strideStep
                let scaleFactor = Float(strideStep) * 0.65
                for i in 0..<n where !isFolderFlags[i] {
                    let p1 = positions[i]
                    var j = i + 1 + offset
                    while j < n {
                        if !isFolderFlags[j] {
                            let p2 = positions[j]
                            let delta = p1 - p2
                            let distSq = max(0.4, delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
                            if distSq < 144.0 {
                                let dist = sqrt(distSq)
                                let f = (delta / dist) * ((repulsionK * scaleFactor) / distSq)
                                forces[i] += f
                                forces[j] -= f
                            }
                        }
                        j += strideStep
                    }
                }
            }
            
            // Spring attraction along pre-resolved edges
            for edge in resolvedEdges {
                let p1 = positions[edge.idx1]
                let p2 = positions[edge.idx2]
                let delta = p2 - p1
                let dist = max(0.1, sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z))
                let displacement = dist - edge.targetLen
                let forceMag = springK * displacement * edge.weight
                let f = (delta / dist) * forceMag
                forces[edge.idx1] += f
                forces[edge.idx2] -= f
            }
            
            // Center gravity + velocity/position integration
            for i in 0..<n {
                forces[i] -= positions[i] * gravities[i]
                velocities[i] = (velocities[i] + (forces[i] / masses[i]) * dt) * damping
                positions[i] += velocities[i] * dt
            }
        }
        
        for i in 0..<n {
            resultNodes[i].position = positions[i]
            resultNodes[i].velocity = velocities[i]
        }
        
        return resultNodes
    }
}
