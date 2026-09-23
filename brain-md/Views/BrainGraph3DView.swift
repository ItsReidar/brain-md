//
//  BrainGraph3DView.swift
//  brain-md
//

import SwiftUI
import SceneKit
import AppKit

// MARK: - Custom Trackball SCNView

public final class TrackballSCNView: SCNView {
    var graphRootNode: SCNNode?
    var cameraNode: SCNNode?
    var onNodeClicked: ((String?) -> Void)?
    
    // Inertia & Spin Physics State
    var spinVelocity: CGPoint = .zero
    private var inertiaTimer: Timer?
    private let friction: CGFloat = 0.93
    private let spinSensitivity: CGFloat = 0.007
    
    // Zoom constraints
    var minZoom: CGFloat = 10.0
    var maxZoom: CGFloat = 120.0
    
    // Mouse drag vs click tracking
    private var mouseDownLocation: NSPoint?
    private var isDraggingGraph: Bool = false
    private let dragThreshold: CGFloat = 3.5
    
    override public init(frame: NSRect, options: [String : Any]? = nil) {
        super.init(frame: frame, options: options)
    }
    
    public convenience init() {
        self.init(frame: .zero, options: nil)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    deinit {
        inertiaTimer?.invalidate()
    }
    
    // MARK: - Direct Mouse Lifecycle (Drag Spin & Click)
    
    override public func mouseDown(with event: NSEvent) {
        stopInertia()
        mouseDownLocation = event.locationInWindow
        isDraggingGraph = false
    }
    
    override public func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, let root = graphRootNode else { return }
        let current = event.locationInWindow
        let dx = current.x - start.x
        let dy = current.y - start.y
        let distance = sqrt(dx * dx + dy * dy)
        
        if distance > dragThreshold {
            isDraggingGraph = true
        }
        
        if isDraggingGraph {
            // Smooth trackball spin
            root.eulerAngles.y += CGFloat(event.deltaX) * spinSensitivity
            root.eulerAngles.x += CGFloat(event.deltaY) * spinSensitivity
            
            spinVelocity = CGPoint(
                x: CGFloat(event.deltaX) * spinSensitivity * 0.9,
                y: CGFloat(event.deltaY) * spinSensitivity * 0.9
            )
        }
    }
    
    override public func mouseUp(with event: NSEvent) {
        let wasDragging = isDraggingGraph
        mouseDownLocation = nil
        isDraggingGraph = false
        
        if wasDragging {
            startInertia()
            return
        }
        
        // Clean click without drag
        let location = convert(event.locationInWindow, from: nil)
        handleNodeClick(at: location)
    }
    
