const std = @import("std");
const vk = @import("vulkan");
const Device = @import("device.zig").Device;

pub const Swapchain = struct {
    handle: vk.SwapchainKHR,
    images: []vk.Image,
    image_views: []vk.ImageView,
    format: vk.Format,
    extent: vk.Extent2D,
    allocator: std.mem.Allocator,

    pub fn create(
        allocator: std.mem.Allocator,
        device: *Device,
        surface: vk.SurfaceKHR,
        width: u32,
        height: u32,
        old_swapchain: ?vk.SwapchainKHR,
    ) !Swapchain {
        const support = try querySwapchainSupport(allocator, device.physical.handle, surface);
        defer {
            allocator.free(support.formats);
            allocator.free(support.present_modes);
        }

        const surface_format = chooseSurfaceFormat(support.formats);
        const present_mode = choosePresentMode(support.present_modes);
        const extent = chooseExtent(support.capabilities, width, height);

        var image_count = support.capabilities.min_image_count + 1;
        if (support.capabilities.max_image_count > 0 and image_count > support.capabilities.max_image_count) {
            image_count = support.capabilities.max_image_count;
        }

        const queue_family_indices = [_]u32{
            device.physical.queue_families.graphics.?,
            device.physical.queue_families.present.?,
        };

        const sharing_mode: vk.SharingMode = if (queue_family_indices[0] != queue_family_indices[1])
            .concurrent
        else
            .exclusive;

        const create_info = vk.SwapchainCreateInfoKHR{
            .surface = surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = sharing_mode,
            .queue_family_index_count = if (sharing_mode == .concurrent) 2 else 0,
            .p_queue_family_indices = if (sharing_mode == .concurrent) &queue_family_indices else null,
            .pre_transform = support.capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = old_swapchain orelse .null_handle,
        };

        const swapchain = try vk.createSwapchainKHR(device.logical, &create_info, null);

        // Get swapchain images
        var swapchain_image_count: u32 = 0;
        try vk.getSwapchainImagesKHR(device.logical, swapchain, &swapchain_image_count, null);

        const images = try allocator.alloc(vk.Image, swapchain_image_count);
        errdefer allocator.free(images);

        try vk.getSwapchainImagesKHR(device.logical, swapchain, &swapchain_image_count, images.ptr);

        // Create image views
        const image_views = try allocator.alloc(vk.ImageView, images.len);
        errdefer allocator.free(image_views);

        for (images, 0..) |image, i| {
            const view_create_info = vk.ImageViewCreateInfo{
                .image = image,
                .view_type = .@"2d",
                .format = surface_format.format,
                .components = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };

            image_views[i] = try vk.createImageView(device.logical, &view_create_info, null);
        }

        return Swapchain{
            .handle = swapchain,
            .images = images,
            .image_views = image_views,
            .format = surface_format.format,
            .extent = extent,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Swapchain, device: vk.Device) void {
        for (self.image_views) |view| {
            vk.destroyImageView(device, view, null);
        }
        self.allocator.free(self.image_views);
        self.allocator.free(self.images);
        vk.destroySwapchainKHR(device, self.handle, null);
    }

    pub fn acquireNextImage(
        self: *Swapchain,
        device: vk.Device,
        semaphore: vk.Semaphore,
        fence: vk.Fence,
    ) !u32 {
        const result = try vk.acquireNextImageKHR(
            device,
            self.handle,
            std.math.maxInt(u64),
            semaphore,
            fence,
        );
        return result.image_index;
    }
};

const SwapchainSupportDetails = struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,
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

fn chooseSurfaceFormat(formats: []vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    for (formats) |format| {
        if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
            return format;
        }
    }
    return formats[0];
}

fn choosePresentMode(present_modes: []vk.PresentModeKHR) vk.PresentModeKHR {
    for (present_modes) |mode| {
        if (mode == .mailbox_khr) {
            return mode;
        }
    }
    return .fifo_khr; // Guaranteed to be available
}

fn chooseExtent(capabilities: vk.SurfaceCapabilitiesKHR, width: u32, height: u32) vk.Extent2D {
    if (capabilities.current_extent.width != std.math.maxInt(u32)) {
        return capabilities.current_extent;
    }

    return vk.Extent2D{
        .width = std.math.clamp(width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
        .height = std.math.clamp(height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
    };
}
