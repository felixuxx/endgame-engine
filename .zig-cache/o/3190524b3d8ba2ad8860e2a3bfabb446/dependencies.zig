pub const packages = struct {
    pub const @"libs/vulkan-zig" = struct {
        pub const build_root = "/home/felixuxx/Projects/gamedev/endgame-engine/libs/vulkan-zig";
        pub const build_zig = @import("libs/vulkan-zig");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "vulkan-zig", "libs/vulkan-zig" },
};
