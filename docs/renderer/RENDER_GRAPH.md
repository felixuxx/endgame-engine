# RENDER_GRAPH

**Render Graph — Design & API**
Version 1.0

This document defines the Render Graph subsystem: a flexible, explicit way to
express render passes, resource dependencies, automatic synchronization and
lifetime, and multi-pass scheduling. It focuses on integration with the existing
Vulkan backend (`RENDER_BACKEND.md`) and the engine's ECS.

---

## 1. Goals

* Express render pipelines as nodes with named inputs/outputs.
* Automatically resolve resource transitions and memory barriers for Vulkan.
* Allow transient resource pooling: reuse physical images/textures across frames.
* Support hybrid CPU/GPU work (compute passes + graphics passes).
* Provide deterministic ordering and optional parallelism between independent passes.
* Make it easy to attach profiling/debugging instrumentation (timers, markers).

---

## 2. Concepts

### 2.1 Resource

Logical render resources (textures, buffers, attachments) that nodes read/write.

Properties:

* `name` (string key)
* `type` (Image/Buffer)
* `format` (for images)
* `usage` flags (color attachment, sampled, storage)
* `lifespan` (Transient, Persistent)

### 2.2 Node (Pass)

A node represents a render or compute pass:

```zig
Node {
    id: NodeId,
    name: String,
    inputs: []ResourceHandle,
    outputs: []ResourceHandle,
    execute: fn (Context) -> void,
    queue_hint: Graphics | Compute | Transfer,
    side_effects: bool, // means can't be culled
}
```

Nodes declare attachments they will read/write. The graph resolves dependencies
to create execution order.

### 2.3 Edge

Edges are implicit via resources — if Node A writes resource R and Node B reads
R, an edge A -> B exists. Edges may carry explicit layout requirements or access
flags.

### 2.4 Render Graph Instance

A `RenderGraph` object is built out of `Node` definitions and `Resource`
descriptions. Each frame you `build()` it (resolve resource aliases, transient
allocation) and `execute()` it (record command buffers and submit).

---

## 3. API (Zig pseudocode)

```zig
pub const RenderGraph = struct {
    allocator: *Allocator,
    nodes: ArrayList(Node),
    resources: HashMap(String, ResourceDesc),

    pub fn init(allocator: *Allocator) RenderGraph {}
    pub fn addNode(self: *RenderGraph, node: Node) NodeId {}
    pub fn addResource(self: *RenderGraph, name: []const u8, desc: ResourceDesc) ResourceHandle {}
    pub fn build(self: *RenderGraph, ctx: *VulkanContext, frame: FrameIndex) !BuiltGraph {}
    pub fn execute(self: *BuiltGraph, ctx: *VulkanContext) !void {}
};
```

Node builder helper example:

```zig
var node = NodeBuilder.init("gbuffer")
    .reads("depth")
    .writes("gbuffer_color")
    .queue(.Graphics)
    .execute(my_gbuffer_fn)
    .build();

render_graph.addNode(node);
```

---

## 4. Resource Types & Lifetimes

### Image (Attachment) Desc

* extent (width/height or scale relative to swapchain)
* format (vkFormat)
* samples (1,4...)
* initial_layout
* final_layout
* usage_flags

### Buffer Desc

* size
* usage (uniform, storage, index)

### Lifespan

* **Persistent**: lives across frames (shadow maps, G-buffer if reused)
* **Transient**: allocated for this frame only (postprocess temporaries)

Transient images are ideal for intermediate passes and will be allocated from a
pool and freed/reused across frames.

---

## 5. Build Phase (Graph Compilation)

When `build()` is called:

1. Validate nodes (no unknown resources).
2. Compute resource producers and consumers mapping.
3. Topologically sort nodes per queue family to determine execution order.
4. Merge compatible passes into command buffer groups for fewer submissions.
5. Allocate transient resources using the `TransientResourcePool`.
6. Emit required image/buffer transitions and barrier info per edge.
7. Produce a `BuiltGraph` structure optimized for execution (precomputed command
buffer templates, descriptor set updates).

Important: `build()` must be efficient; cache the `BuiltGraph` when node set is
unchanged between frames.

---

## 6. Execute Phase (Recording & Submission)

During `execute()`:

