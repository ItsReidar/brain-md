//
//  NoteGraphServiceTests.swift
//  brain-mdTests
//

import XCTest
@testable import brain_md

final class NoteGraphServiceTests: XCTestCase {
    
    var service: NoteGraphService!
    
    override func setUp() {
        super.setUp()
        service = NoteGraphService.shared
    }
    
    override func tearDown() {
        service = nil
        super.tearDown()
    }
    
    // MARK: - Wikilink Extraction Tests
    
    func testExtractWikilinks_BasicAndAliases() {
        let content = """
        # My Document
        Here is a link to [[Introduction]] and another to [[Projects/Architecture|Our Architecture]].
        Also check out [[Notes/DeepDive#Section 2]].
        Regular text with no links.
        """
        
        let links = service.extractWikilinks(from: content)
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[0], "Introduction")
        XCTAssertEqual(links[1], "Projects/Architecture")
        XCTAssertEqual(links[2], "Notes/DeepDive")
    }
    
    // MARK: - Markdown Link Extraction Tests
    
    func testExtractMarkdownLinks_FiltersExternal() {
        let content = """
        Check [this internal note](OtherNote.md) and [sub note](folder/Sub.md).
        Here is an external link [Google](https://google.com) and [Email](mailto:user@test.com).
        Anchor link [Top](#top) should be ignored.
        """
        
        let links = service.extractMarkdownLinks(from: content)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0], "OtherNote.md")
        XCTAssertEqual(links[1], "folder/Sub.md")
    }
    
    // MARK: - Target Resolution Tests
    
    func testResolveLinkTarget() {
        let allPaths = [
            "Welcome.md",
            "Projects/Brain.md",
            "Projects/Tasks.md",
            "Archive/Old.md"
        ]
        
        // Exact match
        XCTAssertEqual(service.resolveLinkTarget("Welcome.md", fromSourcePath: "Projects/Brain.md", allNotePaths: allPaths), "Welcome.md")
        
        // Wikilink without extension
        XCTAssertEqual(service.resolveLinkTarget("Welcome", fromSourcePath: "Projects/Brain.md", allNotePaths: allPaths), "Welcome.md")
        
        // Relative sibling in same directory
        XCTAssertEqual(service.resolveLinkTarget("Tasks.md", fromSourcePath: "Projects/Brain.md", allNotePaths: allPaths), "Projects/Tasks.md")
        XCTAssertEqual(service.resolveLinkTarget("Tasks", fromSourcePath: "Projects/Brain.md", allNotePaths: allPaths), "Projects/Tasks.md")
        
        // Filename in another folder
        XCTAssertEqual(service.resolveLinkTarget("Old", fromSourcePath: "Welcome.md", allNotePaths: allPaths), "Archive/Old.md")
        
        // Nonexistent target
        XCTAssertNil(service.resolveLinkTarget("NonExistent", fromSourcePath: "Welcome.md", allNotePaths: allPaths))
    }
    
    // MARK: - Build Graph Tests
    
    func testBuildGraph_ConnectionsAndDegrees() {
        let paths = ["A.md", "B.md", "C.md"]
        let contents = [
            "A.md": "Links to [[B]] and [[C]].",
            "B.md": "Links back to [[A]].",
            "C.md": "No outgoing links."
        ]
        let tags = [
            "A.md": ["swift"],
            "B.md": ["swift", "macos"],
            "C.md": ["macos"]
        ]
        
        let graph = service.buildGraph(
            notePaths: paths,
            noteContents: contents,
            noteTags: tags,
            includeTags: true
        )
        
        XCTAssertEqual(graph.nodes.count, 3)
        
        // Nodes exist and have titles
        let nodeMap = graph.nodeMap
        XCTAssertNotNil(nodeMap["A.md"])
        XCTAssertEqual(nodeMap["A.md"]?.title, "A")
        
        // Explicit edges: A<->B, A<->C
        let explicitEdges = graph.edges.filter { !$0.type.isTag }
        XCTAssertEqual(explicitEdges.count, 2)
        
        // Tag edges: A<->B (swift), B<->C (macos)
        let tagEdges = graph.edges.filter { $0.type.isTag }
        XCTAssertGreaterThanOrEqual(tagEdges.count, 1)
        
        // Degrees should be positive
        XCTAssertGreaterThan(nodeMap["A.md"]?.degree ?? 0, 0)
    }
    
    // MARK: - 3D Layout Simulation Tests
    
    func testSimulate3DLayout_CoordinatesAreValid() {
        let nodes = [
            GraphNode(id: "1", title: "One", relativePath: "One.md"),
            GraphNode(id: "2", title: "Two", relativePath: "Two.md"),
            GraphNode(id: "3", title: "Three", relativePath: "Three.md")
        ]
        let edges = [
            GraphEdge(sourceId: "1", targetId: "2", type: .link),
            GraphEdge(sourceId: "2", targetId: "3", type: .link)
        ]
        
        let simulated = service.simulate3DLayout(nodes: nodes, edges: edges, iterations: 50)
        
        XCTAssertEqual(simulated.count, 3)
        for node in simulated {
            XCTAssertFalse(node.position.x.isNaN, "X should not be NaN")
            XCTAssertFalse(node.position.y.isNaN, "Y should not be NaN")
            XCTAssertFalse(node.position.z.isNaN, "Z should not be NaN")
            
            XCTAssertFalse(node.position.x.isInfinite, "X should not be Infinite")
            XCTAssertFalse(node.position.y.isInfinite, "Y should not be Infinite")
            XCTAssertFalse(node.position.z.isInfinite, "Z should not be Infinite")
        }
    }
    
    // MARK: - Folder Hubs & Hierarchical Clustering Tests
    
    func testBuildGraph_FolderHubsAndClustering() {
        let paths = [
            "Projects/App.md",
            "Projects/Roadmap.md",
            "Archive/Legacy.md",
            "RootNote.md"
        ]
        let contents = [
            "Projects/App.md": "See [[Roadmap]].",
            "Projects/Roadmap.md": "Related to [[App]].",
            "Archive/Legacy.md": "Old file.",
            "RootNote.md": "Overview."
        ]
        
        let graph = service.buildGraph(
            notePaths: paths,
            noteContents: contents,
            noteTags: [:],
            includeTags: false
        )
        
        // 4 note nodes + 2 folder nodes ("Projects" and "Archive") = 6 nodes
        XCTAssertEqual(graph.noteNodes.count, 4)
        XCTAssertEqual(graph.folderNodes.count, 2)
        XCTAssertEqual(graph.nodes.count, 6)
        
        let nodeMap = graph.nodeMap
        guard let projectsFolder = nodeMap["folder:Projects"] else {
            XCTFail("Projects folder node should exist")
            return
        }
        XCTAssertTrue(projectsFolder.isFolder)
        XCTAssertEqual(projectsFolder.title, "Projects")
        
        // Structural folder edges should connect Projects -> App.md and Projects -> Roadmap.md
        let folderEdges = graph.edges.filter { $0.type.isFolder }
        XCTAssertGreaterThanOrEqual(folderEdges.count, 3) // 2 for Projects, 1 for Archive
        
        // App.md should have Projects folder as neighbor
        let appNeighbors = graph.neighbors(for: "Projects/App.md")
        XCTAssertTrue(appNeighbors.contains("folder:Projects"))
        
        // Check cluster radius is bounded and centered
        for node in graph.nodes {
            let r = sqrt(node.position.x * node.position.x + node.position.y * node.position.y + node.position.z * node.position.z)
            XCTAssertLessThan(r, 50.0, "Node position should be centered, not exploded")
        }
    }
}

