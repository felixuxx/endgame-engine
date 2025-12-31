const std = @import("std");
const vk = @import("vulkan");

pub const Instance = struct {
    handle: vk.Instance,
    debug_messenger: ?vk.DebugUtilsMessengerEXT,
    allocator: std.mem.Allocator,

    pub fn create(
        allocator: std.mem.Allocator,
        app_name: []const u8,
        enable_validation: bool,
    ) !Instance {
        const app_info = vk.ApplicationInfo{
            .p_application_name = app_name.ptr,
            .application_version = vk.makeApiVersion(0, 1, 0, 0),
            .p_engine_name = "Endgame Engine",
            .engine_version = vk.makeApiVersion(0, 1, 0, 0),
            .api_version = vk.API_VERSION_1_3,
        };

        var extensions = std.ArrayList([*:0]const u8).init(allocator);
        defer extensions.deinit();

        // Platform-specific surface extensions
        try extensions.append(vk.extension_info.khr_surface.name);
        if (@import("builtin").os.tag == .linux) {
            try extensions.append(vk.extension_info.khr_xcb_surface.name);
            try extensions.append(vk.extension_info.khr_xlib_surface.name);
            try extensions.append(vk.extension_info.khr_wayland_surface.name);
        } else if (@import("builtin").os.tag == .windows) {
            try extensions.append(vk.extension_info.khr_win32_surface.name);
        }

        if (enable_validation) {
            try extensions.append(vk.extension_info.ext_debug_utils.name);
        }

        var layers = std.ArrayList([*:0]const u8).init(allocator);
        defer layers.deinit();

        if (enable_validation) {
            try layers.append("VK_LAYER_KHRONOS_validation");
        }

        const create_info = vk.InstanceCreateInfo{
            .p_application_info = &app_info,
            .enabled_extension_count = @intCast(extensions.items.len),
            .pp_enabled_extension_names = extensions.items.ptr,
            .enabled_layer_count = @intCast(layers.items.len),
            .pp_enabled_layer_names = layers.items.ptr,
        };

        const instance = try vk.createInstance(&create_info, null);

        var debug_messenger: ?vk.DebugUtilsMessengerEXT = null;
        if (enable_validation) {
            debug_messenger = try setupDebugMessenger(instance);
        }

        return Instance{
            .handle = instance,
            .debug_messenger = debug_messenger,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Instance) void {
        if (self.debug_messenger) |messenger| {
            vk.destroyDebugUtilsMessengerEXT(self.handle, messenger, null);
        }
        vk.destroyInstance(self.handle, null);
    }

    fn setupDebugMessenger(instance: vk.Instance) !vk.DebugUtilsMessengerEXT {
        const create_info = vk.DebugUtilsMessengerCreateInfoEXT{
            .message_severity = .{
                .verbose_bit_ext = true,
                .warning_bit_ext = true,
                .error_bit_ext = true,
            },
            .message_type = .{
                .general_bit_ext = true,
                .validation_bit_ext = true,
                .performance_bit_ext = true,
            },
            .pfn_user_callback = debugCallback,
            .p_user_data = null,
        };

        return try vk.createDebugUtilsMessengerEXT(instance, &create_info, null);
    }

    fn debugCallback(
        message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
        message_types: vk.DebugUtilsMessageTypeFlagsEXT,
        p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
        p_user_data: ?*anyopaque,
    ) callconv(vk.vulkan_call_conv) vk.Bool32 {
        _ = message_types;
        _ = p_user_data;

        if (p_callback_data) |data| {
            const severity_str = if (message_severity.error_bit_ext)
                "ERROR"
            else if (message_severity.warning_bit_ext)
                "WARNING"
            else if (message_severity.info_bit_ext)
                "INFO"
            else
                "VERBOSE";

            std.debug.print("[Vulkan {s}] {s}\n", .{ severity_str, data.p_message });
        }

        return vk.FALSE;
    }
};
