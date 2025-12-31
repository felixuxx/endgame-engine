# RENDERER_PLAN

**Zig + Vulkan Renderer Architecture Plan**
Version 1.0

This document describes the full rendering architecture for your game engine:
data layout, Vulkan subsystems, resource management, GPU-driven workflows,
frame graph design, and integration with ECS.

---

## 1. Renderer Vision

A modern, Vulkan-based renderer focused on:

* **GPU-driven architecture** (indirect draws, culling, material decoding on GPU)
* **Data-oriented design**
* **ECS-first integration**
* **Pipeline modularity** (forward, deferred, ray tracing optional)
* **Hot-reloaded shaders**
* **Automatic resource lifetime management**

Renderer tiers:

1. **Tier 0** — Clear screen, triangle
2. **Tier 1** — Forward rendering + materials
3. **Tier 2** — PBR + shadows
4. **Tier 3** — GPU-driven instance culling + batching
5. **Tier 4** — Render Graph with async compute

---

## 2. Directory Structure

```bash
src/renderer/
    backend/         # Vulkan wrappers
    resources/       # Buffers, textures, samplers, descriptors
    pipeline/        # Graphics + compute pipelines
    graph/           # Render graph
    scene/           # Camera, lights, render components
    loaders/         # Shader compiler, material parser
    util/            # GPU sync, fences, frame allocator
```

---

## 3. Initialization Pipeline

### High-level Vulkan bootstrap order

1. Create Vulkan instance
2. Select physical device
3. Create logical device + queues
4. Create swapchain
5. Allocate command pools & buffers
6. Create descriptor pool
7. Create default GPU resources
8. Create render graph root
9. Create default pipelines (unlit, textured)

---

## 4. Frame Lifecycle

```bash
BeginFrame
    ↓
AcquireSwapchainImage
    ↓
UpdateGlobalUniforms
    ↓
ECS → Renderer Sync Phase
    ↓
RenderGraph.Build()
    ↓
RenderGraph.Execute()  # multi-pass rendering
    ↓
SubmitGraphics/Compute
    ↓
Present
EndFrame
```

---

## 5. ECS Integration

### Components

* `Transform`
* `MeshRenderer`
* `Camera`
* `Light` (directional, point, spot)
* `SkinnedMeshRenderer` (later)

### Systems

* **Visibility System** → prepares GPU instance list
* **Camera System** → main camera selection
* **Light System** → push lighting data
* **RenderSubmit System** → writes draw commands

Renderer reads ECS but does not write to it.

---

## 6. Rendering Data Model

## 6.1 GPU Scene Data

* **Per-frame UBO**

  * view matrix
  * projection matrix
  * camera world position
  * time

* **Per-object data**

  * model matrix
  * material handle

* **Lighting buffer**

  * directional light
  * N point lights
  * N spot lights

## 6.2 Mesh Data

```zig
MeshHandle → {
    vertex_buffer,
    index_buffer,
    submeshes[],
}
```

## 6.3 Material Model

```zig
Material → {
    shader_variant,
    textures[],
    parameters,
}
```

Shader variants drive pipeline selection.

---

## 7. GPU Resource Lifetime Management

## 7.1 Resource Registry

```bash
GpuResourceId → Buffer/Texture/Pipeline
```

Centralized system tracking:

* Creation
* Deletion
* Deferred destruction (N frames in flight)

## 7.2 Upload Staging

Stages:

1. Allocate from frame-local staging buffer
2. Copy into GPU buffer
3. Queue fence for safe use

---

## 8. Descriptor System

Descriptor layout strategy:

* **Set 0** global (frame data, lighting)
* **Set 1** material
* **Set 2** object instance data

Bindless (future):

* Large descriptor arrays for textures + materials

---

## 9. Shader System

Features:

* GLSL or WGSL-like syntax
* Preprocessing
* SPIR-V compilation via `glslc` or shaderc
* Hot reload (file watcher triggers pipeline rebuild)

Pipeline metadata stored in `.meta.json` next to shader.

---

## 10. Render Graph Architecture

## 10.1 Goals

* Automatic dependency resolution
* Transient resource pooling
* Parallel compute + graphics
* Multiple passes: depth prepass, lighting, shadows

## 10.2 Node definition

```zig
Node {
    inputs[]
    outputs[]
    execute(cmd)
}
```

## 10.3 Built-in graph passes

* GBuffer (optional)
* Depth Prepass
* Forward Pass
* Shadow Maps
* Postprocessing
* UI Overlay

---

## 11. Forward Rendering Pipeline

### Stages

1. Depth prepass (optional)
2. Opaque forward
3. Transparent forward
4. Skybox
5. Postprocessing

### Pipeline States

* Depth test enabled
* Blending for transparency
* Push constants for fast data

---

## 12. Future: GPU-Driven Rendering

## 12.1 Indirect Draw Pipeline

```bash
ComputeCull → produces DrawIndirectBuffer
GraphicsPass → vkCmdDrawIndirect
```

## 12.2 Benefits

* No CPU-side draw calls
* Automatic batching
* Real-time culling

---

## 13. Debugging & Tools

* Renderdoc markers
* GPU timing (query pools)
* Pipeline stats
* Live shader reload UI (later)
* GPU memory graphs

---

## 14. Milestones

## M1 — Basic Vulkan

* Instance
* Swapchain
* Triangle

## M2 — Mesh Rendering

* Buffers
* Materials
* Lighting

## M3 — Scene Rendering

* ECS Integration
* Shadow maps
* Forward renderer complete

## M4 — Render Graph

* Dependencies
* Pass scheduling

## M5 — GPU-Driven

* Compute culling
* Indirect draws

---

## 15. Final Notes

This plan represents **the full evolution path** of your engine’s renderer,
from simple forward rendering to a fully GPU-driven architecture. The early
stages prioritize usability; later stages introduce significant performance scaling.
