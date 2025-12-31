const std = @import("vulkan");
const vk = @import("vulkan");

pub const CommandPool = struct {
    handle: vk.CommandPool,
    device: vk.Device,

    pub fn create(device: vk.Device, queue_family_index: u32, flags: vk.CommandPoolCreateFlags) !CommandPool {
        const create_info = vk.CommandPoolCreateInfo{
            .queue_family_index = queue_family_index,
            .flags = flags,
        };

        const pool = try vk.createCommandPool(device, &create_info, null);

        return CommandPool{
            .handle = pool,
            .device = device,
        };
    }

    pub fn deinit(self: *CommandPool) void {
        vk.destroyCommandPool(self.device, self.handle, null);
    }

    pub fn reset(self: *CommandPool) !void {
        try vk.resetCommandPool(self.device, self.handle, .{});
    }

    pub fn allocateBuffers(self: *CommandPool, allocator: std.mem.Allocator, count: u32, level: vk.CommandBufferLevel) ![]vk.CommandBuffer {
        const buffers = try allocator.alloc(vk.CommandBuffer, count);
        errdefer allocator.free(buffers);

        const alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.handle,
            .level = level,
            .command_buffer_count = count,
        };

        try vk.allocateCommandBuffers(self.device, &alloc_info, buffers.ptr);

        return buffers;
    }

    pub fn freeBuffers(self: *CommandPool, allocator: std.mem.Allocator, buffers: []vk.CommandBuffer) void {
        vk.freeCommandBuffers(self.device, self.handle, @intCast(buffers.len), buffers.ptr);
        allocator.free(buffers);
    }
};

/// Helper for one-shot command buffer execution (e.g., for uploads)
pub fn withTransientCommand(
    device: vk.Device,
    pool: vk.CommandPool,
    queue: vk.Queue,
    comptime func: anytype,
) !void {
    const alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    };

    var cmd_buffer: vk.CommandBuffer = undefined;
    try vk.allocateCommandBuffers(device, &alloc_info, @ptrCast(&cmd_buffer));
    defer vk.freeCommandBuffers(device, pool, 1, @ptrCast(&cmd_buffer));

    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };

    try vk.beginCommandBuffer(cmd_buffer, &begin_info);

    try func(cmd_buffer);

    try vk.endCommandBuffer(cmd_buffer);

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmd_buffer),
        .wait_semaphore_count = 0,
        .p_wait_semaphores = null,
        .p_wait_dst_stage_mask = null,
        .signal_semaphore_count = 0,
        .p_signal_semaphores = null,
    };

    try vk.queueSubmit(queue, 1, @ptrCast(&submit_info), .null_handle);
    try vk.queueWaitIdle(queue);
}

pub fn beginCommandBuffer(cmd: vk.CommandBuffer, flags: vk.CommandBufferUsageFlags) !void {
    const begin_info = vk.CommandBufferBeginInfo{
        .flags = flags,
        .p_inheritance_info = null,
    };
    try vk.beginCommandBuffer(cmd, &begin_info);
}

pub fn endCommandBuffer(cmd: vk.CommandBuffer) !void {
    try vk.endCommandBuffer(cmd);
}
