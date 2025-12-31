# ARCHITECTURE

> Project layout (canonical)

```bash
.
├── build.zig
├── build.zig.zon
├── examples
├── src
│   ├── app
│   ├── asset
│   ├── audio
│   ├── core
│   ├── input
│   ├── main.zig
│   ├── math
│   ├── physics
│   ├── renderer
│   ├── root.zig
│   ├── scripting
│   └── utils
├── tests
└── tools
```

---

## 1. High-level goals

* **ECS-first**: archetype-based ECS optimized for fast iteration and cache locality.
* **Modular & pluginable**: core stays minimal; features are plugins (physics,
audio, ui).
* **Explicit Vulkan renderer**: render graph driven, triple-buffered frames-in-flight.
* **Lua scripting**: sandboxed high-level logic, game scripts run via registered
Lua systems.
* **Zig-first ergonomics**: use `comptime` for component registration, safe
explicit memory rules, small runtime.

---

## 2. Mapping repo folders → responsibilities

* `src/app` — App bootstrap, `App` struct, plugin registry, stage runner, command
queue.
* `src/core` — ECS: World, Entity, Component registry, Archetypes, Queries, Schedulers.
* `src/renderer` — Vulkan integration, render graph, pipelines, GPU resource manager.
* `src/asset` — Asset server, loaders, handle semantics, hot-reload integration.
* `src/scripting` — Lua VM wrapper, bindings, system registration for Lua scripts.
* `src/input` — OS events, input mapping layer, gamepad handling.
* `src/audio` — Audio engine, mixer (as plugin).
* `src/physics` — Physics plugin (wrapping Rapier or custom) and fixed-step integration.
* `src/math` — Vector, matrix, quaternion types and helpers.
* `src/utils` — Logging, profiling adapters, allocators, utility types.
* `src/main.zig` & `src/root.zig` — program entry and global initialization helpers.
* `examples` — runnable minimal scenes demonstrating engine features.
* `tests` — unit/integration tests for core systems (ECS, scheduler, asset).
* `tools` — asset packer, shader compiler, editor helpers.

---

## 3. Core runtime model

### App & Stages

* `App` owns `World`, `Resources`, `Scheduler`, `PluginRegistry`, and `RenderContext`.
* Default stage list:
  `Startup -> PreUpdate -> Update -> PostUpdate -> PreRender -> Render
-> PostRender -> Cleanup`
* Systems register with stage plus metadata (reads/writes, labels, before/after).

### Frame loop (high-level)

1. poll OS events → update `Input` resource
2. run `PreUpdate`, `Update`, `PostUpdate` (game logic + Lua systems)
3. `render.extract()` (extract render data from world)
4. `render.prepare()` (upload GPU buffers, descriptor updates)
5. `render.queue()` → build command buffers
6. `render.execute()` → submit to GPU and present
7. `cleanup` (deferred despawn, resource destruction)

---

## 4. ECS (archetype-based)

### Entity

* `Entity = struct { id: u32, generation: u32 }` (or 64-bit combined).

### Archetype

* Archetype stores contiguous columns for each component type and an `entities` array.
* Component layout per archetype: packed columns with known size/alignment.

### Component registry (Zig patterns)

* Use comptime to register components:

```zig
pub fn registerComponent(comptime T: type) ComponentId { ... }
```

* Store per-component metadata: `type_id`, `size`, `align`, `drop_fn?`

### Queries

* Compile query match masks at runtime; cache list of matching archetypes.
* Query iteration returns column pointers for tight loops.

### Change detection

* Global tick counter; components store `last_changed_tick`.
* `Res<Time>` + system last-run tick used to implement `changed()` checks.

### Commands

* `Commands` buffer for spawn/despawn/component add/remove to avoid mid-frame mutation.

---

## 5. System scheduler

* Systems declare all accesses (component read/write, resource read/write).
* Build a dependency graph:

  * explicit edges from `before/after` labels
  * implicit edges from conflicting mutable access
* Partition into parallel batches; execute with Zig worker threads.
* Determinism: when requested, force stable ordering within a stage.

---

## 6. Scripting (Lua)

### Integration pattern

* Single Lua state per App or a pool for worker threads; prefer single
main-state to avoid concurrency issues.
* Expose small, explicit API to Lua: `spawn_entity()`, `add_component(entity,
component)`, `query(...)`, `time.delta`.
* Lua scripts register named functions (e.g., `function update(dt)`), which get
registered as engine systems with declared resource/component access metadata.

### Binding approach

* Write thin Zig C ABI wrappers: `extern fn lua_spawn_entity(L: *lua.State) c_int`.
* For marshalling, use small value types (numbers, strings, light userdata for handles).
* Provide automated binding helpers for common components (Transform, Velocity).

### Security & performance

* Sandbox global access in Lua.
* Heavy loops should be in Zig — expose math helpers to Lua to reduce roundtrips.

---

## 7. Renderer (Vulkan)

### Render Graph

* Node: `{ name, inputs, outputs, execute_fn }`
* Builder resolves resources, creates transient images, and orders passes.
* Three-phase render pipeline each frame: `extract -> prepare -> execute`.

### GPU resource management

