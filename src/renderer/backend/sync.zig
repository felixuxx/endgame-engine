const std = @import("std");
const vk = @import("vulkan");

pub const FrameSync = struct {
    image_available: vk.Semaphore,
    render_finished: vk.Semaphore,
    in_flight_fence: vk.Fence,
    device: vk.Device,

    pub fn create(device: vk.Device) !FrameSync {
        const semaphore_info = vk.SemaphoreCreateInfo{};
        const fence_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = true }, // Start signaled so first frame doesn't wait
        };

        return FrameSync{
            .image_available = try vk.createSemaphore(device, &semaphore_info, null),
            .render_finished = try vk.createSemaphore(device, &semaphore_info, null),
            .in_flight_fence = try vk.createFence(device, &fence_info, null),
            .device = device,
        };
    }

    pub fn deinit(self: *FrameSync) void {
        vk.destroySemaphore(self.device, self.image_available, null);
        vk.destroySemaphore(self.device, self.render_finished, null);
        vk.destroyFence(self.device, self.in_flight_fence, null);
    }

    pub fn waitForFence(self: *FrameSync, timeout: u64) !void {
        const fences = [_]vk.Fence{self.in_flight_fence};
        try vk.waitForFences(self.device, 1, &fences, vk.TRUE, timeout);
    }

    pub fn resetFence(self: *FrameSync) !void {
        const fences = [_]vk.Fence{self.in_flight_fence};
        try vk.resetFences(self.device, 1, &fences);
    }
};

pub const FrameInFlight = struct {
    sync: []FrameSync,
    current_frame: u32,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, device: vk.Device, count: u32) !FrameInFlight {
        const sync = try allocator.alloc(FrameSync, count);
        errdefer allocator.free(sync);

        for (sync) |*s| {
            s.* = try FrameSync.create(device);
        }

        return FrameInFlight{
            .sync = sync,
            .current_frame = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FrameInFlight) void {
        for (self.sync) |*s| {
            s.deinit();
        }
        self.allocator.free(self.sync);
    }

    pub fn getCurrentSync(self: *FrameInFlight) *FrameSync {
        return &self.sync[self.current_frame];
    }

    pub fn advance(self: *FrameInFlight) void {
        self.current_frame = (self.current_frame + 1) % @as(u32, @intCast(self.sync.len));
    }
};