    private func startInertia() {
        stopInertia()
        guard abs(spinVelocity.x) > 0.0005 || abs(spinVelocity.y) > 0.0005 else { return }
        
        inertiaTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self, let root = self.graphRootNode else {
                timer.invalidate()
                return
            }
            
            root.eulerAngles.y += self.spinVelocity.x
            root.eulerAngles.x += self.spinVelocity.y
            
            self.spinVelocity.x *= self.friction
            self.spinVelocity.y *= self.friction
            
            if abs(self.spinVelocity.x) < 0.0002 && abs(self.spinVelocity.y) < 0.0002 {
                self.stopInertia()
            }
        }
    }
    
    private func stopInertia() {
        inertiaTimer?.invalidate()
        inertiaTimer = nil
        spinVelocity = .zero
    }
    
    // MARK: - Zooming via Scroll (Cursor-Anchored)
    
    override public func scrollWheel(with event: NSEvent) {
        guard let camera = cameraNode else {
            super.scrollWheel(with: event)
            return
        }
        
        let delta = event.deltaY
        guard abs(delta) > 0.0001 else { return }
        
        let mousePoint = convert(event.locationInWindow, from: nil)
        
        // Find 3D focal point under mouse cursor
        let hits = hitTest(mousePoint, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true
        ])
        
        let focalPoint: SCNVector3
        if let hit = hits.first(where: { $0.node.name?.hasPrefix("node:") == true || $0.node.name?.hasPrefix("label:") == true }) {
            focalPoint = hit.worldCoordinates
        } else {
            let pNear = unprojectPoint(SCNVector3(mousePoint.x, mousePoint.y, 0.0))
            let pFar = unprojectPoint(SCNVector3(mousePoint.x, mousePoint.y, 1.0))
            let dz = pFar.z - pNear.z
            if abs(dz) > 0.0001 {
                let t = -pNear.z / dz
                focalPoint = SCNVector3(
                    pNear.x + t * (pFar.x - pNear.x),
                    pNear.y + t * (pFar.y - pNear.y),
                    0.0
                )
            } else {
                focalPoint = SCNVector3Zero
            }
        }
        
        let zoomSpeed: CGFloat = 0.5
        let oldZ = camera.position.z
        let rawNewZ = oldZ - (delta * zoomSpeed)
        let newZ = max(minZoom, min(maxZoom, rawNewZ))
        
        guard abs(oldZ - focalPoint.z) > 0.0001 else {
            camera.position.z = newZ
            return
        }
        
        // Perspective scaling ratio: preserve focalPoint under mouse cursor
        let r = (newZ - focalPoint.z) / (oldZ - focalPoint.z)
        var newX = focalPoint.x - (focalPoint.x - camera.position.x) * r
        var newY = focalPoint.y - (focalPoint.y - camera.position.y) * r
        
        // When zooming out toward maxZoom, smoothly pull camera back toward center (0, 0)
        if newZ > oldZ {
            let pullRange = maxZoom - minZoom
            if pullRange > 0 {
                let outProgress = max(0.0, min(1.0, (newZ - minZoom) / pullRange))
                let damping = pow(outProgress, 2.0) * 0.15
                newX *= (1.0 - damping)
                newY *= (1.0 - damping)
            }
        }
        
        // Clamp X and Y to avoid extreme runaway offsets
        let maxPan: CGFloat = maxZoom * 0.75
        camera.position = SCNVector3(
            max(-maxPan, min(maxPan, newX)),
            max(-maxPan, min(maxPan, newY)),
            newZ
        )
    }
    
    // MARK: - Resilient Node Click Resolution
    
    private func handleNodeClick(at location: CGPoint) {
        // 1. Raycast with .all to pierce through foreground edges
        let hits = hitTest(location, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: true
        ])
        
        for hit in hits {
            if let nodeId = extractNodeId(from: hit.node) {
                onNodeClicked?(nodeId)
                return
            }
        }
        
        // 2. Screen-Space Proximity Snapping for small note dots (< 18 points)
        if let snappedNodeId = findClosestNodeToScreen(point: location, maxDistance: 18.0) {
            onNodeClicked?(snappedNodeId)
            return
        }
        
        // 3. Clicked true empty space -> deselect
        onNodeClicked?(nil)
    }
    
    private func extractNodeId(from node: SCNNode) -> String? {
        var current: SCNNode? = node
        while let n = current {
            if let name = n.name {
                if name.hasPrefix("node:") {
                    return String(name.dropFirst(5))
                } else if name.hasPrefix("label:") {
                    return String(name.dropFirst(6))
                }
            }
            current = n.parent
        }
        return nil
    }
    
    private func findClosestNodeToScreen(point: CGPoint, maxDistance: CGFloat) -> String? {
        guard let root = graphRootNode else { return nil }
        
        var closestId: String? = nil
        var minDistance = maxDistance
        
        for child in root.childNodes {
            guard let name = child.name, name.hasPrefix("node:") else { continue }
            guard child.opacity > 0.2 else { continue }
            
            let worldPos = child.presentation.worldPosition
            let screenPos = projectPoint(worldPos)
            
            // Only consider nodes in front of camera
            guard screenPos.z > 0 && screenPos.z < 1.0 else { continue }
            
            let dx = CGFloat(screenPos.x) - point.x
            let dy = CGFloat(screenPos.y) - point.y
            let dist = sqrt(dx * dx + dy * dy)
            
            if dist < minDistance {
                minDistance = dist
                closestId = String(name.dropFirst(5))
            }
        }
        
        return closestId
    }
}

// MARK: - SceneKit 3D View (NSViewRepresentable)