* Implement `GpuAllocator` for device memory suballocation (linear/buddy allocator).
* `PerFrame` pools: command pools, descriptor pools, dynamic buffer arenas.
* Triple buffering: keep N frames in flight; defer resource destruction by N frames.

### Descriptor & pipeline management

* Material describes shader pipeline + descriptor set layout + default bindings.
* Reuse pipelines and descriptor sets where possible; cache pipeline + layout combos.

### Synchronization

* Per-frame semaphores/fences: image-available, render-finished, frame-fence.
* Careful use of `vkCmdPipelineBarrier` when transient resources cross passes.

---

## 8. Asset system & hot-reload

* `AssetServer` returns `Handle<T>` immediately for `load(path)`.
* Background loader threads decode files and insert into `Assets<T>` store.
* Hot-reload: use `inotify` / `ReadDirectoryChangesW` to detect changes;
mark asset dirty and requeue loader.
* Asset lifetime via strong/weak handle refcounts; evict unused assets.

Supported loaders: GLTF, KTX2/DDS, PNG/JPEG, shader sources, custom scene format.

---

## 9. Physics & Audio (plugins)

* Physics plugin offers `RigidBody`, `Collider`, and `PhysicsStep` fixed-step system.
* Use an external solver (Rapier) wrapped by plugin, or implement a minimal
custom solver for predictable control.
* Audio plugin runs mixer on separate thread, offers 3D positional audio components.

---

## 10. Memory & allocators

* Global allocator for long-lived objects (e.g., `std.heap.page_allocator`
or custom buddy).
* Frame arena allocator for transient per-frame data; reset each frame.
* Vulkan memory separate, managed through `GpuAllocator` with deferred free.

---

## 11. Build notes (`build.zig`)

* Provide build options:

  * `--release`, `--debug`, `--validate-vulkan` (enable validation layers)
* Include feature flags toggles (e.g., `enable_tracy`, `enable_luajit`).
* Setup targets for examples and test harnesses; expose `run-example <name>`
in build script.

---

## 12. Tests & examples

* `tests/ecs` — unit tests for spawn/despawn, queries, change detection.
* `tests/scheduler` — determinism and conflict resolution tests.
* `examples/basic_triangle`, `examples/pong`, `examples/scene_instancing`
— minimal runnable examples.

---

## 13. Tooling

* `tools/shader_compiler` — pack shaders, compile to SPIR-V, optionally reflect
descriptor sets.
* `tools/asset_packer` — bake textures/meshes for faster load time.
* Dev helper: `tools/reload_watcher` — run with engine to auto-reload changed assets.

---

## 14. Roadmap (recommended milestones)

**MVP** -

* `core` ECS + scheduler (comptime registration)
* basic window + Vulkan swapchain + triangle example
* simple asset loader (blocking)
* minimal Lua embedding and a Lua-driven example

**v1** -

* render graph + GBuffer + lighting
* async asset loaders + hot-reload
* scene/prefab format + instancing
* basic physics plugin + audio plugin

**v2** -

* editor & inspector
* robust profiler & per-system timings
* scripting ergonomics / better API generators for Lua
* platform packaging and CI pipelines

---

## 15. Contributor guidelines (brief)

* Keep core minimal; prefer plugins for domain-specific features.
* All new systems must include tests (unit or integration).
* Use `comptime` for component type registration; avoid runtime reflection in
hot paths.
* Document ABI exposed to Lua in `src/scripting/README.md`.

---

## 16. Quick Zig API sketches

ECS spawn:

```zig
pub fn worldSpawn(world: *World, comps: []ComponentBundle) Entity { ... }
```

System registration:

```zig
pub fn addSystem(comptime fnType: anytype, stage: Stage) void {
    const meta = reflectSystem(comptime fnType);
    scheduler.register(meta);
}
```

Lua binding:

```zig
export fn lua_spawn_entity(L: *lua.State) c_int {
    const e = World.spawn(...);
    lua_pushinteger(L, @intCast(c_long, e.id));
    return 1;
}
```

---

## 17. Next steps / recommended immediate tasks

1. Implement `core.world` and `components` with basic spawn/query/despawn test coverage.
2. Create a minimal `renderer.vk_init` that creates a window, swapchain and
renders a colored triangle.
3. Add `scripting.lua_vm` wrapper and expose simple `spawn_entity`/`add_component`
demo.
4. Wire `build.zig` targets for `examples/basic_triangle` and tests run.

---

## 18. Appendix: file examples

* `src/core/world.zig` — world, entity table, archetype ops
* `src/core/query.zig` — query compile/cache & iterators
* `src/renderer/render_graph.zig` — node registration, resource allocator, pass ordering
* `src/scripting/lua_vm.zig` — create/destroy Lua state, helper marshallers

---

If you'd like, I can:

* produce a `docs/ecs.md` that expands the archetype & query internals into
exact Zig data structures, with runnable unit tests, **or**
* generate a sample `examples/basic_triangle` complete Zig program that wires
`main.zig -> renderer.vk_init -> render loop` so you can get
Vulkan + Zig running immediately, **or**
* produce an `API.md` describing the Lua bindings you should expose and a
script example.

Which of those should I generate next?
