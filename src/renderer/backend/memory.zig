const std = @import("std");
const vk = @import("vulkan");

pub const Buffer = struct {
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
    size: vk.DeviceSize,

    pub fn deinit(self: *Buffer, device: vk.Device) void {
        vk.destroyBuffer(device, self.handle, null);
        vk.freeMemory(device, self.memory, null);
    }
};

pub const Image = struct {
    handle: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,

    pub fn deinit(self: *Image, device: vk.Device) void {
        vk.destroyImageView(device, self.view, null);
        vk.destroyImage(device, self.handle, null);
        vk.freeMemory(device, self.memory, null);
    }
};

pub fn createBuffer(
    device: vk.Device,
    physical_device: vk.PhysicalDevice,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    properties: vk.MemoryPropertyFlags,
) !Buffer {
    const buffer_info = vk.BufferCreateInfo{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = null,
    };

    const buffer = try vk.createBuffer(device, &buffer_info, null);
    errdefer vk.destroyBuffer(device, buffer, null);

    const mem_requirements = vk.getBufferMemoryRequirements(device, buffer);

    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = mem_requirements.size,
        .memory_type_index = try findMemoryType(physical_device, mem_requirements.memory_type_bits, properties),
    };

    const memory = try vk.allocateMemory(device, &alloc_info, null);
    errdefer vk.freeMemory(device, memory, null);

    try vk.bindBufferMemory(device, buffer, memory, 0);

    return Buffer{
        .handle = buffer,
        .memory = memory,
        .size = size,
    };
}

pub fn copyBuffer(
    device: vk.Device,
    command_pool: vk.CommandPool,
    queue: vk.Queue,
    src: vk.Buffer,
    dst: vk.Buffer,
    size: vk.DeviceSize,
) !void {
    const command = @import("command.zig");

    try command.withTransientCommand(device, command_pool, queue, struct {
        fn copy(cmd: vk.CommandBuffer) !void {
            const copy_region = vk.BufferCopy{
                .src_offset = 0,
                .dst_offset = 0,
                .size = size,
            };
            vk.cmdCopyBuffer(cmd, src, dst, 1, @ptrCast(&copy_region));
        }
    }.copy);
}

pub fn createBufferWithData(
    comptime T: type,
    device: vk.Device,
    physical_device: vk.PhysicalDevice,
    command_pool: vk.CommandPool,
    queue: vk.Queue,
    data: []const T,
    usage: vk.BufferUsageFlags,
) !Buffer {
    const size: vk.DeviceSize = @sizeOf(T) * data.len;

    // Create staging buffer
    var staging = try createBuffer(
        device,
        physical_device,
        size,
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    );
    defer staging.deinit(device);

    // Copy data to staging buffer
    const mapped = try vk.mapMemory(device, staging.memory, 0, size, .{});
    @memcpy(@as([*]u8, @ptrCast(mapped))[0..size], std.mem.sliceAsBytes(data));
    vk.unmapMemory(device, staging.memory);

    // Create device local buffer
    var buffer_usage = usage;
    buffer_usage.transfer_dst_bit = true;

    const buffer = try createBuffer(
        device,
        physical_device,
        size,
        buffer_usage,
        .{ .device_local_bit = true },
    );
    errdefer buffer.deinit(device);

    // Copy from staging to device local
    try copyBuffer(device, command_pool, queue, staging.handle, buffer.handle, size);

    return buffer;
}

fn findMemoryType(
    physical_device: vk.PhysicalDevice,
    type_filter: u32,
    properties: vk.MemoryPropertyFlags,
) !u32 {
    const mem_properties = vk.getPhysicalDeviceMemoryProperties(physical_device);

    var i: u32 = 0;
    while (i < mem_properties.memory_type_count) : (i += 1) {
        const type_bit = @as(u32, 1) << @intCast(i);
        if ((type_filter & type_bit) != 0) {
            const prop_flags = mem_properties.memory_types[i].property_flags;
            if (prop_flags.host_visible_bit == properties.host_visible_bit and
                prop_flags.host_coherent_bit == properties.host_coherent_bit and
                prop_flags.device_local_bit == properties.device_local_bit)
            {
                return i;
            }
        }
    }

    return error.NoSuitableMemoryType;
}
