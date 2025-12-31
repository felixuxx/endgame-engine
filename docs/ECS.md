# ECS Specification

**Zig + Archetype ECS Architecture**
Version 1.0

This document defines the Entity–Component–System (ECS) architecture used in the engine.
It describes the core data structures, memory model, APIs, and system scheduling rules.

---

# 1. Goals

* **High performance**: cache-friendly archetype storage, minimal pointer chasing.
* **Predictability**: stable rules for system ordering and component access.
* **Parallelism**: scheduler resolves conflicts and executes systems in batches.
* **Comptime ergonomics**: component registration and system metadata are generated at compile time.
* **Integrates with scripting**: Lua systems map into the same scheduling model.

---

# 2. Core Concepts Overview

### Entity

A stable handle pointing to data stored in archetypes.

### Component

Plain data type attached to an entity. No logic.

### Archetype

A table of entities that share the same set of components.

### Chunk

A contiguous memory block inside an archetype storing components for *N* entities.

### Query

A view over archetypes that contain a required component set.

### System

A function that runs each frame and declares which components/resources it reads/writes.

### Commands

A deferred mutation buffer for entity creation, destruction, and component changes.

---

# 3. Entity Model

### Entity Handle

```zig
pub const Entity = extern struct {
    id: u32,
    generation: u32,
};
```

### Entity Table

Maintains:

* current generation
* free-list for recycling
* mapping → `(archetype_id, row_index)`

### Guarantees

* Entity handle remains stable until despawned.
* Accessing a dead entity returns error unless explicitly allowed.

---

# 4. Component Registry

Components are registered at **comptime**.

```zig
pub fn registerComponent(comptime T: type) ComponentId;
```

Metadata stored:

* name
* type info
* size, align
* optional `drop` function (for buffers, strings, custom resources)

Additionally:

* system metadata uses component registry for dependency resolution
* Lua bindings auto-register components via a small wrapper

---

# 5. Archetypes

An **archetype** is keyed by a sorted component set.

```
Archetype(ComponentSet = {Transform, Velocity, Renderable})
```

### Internal Layout

```
Archetype
 ├─ entities: []Entity
 ├─ columns:
 │    ├─ Transform: []Transform
 │    ├─ Velocity:  []Velocity
 │    └─ Renderable:[]Renderable
 └─ chunk_size: usize
```

* Columns store tightly packed component arrays.
* Index `i` refers to the same entity across all columns.
* Growing an archetype moves to a new chunk; shrinking leaves holes until compaction.

### Moving Entities Between Archetypes

Occurs when adding/removing components:

1. Remove row from source (swap-remove).
2. Insert row into target archetype.
3. Update entity table mapping.

Moves are fast (memcpy per component).

---

# 6. Chunks

Archetypes are divided into fixed-size chunks (e.g., 16–64 KB).
Benefits:

* predictable layout
* fewer allocations
* better CPU cache locality

Chunk contains:

* columns with SoA layout
* allocation cursor
* optional "change ticks" per component

---

# 7. Change Tracking

Each component column optionally stores a `last_changed_tick: u32`.

Global:

```
world.change_tick += 1;
```

System uses:

* `query.changed(Component)`
* `Res<T>.isChangedSince(last_run_tick)`

Change ticks are wrapped mod 2^32; comparisons use modular arithmetic.

---

# 8. Queries

Query is defined at comptime:

```zig
pub fn query(
    comptime Reads: type, 
    comptime Writes: type
) QueryHandle;
```

Example:

```zig
const Q = query(.{ Transform, Velocity }, .{});
```

### Query Matching

At runtime:

* build required component mask
* for each archetype → if `(archetype.components ⊇ query.reads+writes)` → include

### Query Iterator

Returned iterator yields:

```
struct {
    entities: []Entity,
    t: []const Transform,
    v: []Velocity,
}
```

* If a component is writable, array is mutable.
* Iteration is chunk-aware but abstracted from user.

---

# 9. Commands (Deferred Mutations)

Mutations are not applied during system execution.