public struct Graph3DSceneView: NSViewRepresentable {
    public let graphData: GraphData
    public let searchFilter: String
    public let selectedNodeId: String?
    public let onNodeSelected: (GraphNode?) -> Void
    
    public init(
        graphData: GraphData,
        searchFilter: String,
        selectedNodeId: String?,
        onNodeSelected: @escaping (GraphNode?) -> Void
    ) {
        self.graphData = graphData
        self.searchFilter = searchFilter
        self.selectedNodeId = selectedNodeId
        self.onNodeSelected = onNodeSelected
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeNSView(context: Context) -> TrackballSCNView {
        let scnView = TrackballSCNView()
        let scene = SCNScene()
        scnView.scene = scene
        scnView.antialiasingMode = SCNAntialiasingMode.multisampling4X
        scnView.autoenablesDefaultLighting = false
        
        // Background appearance (adaptive soft canvas)
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        scnView.backgroundColor = isDark
            ? NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
            : NSColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1.0)
        
        // Ambient Light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = isDark ? 650 : 850
        ambientLight.light?.color = NSColor(white: 0.9, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)
        
        // Directional Key Light
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 900
        keyLight.eulerAngles = SCNVector3(-0.6, 0.4, 0)
        scene.rootNode.addChildNode(keyLight)
        
        // Fill Light
        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .omni
        fillLight.light?.intensity = 500
        fillLight.position = SCNVector3(0, -10, 20)
        scene.rootNode.addChildNode(fillLight)
        
        // Graph Container Root (spins when user drags)
        let graphRoot = SCNNode()
        graphRoot.name = "graphRoot"
        scene.rootNode.addChildNode(graphRoot)
        scnView.graphRootNode = graphRoot
        
        // Camera
        let cameraNode = SCNNode()
        cameraNode.name = "defaultCamera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.5
        cameraNode.camera?.zFar = 500
        
        // Calculate framing based on node bounding distance
        let maxDist = context.coordinator.calculateMaxRadius(for: graphData)
        let targetZ = max(20.0, maxDist * 2.3)
        cameraNode.position = SCNVector3(0, 0, targetZ)
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
        scnView.cameraNode = cameraNode
        scnView.minZoom = 8.0
        scnView.maxZoom = max(60.0, targetZ * 2.5)
        
        // Hook up click callback
        let coordinator = context.coordinator
        scnView.onNodeClicked = { [weak coordinator] (clickedId: String?) in
            guard let coordinator = coordinator else { return }
            if let id = clickedId, let node = coordinator.parent.graphData.nodeMap[id] {
                coordinator.parent.onNodeSelected(node)
            } else {
                coordinator.parent.onNodeSelected(nil)
            }
        }
        
        context.coordinator.scnView = scnView
        context.coordinator.updateSceneGraph(in: graphRoot, data: graphData, filter: searchFilter, selectedId: selectedNodeId)
        
        // Enable continuous rendering for fluid organic floating and spin physics
        scnView.isPlaying = true
        scnView.delegate = context.coordinator
        
        return scnView
    }
    
    public func updateNSView(_ nsView: TrackballSCNView, context: Context) {
        guard let graphRoot = nsView.graphRootNode else { return }
        context.coordinator.parent = self
        context.coordinator.updateSceneGraph(in: graphRoot, data: graphData, filter: searchFilter, selectedId: selectedNodeId)
    }
    
    // MARK: - Coordinator
    
    public final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var parent: Graph3DSceneView
        weak var scnView: TrackballSCNView?
        private var lastRenderedDataId: String = ""
        private var lastFilter: String = ""
        private var lastSelectedId: String? = nil
        
        // Fluid animation state
        private struct NodeAnimState {
            let basePos: SCNVector3
            let isFolder: Bool
            let phase: Double
            var currentOffset: SCNVector3 = SCNVector3Zero
        }
        
        private var animStates: [String: NodeAnimState] = [:]
        private var edgeNodeMap: [(id: String, sourceId: String, targetId: String, lineNode: SCNNode)] = []
        private var lastAnimTime: TimeInterval = 0
        
