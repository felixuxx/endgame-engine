const std = @import("std");
const vk = @import("vulkan");

pub const QueueFamilyIndices = struct {
    graphics: ?u32 = null,
    present: ?u32 = null,
    compute: ?u32 = null,
    transfer: ?u32 = null,

    pub fn isComplete(self: QueueFamilyIndices) bool {
        return self.graphics != null and self.present != null;
    }
};

pub const PhysicalDevice = struct {
    handle: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
    features: vk.PhysicalDeviceFeatures,
    queue_families: QueueFamilyIndices,
};

pub const Device = struct {
    physical: PhysicalDevice,
    logical: vk.Device,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
    compute_queue: ?vk.Queue,
    transfer_queue: ?vk.Queue,

    pub fn create(
        allocator: std.mem.Allocator,
        instance: vk.Instance,
        surface: vk.SurfaceKHR,
    ) !Device {
        const physical = try pickPhysicalDevice(allocator, instance, surface);

        var queue_create_infos = std.ArrayList(vk.DeviceQueueCreateInfo).init(allocator);
        defer queue_create_infos.deinit();

        const queue_priority: f32 = 1.0;

        // Graphics queue
        if (physical.queue_families.graphics) |graphics_family| {
            try queue_create_infos.append(.{
                .queue_family_index = graphics_family,
                .queue_count = 1,
                .p_queue_priorities = &queue_priority,
            });
        }

        // Present queue (if different from graphics)
        if (physical.queue_families.present) |present_family| {
            if (physical.queue_families.graphics != present_family) {
                try queue_create_infos.append(.{
                    .queue_family_index = present_family,
                    .queue_count = 1,
                    .p_queue_priorities = &queue_priority,
                });
            }
        }

        const device_extensions = [_][*:0]const u8{
            vk.extension_info.khr_swapchain.name,
        };

        const device_features = vk.PhysicalDeviceFeatures{
            .sampler_anisotropy = vk.TRUE,
        };

        const create_info = vk.DeviceCreateInfo{
            .queue_create_info_count = @intCast(queue_create_infos.items.len),
            .p_queue_create_infos = queue_create_infos.items.ptr,
            .enabled_extension_count = device_extensions.len,
            .pp_enabled_extension_names = &device_extensions,
            .p_enabled_features = &device_features,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
        };

        const logical = try vk.createDevice(physical.handle, &create_info, null);

        const graphics_queue = vk.getDeviceQueue(logical, physical.queue_families.graphics.?, 0);
        const present_queue = vk.getDeviceQueue(logical, physical.queue_families.present.?, 0);

        const compute_queue = if (physical.queue_families.compute) |compute_family|
            vk.getDeviceQueue(logical, compute_family, 0)
        else
            null;

        const transfer_queue = if (physical.queue_families.transfer) |transfer_family|
            vk.getDeviceQueue(logical, transfer_family, 0)
        else
            null;

        return Device{
            .physical = physical,
            .logical = logical,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .compute_queue = compute_queue,
            .transfer_queue = transfer_queue,
        };
    }

    pub fn deinit(self: *Device) void {
        vk.destroyDevice(self.logical, null);
    }

    pub fn waitIdle(self: *Device) !void {
        try vk.deviceWaitIdle(self.logical);
    }
};

fn pickPhysicalDevice(
    allocator: std.mem.Allocator,
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
) !PhysicalDevice {
    var device_count: u32 = 0;
    try vk.enumeratePhysicalDevices(instance, &device_count, null);

    if (device_count == 0) {
        return error.NoVulkanDevices;
    }

    const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(devices);

    try vk.enumeratePhysicalDevices(instance, &device_count, devices.ptr);

    var best_device: ?PhysicalDevice = null;
    var best_score: u32 = 0;

    for (devices) |device| {
        const score = try scoreDevice(allocator, device, surface);
        if (score > best_score) {
            const queue_families = try findQueueFamilies(allocator, device, surface);
            if (queue_families.isComplete()) {
                const properties = vk.getPhysicalDeviceProperties(device);
                const features = vk.getPhysicalDeviceFeatures(device);

                best_device = PhysicalDevice{
                    .handle = device,
                    .properties = properties,
                    .features = features,
                    .queue_families = queue_families,
                };
                best_score = score;
            }
        }
    }

    return best_device orelse error.NoSuitableDevice;
}