```zig
commands.spawn(.{ Transform{...}, Velocity{...} });
commands.despawn(e);
commands.add(e, Renderable{...});
commands.remove(e, Velocity);
```

At end of frame:

* Apply in deterministic order
* Moves entities between archetypes if required
* Dead entities enter free-list

---

# 10. System Declaration

A system is any function with compatible signature:

```zig
fn mySystem(q: Query(Reads, Writes), res: *Resources, cmd: *Commands) void {}
```

Metadata extracted at comptime:

* reads & writes
* labels
* before/after constraints
* whether system is thread-safe
* whether system is “exclusive” (rare)

Systems are registered inside engine stages.

---

# 11. Scheduler

The scheduler:

1. Collects system metadata
2. Builds a dependency graph
3. Solves ordering + detects conflicts
4. Produces parallel execution batches

### Conflict Rules

Two systems conflict if:

* both write the same component
* one writes a component another reads
* both write the same resource
* Lua scripts are always considered at least “readers” of all script-accessible components

### Scheduler Output Example

```
[Batch 0]
  - input_system (reads Input)
  - ai_system (reads Transform; writes Target)
[Batch 1]
  - movement_system (writes Transform, Velocity)
  - animation_system (reads Transform; writes Animation)
[Batch 2]
  - physics_step (writes Transform, Velocity)
```

Batches run on multiple worker threads.

---

# 12. Stages

Default:

```
Startup
PreUpdate
Update
PostUpdate
PreRender
Render
PostRender
Cleanup
```

System → stage mapping is defined at registration:

```zig
app.addSystem(.Update, mySystem);
```

---

# 13. Resources

Resources are singletons stored in a hash map:

```zig
world.resources.put(Time, Time{...});
```

Access:

* `Res<T>` (read only)
* `ResMut<T>` (read/write)

Resources obey same conflict rules as components.

---

# 14. Scripting Integration (Lua)

Lua systems are registered like normal systems:

```lua
function update(dt)
    -- read Transform, write Velocity
end
```

Binding metadata:

* Lua system declares required components/resources via registration API
* Scheduler treats Lua systems as first-class systems
* Lua cannot bypass ECS safety rules

---

# 15. Error Handling

All ECS operations return `!Error` except hot paths which panic internally:

* `spawn` / `despawn` → error if entity invalid
* `getMut` → error if missing component
* `query` iteration → no error, guaranteed safe

Optional: enable debug mode with runtime asserts.

---

# 16. Memory Model Summary

* Archetypes own chunks of contiguous component arrays
* Entities move between archetypes on mutation
* Commands buffer protects from mid-frame mutation
* Multi-threading allowed only on conflict-free queries
* All ECS data is stored in engine’s main allocator

---

# 17. API Examples

### Spawning

```zig
const e = cmd.spawn(.{
    Transform{ .pos = .{0,0,0} },
    Velocity{ .x = 1, .y = 0 },
});
```

### Querying

```zig
fn movementSystem(q: Query(.{Transform, Velocity}, .{}), dt: f32) void {
    var iter = q.iterator();
    while (iter.next()) |batch| {
        for (batch.i) |i| {
            batch.t[i].pos += batch.v[i] * dt;
        }
    }
}
```

### Adding a component

```zig
cmd.add(e, Renderable{ .mesh = handle });
```

---

# 18. Implementation Order (Recommended)

1. Component registry
2. Entity table
3. Archetype + chunk allocator
4. Commands
5. Query matching + iterator
6. Scheduler
7. Stages + App integration
8. Lua systems
9. Debug tooling (archetype inspector, system graph visualizer)

---

# 19. Future Extensions

* Packed bitsets for faster archetype matching
* SOA+SIMD micro-optimizations
* Optional sparse components stored externally
* Debug UI showing archetypes and system timings
* Serialization of whole worlds

---

# 20. Appendix: Data Diagram

```
World
 ├── entity_table
 ├── archetypes[]
 │     ├── columns[]
 │     ├── entities[]
 │     └── chunks[]
 ├── resources
 └── scheduler
        ├── systems[]
        └── batches[]
```

---

End of ECS specification.
