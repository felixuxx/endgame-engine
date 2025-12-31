# Endgame Engine

A modern, ECS-first game engine written in Zig, designed for performance,
modularity, and developer ergonomics.

## Features

- **ECS-first architecture**: Archetype-based ECS optimized for cache locality
and fast iteration.
- **Vulkan renderer**: Explicit, render graph-driven, triple-buffered frames-in-flight.
- **Lua scripting**: Sandboxed high-level logic with registered Lua systems.
- **Modular & pluginable**: Core stays minimal; features like physics, audio,
and UI are plugins.
- **Zig-first ergonomics**: Utilizes `comptime` for component registration,
safe explicit memory rules, and a small runtime.

## Documentation

- [Architecture Overview](ARCHITECTURE.md)
- [ECS Specification](ECS.md)
- [Renderer Plan](renderer/RENDERER_PLAN.md)
- [Render Backend](renderer/RENDER_BACKEND.md)
- [Render Graph](renderer/RENDER_GRAPH.md)

## Getting Started

### Prerequisites

- Zig compiler (latest stable)
- Vulkan SDK
- Lua (for scripting)

### Building

```bash
zig build
```

### Running Examples

```bash
zig build run-example basic_triangle
```

## Project Structure

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

## Contributing

Please read the [Contributor Guidelines](CONTRIBUTING.md) for details on our code
of conduct and the process for submitting pull requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file
for details.

## Roadmap

- **MVP**: Core ECS, basic Vulkan renderer, minimal Lua embedding.
- **v1**: Render graph, async asset loading, scene/prefab format.
- **v2**: Editor & inspector, robust profiler, scripting ergonomics.

## Contact

For questions or feedback, please open an issue or contact the maintainers.

---