        init(_ parent: Graph3DSceneView) {
            self.parent = parent
        }
        
        func calculateMaxRadius(for data: GraphData) -> CGFloat {
            guard !data.nodes.isEmpty else { return 12.0 }
            var maxR: Float = 0
            for node in data.nodes {
                let r = sqrt(node.position.x * node.position.x + node.position.y * node.position.y + node.position.z * node.position.z)
                if r > maxR { maxR = r }
            }
            return CGFloat(maxR)
        }
        
        func updateSceneGraph(in graphRoot: SCNNode, data: GraphData, filter: String, selectedId: String?) {
            let dataSignature = "\(data.nodes.count)-\(data.edges.count)"
            let needsRebuild = (dataSignature != lastRenderedDataId)
            
            if needsRebuild {
                lastRenderedDataId = dataSignature
                rebuildGraphNodes(in: graphRoot, data: data)
                
                // Refocus camera to fit new cluster size
                let maxDist = calculateMaxRadius(for: data)
                let targetZ = max(20.0, maxDist * 2.3)
                if let camera = scnView?.cameraNode {
                    camera.position = SCNVector3(0, 0, targetZ)
                    scnView?.maxZoom = max(60.0, targetZ * 2.5)
                }
            }
            
            if needsRebuild || filter != lastFilter || selectedId != lastSelectedId {
                lastFilter = filter
                lastSelectedId = selectedId
                applyHighlightAndOpacity(in: graphRoot, data: data, filter: filter, selectedId: selectedId)
            }
        }
        
