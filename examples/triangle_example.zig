const std = @import("std");
const vk = @import("vulkan");
const c = @import("c.zig");

const app_name = "Endgame Engine - Triangle Example";

pub fn main() !void {
    // Initialize GLFW
    if (c.glfwInit() != c.GLFW_TRUE) {
        std.log.err("Failed to initialize GLFW", .{});
        return error.GlfwInitFailed;
    }
    defer c.glfwTerminate();

    // Check Vulkan support
    if (c.glfwVulkanSupported() != c.GLFW_TRUE) {
        std.log.err("GLFW could not find Vulkan support", .{});
        return error.NoVulkan;
    }

    std.log.info("GLFW initialized successfully", .{});
    std.log.info("Vulkan is supported", .{});

    // Create window
    var extent = vk.Extent2D{ .width = 800, .height = 600 };

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(
        @intCast(extent.width),
        @intCast(extent.height),
        app_name,
        null,
        null,
    ) orelse {
        std.log.err("Failed to create GLFW window", .{});
        return error.WindowInitFailed;
    };
    defer c.glfwDestroyWindow(window);

    // Get actual framebuffer size (may differ from requested size)
    extent.width, extent.height = blk: {
        var w: c_int = undefined;
        var h: c_int = undefined;
        c.glfwGetFramebufferSize(window, &w, &h);
        break :blk .{ @intCast(w), @intCast(h) };
    };

    std.log.info("Window created: {}x{}", .{ extent.width, extent.height });

    // Set up allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // TODO: Initialize Vulkan context
    // TODO: Create swapchain
    // TODO: Create render pass and pipeline
    // TODO: Main render loop

    std.log.info("Phase 1 complete: Window management working!", .{});
    std.log.info("Press Ctrl+C to exit (render loop not yet implemented)", .{});

    // Simple event loop for now
    var frame_count: u32 = 0;
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE and frame_count < 60) : (frame_count += 1) {
        c.glfwPollEvents();
        std.Thread.sleep(16 * std.time.ns_per_ms); // ~60 FPS
    }

    _ = allocator;
    std.log.info("Shutting down cleanly", .{});
}
