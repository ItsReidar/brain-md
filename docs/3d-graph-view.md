# 3D Visual Brain Graph

This document details the architecture, design principles, mathematical layout model, and interaction mechanisms of the **3D Visual Brain Graph** in `brain-md`.

---

## Overview

The 3D Visual Brain Graph transforms your markdown vault into an interactive 3D neural universe. It visualizes how thoughts, ideas, and knowledge interconnect across your notes via explicit links (`[[wikilinks]]`, `[title](path.md)`) and shared `#tag` clusters.

Built entirely in **native Apple SceneKit (Metal-accelerated)**, the visualizer runs 100% offline with zero external dependencies and sub-millisecond layout computation.

```text
                    ┌─────────────────────────────────────────┐
                    │          Vault Notes (.md)              │
                    └──────────────────┬──────────────────────┘
                                       │ (1. Parse)
                    ┌──────────────────▼──────────────────────┐
                    │          NoteGraphService               │
                    │   - [[Wikilinks]] & [Markdown Links]    │
                    │   - Tag Clusters & Edge Weighting       │
                    │   - 3D Force Simulation (SIMD3<Float>)  │
                    └──────────────────┬──────────────────────┘
                                       │ (2. GraphData)
                    ┌──────────────────▼──────────────────────┐
                    │         Graph3DSceneView (SceneKit)     │
                    │   - Glowing Metal Spheres (Nodes)       │
                    │   - Synaptic Link Beams (Edges)         │
                    │   - 3D Camera Controls (Orbit/Pan/Zoom) │
                    └──────────────────┬──────────────────────┘
                                       │ (3. Click Raycast)
                    ┌──────────────────▼──────────────────────┐
                    │      NodeDetailCard (Inspector Pop-up)  │
                    │   - Note metadata, tags, and neighbors  │
                    │   - "Open in Editor" jump action        │
                    └─────────────────────────────────────────┘
```

---

## Key Features

1. **Intuitive 3D Spin-Ball Trackball & Cursor-Anchored Zoom**:
   - Natural, single-touch/single-click drag to freely spin the 3D brain ball in any direction with realistic inertia momentum.
   - **Cursor-Anchored Zoom**: Scrolling or pinching zooms directly towards the 3D point under the mouse cursor using raycasting and perspective scaling ($r = \frac{newZ - P_z}{oldZ - P_z}$), keeping the hovered node or region pinned under your cursor.
   - Smooth recentering damping when zooming out toward `maxZoom` prevents the graph ball from drifting away.

2. **Folder Hub Nodes & Outward-Radiating Clusters**:
   - Folders are promoted to **first-class large glossy hub nodes** labeled with their folder name/subject.
   - Notes belonging to a folder attach with high spring tension to their folder hub, forming cohesive, distinct communities matching biological neural brain clusters.
   - Notes initialize in the core and expand outwards radially, preventing perimeter boundary scattering and ensuring all notes are comfortably framed in the viewport.

3. **Velvety Matte Finish & Dynamic Front-Facing Badge Labels**:
   - Nodes feature a refined **matte Lambertian finish** (pure diffuse shading without distracting specular glare or shiny plastic reflections).
   - Node and folder names are rendered inside **translucent black pill badges** (`NSColor(white: 0.0, alpha: 0.74)` with crisp white text and a subtle translucent border).
   - **Always In Front of Nodes**: Instead of a static local coordinate offset, badges utilize a dynamic `SCNTransformConstraint` in world space that positions them along the vector from the node toward the camera ($\vec{P}_{\text{badge}} = \vec{W} + \hat{u}_{\text{toCam}} \cdot (\text{radius} + 0.15)$) combined with `SCNBillboardConstraint`.
   - As you freely spin the 3D ball in any direction, labels never rotate behind nodes, flip upside down, or clip into geometry.
   - Resilient hit-testing with multi-hit raycasting and screen-space proximity snapping guarantees effortless node selection.

4. **Fluid Organic Floating & Elastic Spin Dynamics**:
   - **Organic Harmonic Breathing**: Nodes gently float and undulate in 3D space with harmonic multi-axis sinusoidal waves and golden-ratio phase dispersion ($\phi_i = i \times 1.618$). Folder hubs anchor with subtle breathing ($A \approx 0.05$), while note dots drift gracefully ($A \approx 0.15$), making the graph feel alive like a neural suspension.
   - **Rotational Elastic Fluidity**: When dragging to spin the 3D ball or during inertia momentum, nodes react with realistic fluid inertia, flexing backwards against the spin velocity ($\vec{\delta}_{\text{lag}} = -\vec{\omega} \cdot k_{\text{flex}}$). When rotation stops, nodes gently spring-rebound back to their rest positions with smooth damped oscillation.
   - **Dynamic 3D Synaptic Cylinders & Thickness**: Rather than 1-pixel hairlines (which are faint on high-DPI Retina screens), connections render as true 3D `SCNCylinder` geometries with calibrated thickness (Direct links: radius 0.048, Folder hubs: radius 0.040, Tag clusters: radius 0.035). Edges feature vibrant theme colors, subtle emission glow (0.35 alpha), and constant lighting so they never dim or get lost in shadows during rotation.
   - **Zero-Allocation 120 FPS Tracking**: As nodes float and rotate, connection endpoints are dynamically positioned, oriented via SIMD quaternions, and scaled along their local Y-axis in real time with zero heap geometry reallocations.

5. **Interactive Inspection Pop-up**:
   - Clicking any note or folder node triggers SceneKit raycast hit-testing.
   - Shows note title, folder, relative path, tag chips, and connected neighbor notes.
   - Direct **"Open in Editor"** button instantly loads the note into the editor and dismisses the graph modal.

6. **Live Search & Filtering**:
   - Instant search query highlights matching notes and dims unrelated nodes and edges.
   - Interactive toggle to enable or disable shared `#tag` cluster edges.
   - Re-simulation button to recalculate the 3D physics layout.
   - Access shortcut: **`⌥⌘G`** or toolbar brain icon.