fn scoreDevice(
    allocator: std.mem.Allocator,
    device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !u32 {
    const properties = vk.getPhysicalDeviceProperties(device);
    const features = vk.getPhysicalDeviceFeatures(device);

    var score: u32 = 0;

    // Discrete GPUs have a significant performance advantage
    if (properties.device_type == .discrete_gpu) {
        score += 1000;
    }

    // Maximum possible size of textures affects graphics quality
    score += properties.limits.max_image_dimension_2d;

    // Check for required features
    if (features.sampler_anisotropy == vk.FALSE) {
        return 0;
    }

    // Check for swapchain support
    if (!try checkDeviceExtensionSupport(allocator, device)) {
        return 0;
    }

    // Check swapchain adequacy
    const swapchain_support = try querySwapchainSupport(allocator, device, surface);
    defer swapchain_support.deinit(allocator);

    if (swapchain_support.formats.len == 0 or swapchain_support.present_modes.len == 0) {
        return 0;
    }

    return score;
}

fn findQueueFamilies(
    allocator: std.mem.Allocator,
    device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !QueueFamilyIndices {
    var indices = QueueFamilyIndices{};

    var queue_family_count: u32 = 0;
    vk.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

    const queue_families = try allocator.alloc(vk.QueueFamilyProperties, queue_family_count);
    defer allocator.free(queue_families);

    vk.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

    for (queue_families, 0..) |family, i| {
        const index: u32 = @intCast(i);

        if (family.queue_flags.graphics_bit) {
            indices.graphics = index;
        }

        if (family.queue_flags.compute_bit) {
            indices.compute = index;
        }

        if (family.queue_flags.transfer_bit) {
            indices.transfer = index;
        }

        const present_support = try vk.getPhysicalDeviceSurfaceSupportKHR(device, index, surface);
        if (present_support == vk.TRUE) {
            indices.present = index;
        }

        if (indices.isComplete()) {
            break;
        }
    }

    return indices;
}

fn checkDeviceExtensionSupport(allocator: std.mem.Allocator, device: vk.PhysicalDevice) !bool {
    var extension_count: u32 = 0;
    try vk.enumerateDeviceExtensionProperties(device, null, &extension_count, null);

    const available_extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
    defer allocator.free(available_extensions);

    try vk.enumerateDeviceExtensionProperties(device, null, &extension_count, available_extensions.ptr);

    const required_extensions = [_][]const u8{
        std.mem.span(vk.extension_info.khr_swapchain.name),
    };

    for (required_extensions) |required| {
        var found = false;
        for (available_extensions) |available| {
            const available_name = std.mem.sliceTo(&available.extension_name, 0);
            if (std.mem.eql(u8, required, available_name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    return true;
}

const SwapchainSupportDetails = struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,

    fn deinit(self: SwapchainSupportDetails, allocator: std.mem.Allocator) void {
        allocator.free(self.formats);
        allocator.free(self.present_modes);
    }
};

fn querySwapchainSupport(
    allocator: std.mem.Allocator,
    device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !SwapchainSupportDetails {
    const capabilities = try vk.getPhysicalDeviceSurfaceCapabilitiesKHR(device, surface);

    var format_count: u32 = 0;
    try vk.getPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null);

    const formats = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
    try vk.getPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, formats.ptr);

    var present_mode_count: u32 = 0;
    try vk.getPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null);

    const present_modes = try allocator.alloc(vk.PresentModeKHR, present_mode_count);
    try vk.getPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, present_modes.ptr);

    return SwapchainSupportDetails{
        .capabilities = capabilities,
        .formats = formats,
        .present_modes = present_modes,
    };
}
