# RENDER_BACKEND

**Vulkan Backend (Zig) — Design & API Spec**
Version 1.0

This document specifies a clean, portable Vulkan wrapper layer implemented in Zig. The wrapper focuses on safety ergonomics, explicit resource ownership, small runtime cost, and exposing a minimal, testable API for higher-level renderer systems.

---

## Goals

* Provide a small, well-documented Zig API over Vulkan's verbose setup and resource lifetime.
* Encapsulate platform differences (Win32, X11/Wayland, macOS MoltenVK) behind `platform/` modules.
* Strong error handling (Zig `!Error`) and deterministic resource destruction.
* Support triple buffering frames-in-flight and deferred resource destruction.
* Keep the wrapper minimal — high-level render graph & material logic remain in `src/renderer/`.

---

## Directory Layout

```bash
src/renderer/backend/
  instance.zig
  device.zig
  swapchain.zig
  command.zig
  descriptor.zig
  memory.zig
  resources.zig
  sync.zig
  debug.zig
  util.zig
  platform/  # window surface helpers per OS
```

---

## API Design Principles

* **Explicit ownership:** create/destroy pairs with RAII-style helpers (use `defer` in Zig to clean up).
* **Small surface area:** expose only what renderer needs (create buffers/textures, record commands, submit, present).
* **Per-frame context:** pass a `FrameContext` to per-frame operations to avoid global state.
* **No hidden global mutable state:** allow multiple `Renderer` instances for testing.

---

## Key Types (Zig pseudotype names)

```zig
pub const VkInstanceHandle = struct { handle: VkInstance }; // wrapper
pub const VkDeviceHandle = struct { device: VkDevice, queues: Queues };
pub const Swapchain = struct { swapchain: VkSwapchainKHR, images: []VkImage, image_views: []VkImageView };
pub const CommandPool = struct { pool: VkCommandPool };
pub const FrameResource = struct { command_buffer: VkCommandBuffer, fence: VkFence, image_available: VkSemaphore, render_finished: VkSemaphore };
```

---

## Initialization Sequence (recommended wrapper flow)

1. `Instance.create(app_name, enable_validation)` → returns `Instance`.
2. `Instance.setup_debug_messenger()` (optional, only when validation enabled).
3. `pick_physical_device(instance, required_features, required_extensions)` → `PhysicalDevice`.
4. `Device.create(physical, queue_priorities, enabled_features, enabled_extensions)` → `Device`.
5. `Surface.create(window_handle)` → `Surface`.
6. `Swapchain.create(device, surface, preferred_format, present_mode, width, height)` → `Swapchain`.
7. Create command pools for graphics/transfer/compute.
8. Create per-frame resources (`FrameResource` array sized by `frames_in_flight`).

Wrap the above in a higher-level `VulkanContext` struct that the renderer owns.

---

## Physical Device Selection

Selection considers:

* Required queue families (graphics, compute, transfer, present).
* Required device features (samplerAnisotropy, timelineSemaphore optional).
* Device extensions (`VK_KHR_swapchain` + optional features like descriptorIndexing).
* Prefer discrete GPUs and highest score by sample metrics (VRAM, dedicated support, discrete type).

Expose a `DeviceSelector` utility to choose based on a scoring function.

---

## Command Recording & Pools

* Provide fast path helpers:

  * `with_transient_command(device, queue, fn (cmd: CommandBuffer) !void) !void` for immediate one-shot uploads.
  * `CommandPool.allocate_buffers(n)`
* Command pools per thread or per-frame. Use resettable pools for frame-based allocation.
* Provide helpers to begin & end render passes with safe lifetime tables.

---

## Memory Allocation

* Provide Zig wrapper `GpuAllocator` that manages `vkAllocateMemory` suballocations.
* Implement a simple linear allocator per memory heap and a freelist-based allocator for larger allocations.
* Expose convenience: `create_buffer_with_staging(data, usage, properties)` which manages staging, copying, and transient resources.
* Defer free until safe: track frame number and only release after `frames_in_flight` have passed.

---

## Descriptor & Pipeline Helpers

* `DescriptorPool` with dynamic resizing policies for descriptor-heavy scenes.
* `DescriptorSetLayoutBuilder` fluent API generating layouts from binding descriptors.
* `PipelineBuilder` that combines shader modules, render pass, vertex input descriptions, and push constant layout into a pipeline object with caching based on key hash.
* Cache pipeline/TDR objects to avoid expensive re-creation during hot reloads.

---

## Synchronization Primitives

* Define `FrameSync` containing per-frame `VkFence` and semaphores.
* Optionally support `VkTimelineSemaphore` if available.
* Provide helpers for GPU fences waiting, resetting, and setting timeouts with nice Zig-friendly error messages.

---

## Swapchain Management

* Wrap swapchain recreation into `Swapchain.recreate(width, height)` handling old swapchain cleanup safely.
* Provide `acquire_next_image(timeout) -> (image_index, result)` with automatic handling for `VK_ERROR_OUT_OF_DATE_KHR` and `VK_SUBOPTIMAL_KHR`.

---

## Resource Lifetime & Deferred Destruction

* Central `ResourceRegistry` holds weak references to GPU resources.
* When user requests destroy(resource), mark it with `delete_frame = current_frame + frames_in_flight`.
* On each frame end, sweep and free resources with `delete_frame <= current_frame`.

---

## Debugging Features

* Integrate Vulkan debug utils messages to log levels; forward to engine logger.
* Provide `debug_name(object, "name")` function to set `VK_EXT_debug_utils` names for resources.
* Optional `with_debug_marker(cmd_buf, "region")` scoping macros for RenderDoc instrumentation.

---

## Error Handling

* All public functions should return `!RenderError` with clear variants: `OutOfMemory`, `DeviceLost`, `ValidationError`, `Timeout`, `SwapchainOutOfDate`, etc.
* Make common errors recoverable (attempt swapchain recreate on out-of-date).

---

## Multithreading Model

* Device is thread-safe but command pools and command buffers should be confined per thread.
* Provide `CommandPoolThreadLocal` utility for worker threads.
* Staging uploads should use a separate transfer queue if available.

---

## Zig API Examples

```zig
const ctx = try VulkanContext.create(app_name, enable_validation);
defer ctx.deinit();

// Create buffer with staging
const vb = try ctx.create_buffer_with_data(vertices, .VERTEX_BUFFER);
// Frame loop
while (running) {
    const frame = ctx.begin_frame();
    defer ctx.end_frame(frame);

    // record commands into frame.command_buffer
    try frame.begin_primary();
    try frame.begin_render_pass(pass_info);
    // draw calls...
    frame.end_render_pass();
    try frame.submit_and_present();
}
```

---

## Tests & Validation

* Unit tests for: memory allocator, descriptor pooling, command pool reset.
* Integration tests: swapchain recreation, device lost recovery (simulate via kill or validation layer injection).

---

## TODOs

* Implement timeline semaphore fallback path
* Implement GPU memory defragmentation tool
* Add support for `VK_KHR_dynamic_rendering` (optional modern path)

---

## Appendix: Integration Checklist with `renderer_plan`

* Hook `VulkanContext` to `RenderGraph` build/execute phases.
* Ensure `FrameResource` matches `frames_in_flight` used by render graph.
* Provide `with_transient_command` helper used by Asset loader for staging uploads.

---