        private func rebuildGraphNodes(in graphRoot: SCNNode, data: GraphData) {
            graphRoot.childNodes.forEach { $0.removeFromParentNode() }
            animStates.removeAll()
            edgeNodeMap.removeAll()
            lastAnimTime = 0
            
            // Vibrant glossy cluster color palette (matching reference)
            let colorPalette: [NSColor] = [
                NSColor(red: 0.95, green: 0.25, blue: 0.65, alpha: 1.0), // Magenta / Hot Pink
                NSColor(red: 0.35, green: 0.65, blue: 1.00, alpha: 1.0), // Sky Blue
                NSColor(red: 0.30, green: 0.85, blue: 0.60, alpha: 1.0), // Emerald Green
                NSColor(red: 0.98, green: 0.75, blue: 0.25, alpha: 1.0), // Amber / Gold
                NSColor(red: 0.65, green: 0.40, blue: 0.95, alpha: 1.0), // Purple / Violet
                NSColor(red: 0.25, green: 0.85, blue: 0.90, alpha: 1.0), // Cyan / Turquoise
                NSColor(red: 0.95, green: 0.50, blue: 0.30, alpha: 1.0)  // Coral / Orange
            ]
            
            var groupColors: [String: NSColor] = [:]
            var colorIndex = 0
            
            let camera = scnView?.cameraNode ?? scnView?.scene?.rootNode.childNode(withName: "defaultCamera", recursively: true)
            
            // 1. Build Spheres (Folder Hubs + Notes)
            for node in data.nodes {
                let group = node.group
                if groupColors[group] == nil {
                    groupColors[group] = colorPalette[colorIndex % colorPalette.count]
                    colorIndex += 1
                }
                let color = groupColors[group]!
                
                let radius: CGFloat
                let sphere: SCNSphere
                let material = SCNMaterial()
                
                if node.isFolder {
                    // Larger, prominent matte folder hub
                    radius = max(0.95, 0.95 + sqrt(CGFloat(node.degree)) * 0.12)
                    sphere = SCNSphere(radius: radius)
                    sphere.segmentCount = 36
                    
                    material.lightingModel = .lambert
                    material.diffuse.contents = color
                    material.specular.contents = NSColor.clear
                    material.shininess = 0.0
                    material.emission.contents = NSColor.clear
                } else {
                    // Crisp, matte note node
                    radius = max(0.28, 0.28 + sqrt(CGFloat(node.degree)) * 0.08)
                    sphere = SCNSphere(radius: radius)
                    sphere.segmentCount = 24
                    
                    material.lightingModel = .lambert
                    material.diffuse.contents = color
                    material.specular.contents = NSColor.clear
                    material.shininess = 0.0
                    material.emission.contents = NSColor.clear
                }
                
                sphere.materials = [material]
                
                let basePos = SCNVector3(CGFloat(node.position.x), CGFloat(node.position.y), CGFloat(node.position.z))
                let phase = Double(animStates.count) * 1.61803398875
                animStates[node.id] = NodeAnimState(
                    basePos: basePos,
                    isFolder: node.isFolder,
                    phase: phase,
                    currentOffset: SCNVector3Zero
                )
                
                let scnNode = SCNNode(geometry: sphere)
                scnNode.name = "node:\(node.id)"
                scnNode.position = basePos
                
                // Add Billboard Badge Label for folders and connected notes
                let showLabel = node.isFolder || node.degree >= 2 || data.nodes.count <= 35
                if showLabel {
                    let badgeNode = createLabelBadgeNode(title: node.title, isFolder: node.isFolder, radius: radius, nodeId: node.id, cameraNode: camera)
                    scnNode.addChildNode(badgeNode)
                }
                
                graphRoot.addChildNode(scnNode)
            }
            
            // 2. Build Connection Lines (Synapses)
            let nodeMap = data.nodeMap
            for edge in data.edges {
                guard let sourceNode = nodeMap[edge.sourceId],
                      let targetNode = nodeMap[edge.targetId] else { continue }
                
                let p1 = SCNVector3(CGFloat(sourceNode.position.x), CGFloat(sourceNode.position.y), CGFloat(sourceNode.position.z))
                let p2 = SCNVector3(CGFloat(targetNode.position.x), CGFloat(targetNode.position.y), CGFloat(targetNode.position.z))
                
                let edgeColor: NSColor
                let opacity: CGFloat
                
                switch edge.type {
                case .folderMember:
                    // Soft structural link from folder to note
                    let group = sourceNode.isFolder ? sourceNode.group : targetNode.group
                    edgeColor = groupColors[group] ?? NSColor.gray
                    opacity = 0.22
                case .link:
                    // Direct explicit link between notes
                    edgeColor = NSColor(red: 0.35, green: 0.70, blue: 1.0, alpha: 0.6)
                    opacity = 0.50
                case .tag:
                    // Shared tag cluster connection
                    edgeColor = NSColor(red: 0.75, green: 0.45, blue: 0.95, alpha: 0.4)
                    opacity = 0.28
                }
                
                if let lineNode = createLineNode(from: p1, to: p2, color: edgeColor, opacity: opacity) {
                    lineNode.name = "edge:\(edge.id)"
                    graphRoot.addChildNode(lineNode)
                    edgeNodeMap.append((id: edge.id, sourceId: edge.sourceId, targetId: edge.targetId, lineNode: lineNode))
                }
            }
        }
        
        // MARK: - SCNSceneRendererDelegate (Fluid Organic Floating & Elastic Spin)
        
        public func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let view = scnView, let root = view.graphRootNode, !animStates.isEmpty else { return }
            
            let dt: Double
            if lastAnimTime == 0 {
                dt = 0.016
            } else {
                dt = min(0.05, max(0.001, time - lastAnimTime))
            }
            lastAnimTime = time
            
            let spinVel = view.spinVelocity
            let t = time
            
            // 1. Update node positions with harmonic float + rotational inertia lag
            var updatedPositions: [String: SCNVector3] = [:]
            