* For each command group (a sequence of nodes that share queue/compatibility):

  1. Acquire frame-local command buffer.
  2. Begin recording.
  3. For each node in group: call node.execute(context) which records commands.
  4. End render pass(s) and command buffer.
  5. Submit command buffer with appropriate semaphores and fences.

Nodes get a `RenderContext` with handy helpers:

* `bind_pipeline` / `bind_descriptor_sets` / `push_constants`
* `draw_indexed` / `dispatch` / `copy_buffer_to_image`
* `set_viewport` / `set_scissor`

The `BuiltGraph` contains precomputed barrier ranges so the execute step doesn't
need to recompute. However Vulkan commands still require explicit barriers;
`execute()` emits them in the recorded command buffer.

---

## 7. Synchronization & Barriers

Render Graph computes minimal Vulkan barriers between passes:

* Image layout transitions (undefined → color attachment optimal, etc.)
* Pipeline stage masks and access masks computed based on resource usage.

Implement helper:

```zig
fn barrier_for_transition(old_usage: Usage, new_usage: Usage) BarrierInfo { ... }
```

Group barriers where possible to reduce calls.

---

## 8. Transient Resource Pool

Implement allocator that reuses images/buffers with the same descriptors to
avoid continuous allocation.

API:

```zig
TransientPool.alloc_image(desc: ImageDesc) -> ImageHandle
TransientPool.free_image(image)
TransientPool.reset(frame)
```

Pool tracks last-used frame; reuse based on compatible formats / extents.

---

## 9. Descriptor Management

Since nodes may require descriptor sets for materials / frame data, `build()`
should pre-allocate descriptor sets for nodes or generate descriptor update
templates where supported.

Strategy:

* Global descriptor set per frame for UBOs (set 0)
* Per-material descriptor set (set 1) - persistent
* Node-local ephemeral descriptor sets allocated from frame-local pool

---

## 10. Parallelism & Multi-Queue Execution

When nodes target different queues (compute vs graphics), schedule accordingly:

* Build cross-queue dependencies (release/acquire semaphores)
* Allow compute nodes to run in parallel with graphics when dependencies allow

Topological sorting should consider queue hints; group nodes by (queue family)
and detect synchronization points.

---

## 11. Debugging & Profiling

* Insert debug markers per node (`vkCmdBeginDebugUtilsLabelEXT` / `vkCmdEndDebugUtilsLabelEXT`).
* Allow node start/end GPU timestamps using `vkCmdWriteTimestamp` and readback.
* Provide a visualizer to print node graph, resource lifetimes, and memory usage.

---

## 12. API Examples: Building a Simple Frame Graph

```zig
var rg = RenderGraph.init(allocator);
rg.addResource("swapchain_color", ImageDesc{ ... , lifespan: Persistent });
rg.addResource("depth", ImageDesc{ ... , lifespan: Transient });
rg.addResource("hdr_temp", ImageDesc{ ... , lifespan: Transient });

rg.addNode(NodeBuilder.init("depth_prepass")
    .reads("depth")
    .writes("depth")
    .queue(.Graphics)
    .execute(depth_prepass_execute)
    .build());

rg.addNode(NodeBuilder.init("forward")
    .reads("depth")
    .reads("gbuffer_color")
    .writes("swapchain_color")
    .queue(.Graphics)
    .execute(forward_execute)
    .build());

const built = try rg.build(&vk_ctx, frame_index);
try built.execute(&vk_ctx);
```

---

## 13. Integration with ECS

* Visibility culling system writes instance lists (SSBOs) consumed by render
graph compute/graphics nodes.
* Camera system selects active camera & writes per-frame UBO.
* Material / Mesh components register resources referenced in the graph.

Design principle: renderer pulls what it needs from ECS in an `extract()` stage
and writes GPU-friendly structures into a `RenderWorld` used by the render graph.

---

## 14. Caching & Reuse

* Keep a cache of `BuiltGraph` keyed by node set & resource descriptors.
* Reuse transient allocations across frames when compatible.

---

## 15. Tests

* Unit test topological sorting & dependency detection.
* Integration test that builds & executes a simple graph:
depth prepass + forward pass.
* Stress test with many transient attachments to validate pool reuse.

---

## 16. Future Extensions

* Automatic render pass merging / pass fusion to reduce render pass counts.
* Descriptor update templates + push descriptor support for platforms that
support them.
* Graph-level reflection to auto-generate ImGui debug UI.
* GPU-driven render graph where execution and culling decisions are made on GPU.

---