            for (nodeId, var state) in animStates {
                guard let scnNode = root.childNode(withName: "node:\(nodeId)", recursively: false) else { continue }
                
                // Ambient organic floating
                let amp: Double = state.isFolder ? 0.05 : 0.15
                let floatX = amp * sin(0.85 * t + state.phase)
                let floatY = amp * cos(0.65 * t + state.phase * 1.3)
                let floatZ = amp * sin(0.75 * t + state.phase * 0.7)
                
                // Rotational elastic lag (flexes against spin velocity)
                let lagMultiplier: Double = state.isFolder ? 0.35 : 1.25
                let targetLagX = -Double(spinVel.x) * lagMultiplier * 4.5
                let targetLagY = -Double(spinVel.y) * lagMultiplier * 4.5
                
                let targetOffsetX = floatX + targetLagX
                let targetOffsetY = floatY + targetLagY
                let targetOffsetZ = floatZ
                
                // Smooth spring-damper approach to target offset
                let blend = min(1.0, CGFloat(dt * 8.0))
                let newOffsetX = state.currentOffset.x + (CGFloat(targetOffsetX) - state.currentOffset.x) * blend
                let newOffsetY = state.currentOffset.y + (CGFloat(targetOffsetY) - state.currentOffset.y) * blend
                let newOffsetZ = state.currentOffset.z + (CGFloat(targetOffsetZ) - state.currentOffset.z) * blend
                
                let newOffset = SCNVector3(newOffsetX, newOffsetY, newOffsetZ)
                state.currentOffset = newOffset
                animStates[nodeId] = state
                
                let finalPos = SCNVector3(
                    state.basePos.x + newOffset.x,
                    state.basePos.y + newOffset.y,
                    state.basePos.z + newOffset.z
                )
                scnNode.position = finalPos
                updatedPositions[nodeId] = finalPos
            }
            
            // 2. Update dynamic edge line endpoints to track moving nodes
            for edge in edgeNodeMap {
                guard let p1 = updatedPositions[edge.sourceId],
                      let p2 = updatedPositions[edge.targetId] else { continue }
                
                let source = SCNGeometrySource(vertices: [p1, p2])
                let element = SCNGeometryElement(indices: [0, 1] as [Int32], primitiveType: .line)
                let newGeom = SCNGeometry(sources: [source], elements: [element])
                if let oldMat = edge.lineNode.geometry?.materials.first {
                    newGeom.materials = [oldMat]
                }
                edge.lineNode.geometry = newGeom
            }
        }
        
        private func createLineNode(from p1: SCNVector3, to p2: SCNVector3, color: NSColor, opacity: CGFloat) -> SCNNode? {
            let indices: [Int32] = [0, 1]
            let source = SCNGeometrySource(vertices: [p1, p2])
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let geom = SCNGeometry(sources: [source], elements: [element])
            
            let mat = SCNMaterial()
            mat.diffuse.contents = color
            mat.emission.contents = color.withAlphaComponent(0.2)
            mat.transparency = opacity
            geom.materials = [mat]
            
            let node = SCNNode(geometry: geom)
            return node
        }
        
        private func createLabelBadgeNode(title: String, isFolder: Bool, radius: CGFloat, nodeId: String, cameraNode: SCNNode?) -> SCNNode {
            let maxLen = isFolder ? 22 : 24
            let truncated = title.count > maxLen ? String(title.prefix(maxLen - 1)) + "…" : title
            let displayTitle = isFolder ? "📁  \(truncated)" : truncated
            
            let fontSize: CGFloat = isFolder ? 12.0 : 10.0
            let font = NSFont.systemFont(ofSize: fontSize, weight: isFolder ? .bold : .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let textSize = (displayTitle as NSString).size(withAttributes: attributes)
            
            let hPad: CGFloat = isFolder ? 10.0 : 7.5
            let vPad: CGFloat = isFolder ? 4.5 : 3.0
            let badgeWidth = ceil(textSize.width + hPad * 2)
            let badgeHeight = ceil(textSize.height + vPad * 2)
            
            let scale: CGFloat = 2.0
            let imgSize = NSSize(width: badgeWidth * scale, height: badgeHeight * scale)
            let image = NSImage(size: imgSize)
            image.lockFocus()
            
            let rect = NSRect(origin: .zero, size: imgSize)
            let pillRect = rect.insetBy(dx: 1.5, dy: 1.5)
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2.0, yRadius: pillRect.height / 2.0)
            
            // Black background with opacity for high contrast and readability
            NSColor(white: 0.0, alpha: 0.74).setFill()
            pillPath.fill()
            
            // Subtle translucent border for polish
            NSColor(white: 1.0, alpha: 0.16).setStroke()
            pillPath.lineWidth = 1.5
            pillPath.stroke()
            
            // Draw text centered
            let scaledFont = NSFont.systemFont(ofSize: fontSize * scale, weight: isFolder ? .bold : .medium)
            let scaledAttributes: [NSAttributedString.Key: Any] = [
                .font: scaledFont,
                .foregroundColor: NSColor.white
            ]
            let scaledTextSize = (displayTitle as NSString).size(withAttributes: scaledAttributes)
            let textRect = NSRect(
                x: (imgSize.width - scaledTextSize.width) / 2.0,
                y: (imgSize.height - scaledTextSize.height) / 2.0 + 0.5,
                width: scaledTextSize.width,
                height: scaledTextSize.height
            )
            (displayTitle as NSString).draw(in: textRect, withAttributes: scaledAttributes)
            
            image.unlockFocus()
            
            // Convert points to SceneKit 3D world units
            let unitScale: CGFloat = 0.022
            let worldWidth = badgeWidth * unitScale
            let worldHeight = badgeHeight * unitScale
            
            let plane = SCNPlane(width: worldWidth, height: worldHeight)
            let material = SCNMaterial()
            material.diffuse.contents = image
            material.lightingModel = .constant // Unlit so it remains crisp and bright from any angle
            material.isDoubleSided = true
            material.readsFromDepthBuffer = true
            material.writesToDepthBuffer = false // Prevents alpha occlusion and clipping
            plane.materials = [material]
            
            let badgeNode = SCNNode(geometry: plane)
            badgeNode.name = "label:\(nodeId)"
            badgeNode.renderingOrder = 100
            
            // Always face camera
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            
            if let camera = cameraNode {
                let positionConstraint = SCNTransformConstraint.positionConstraint(inWorldSpace: true) { [weak camera] node, _ in
                    guard let parent = node.parent, let cam = camera else { return node.presentation.worldPosition }
                    
                    let pWorld = parent.presentation.worldPosition
                    let sPos: SCNVector3
                    if pWorld.x == 0 && pWorld.y == 0 && pWorld.z == 0 && (parent.position.x != 0 || parent.position.y != 0 || parent.position.z != 0) {
                        sPos = parent.convertPosition(SCNVector3Zero, to: nil)
                    } else {
                        sPos = pWorld
                    }
                    
                    let cWorld = cam.presentation.worldPosition
                    let cPos = (cWorld.x == 0 && cWorld.y == 0 && cWorld.z == 0 && cam.position.z != 0) ? cam.worldPosition : cWorld
                    
                    let dx = cPos.x - sPos.x
                    let dy = cPos.y - sPos.y
                    let dz = cPos.z - sPos.z
                    let dist = max(0.0001, sqrt(dx*dx + dy*dy + dz*dz))
                    let nx = dx / dist
                    let ny = dy / dist
                    let nz = dz / dist
                    
                    // Position badge in front of the sphere towards camera with slight elevation
                    let frontOffset = radius + 0.15
                    let upOffset = radius * 0.35 + (worldHeight / 2.0) + 0.05
                    
                    return SCNVector3(
                        sPos.x + nx * frontOffset,
                        sPos.y + ny * frontOffset + upOffset,
                        sPos.z + nz * frontOffset
                    )
                }
                badgeNode.constraints = [positionConstraint, billboard]
            } else {
                let verticalOffset = radius + (worldHeight / 2.0) + (isFolder ? 0.35 : 0.22)
                badgeNode.position = SCNVector3(0, verticalOffset, 0)
                badgeNode.constraints = [billboard]
            }
            
            return badgeNode
        }
        
        private func applyHighlightAndOpacity(in graphRoot: SCNNode, data: GraphData, filter: String, selectedId: String?) {
            let cleanFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let hasFilter = !cleanFilter.isEmpty
            let hasSelection = selectedId != nil
            
            let neighbors: Set<String>
            if let sel = selectedId {
                neighbors = Set(data.neighbors(for: sel) + [sel])
            } else {
                neighbors = []
            }
            
            // Update node opacity
            for node in data.nodes {
                guard let scnNode = graphRoot.childNode(withName: "node:\(node.id)", recursively: false) else { continue }
                
                var matches = true
                if hasFilter {
                    matches = node.title.lowercased().contains(cleanFilter) ||
                              node.relativePath.lowercased().contains(cleanFilter) ||
                              node.tags.contains { $0.lowercased().contains(cleanFilter) }
                }
                
                if hasSelection {
                    matches = matches && neighbors.contains(node.id)
                }
                
                let targetOpacity: CGFloat = matches ? 1.0 : (hasFilter || hasSelection ? 0.12 : 1.0)
                scnNode.opacity = targetOpacity
            }
            
            // Update edge opacity
            for edge in data.edges {
                guard let edgeNode = graphRoot.childNode(withName: "edge:\(edge.id)", recursively: false) else { continue }
                
                var edgeVisible = true
                if hasSelection, let sel = selectedId {
                    edgeVisible = (edge.sourceId == sel || edge.targetId == sel)
                } else if hasFilter {
                    let sourceMatches = edge.sourceId.lowercased().contains(cleanFilter)
                    let targetMatches = edge.targetId.lowercased().contains(cleanFilter)
                    edgeVisible = sourceMatches || targetMatches
                }
                
                let baseOpacity: CGFloat = edge.type.isTag ? 0.28 : (edge.type.isFolder ? 0.22 : 0.50)
                edgeNode.opacity = edgeVisible ? baseOpacity : 0.04
            }
        }
    }
}

// MARK: - Node Detail Card (Pop-up Inspector)

public struct NodeDetailCard: View {
    public let node: GraphNode
    public let graphData: GraphData
    public let onOpenInEditor: () -> Void
    public let onClose: () -> Void
    public let onSelectNeighbor: (String) -> Void
    
    public init(
        node: GraphNode,
        graphData: GraphData,
        onOpenInEditor: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onSelectNeighbor: @escaping (String) -> Void
    ) {
        self.node = node
        self.graphData = graphData
        self.onOpenInEditor = onOpenInEditor
        self.onClose = onClose
        self.onSelectNeighbor = onSelectNeighbor
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: node.isFolder ? "folder.fill" : "doc.text.fill")
                    .font(.system(size: 20))
                    .foregroundColor(node.isFolder ? .purple : .accentColor)
                    .frame(width: 32, height: 32)
                    .background((node.isFolder ? Color.purple : Color.accentColor).opacity(0.14))
                    .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(node.isFolder ? "Folder Hub (\(node.relativePath))" : node.relativePath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close inspector")
            }
            
            Divider()
            
            // Metadata Stats
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.isFolder ? "MEMBER NOTES" : "CONNECTIONS")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Text("\(node.degree)")
                        .font(.title3.bold())
                }
                
                Divider()
                    .frame(height: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("CATEGORY / HUB")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(node.group)
                        .font(.subheadline.weight(.medium))
                }
            }
            
            // Tags
            if !node.tags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TAGS")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(node.tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.purple)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(Color.purple.opacity(0.12))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
            }
            
            // Connected Notes / Members List
            let neighbors = graphData.neighbors(for: node.id)
            if !neighbors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(node.isFolder ? "FOLDER CONTENTS (\(neighbors.count))" : "CONNECTED NOTES (\(neighbors.count))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(neighbors.prefix(5), id: \.self) { neighborId in
                            let isNeighborFolder = neighborId.hasPrefix("folder:")
                            let title = isNeighborFolder
                                ? String(neighborId.dropFirst(7))
                                : (neighborId as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
                            
                            Button(action: {
                                onSelectNeighbor(neighborId)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: isNeighborFolder ? "folder.fill" : "circle.fill")
                                        .font(.system(size: isNeighborFolder ? 10 : 5))
                                        .foregroundColor(isNeighborFolder ? .purple : .accentColor)
                                    Text(title)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.04))
                                .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        if neighbors.count > 5 {
                            Text("+ \(neighbors.count - 5) more")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.leading, 8)
                        }
                    }
                }
            }
            
            // Open in Editor Button (only for note documents)
            if !node.isFolder {
                Divider()
                
                Button(action: onOpenInEditor) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.app.fill")
                        Text("Open in Editor")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(16)
        .frame(width: 290)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.20), radius: 16, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}
