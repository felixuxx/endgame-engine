const std = @import("std");
const vk = @import("vulkan");
const Instance = @import("backend/instance.zig").Instance;
const Device = @import("backend/device.zig").Device;
const Swapchain = @import("backend/swapchain.zig").Swapchain;
const CommandPool = @import("backend/command.zig").CommandPool;
const FrameInFlight = @import("backend/sync.zig").FrameInFlight;
const memory = @import("backend/memory.zig");

pub const VulkanContext = struct {
    allocator: std.mem.Allocator,
    instance: Instance,
    surface: vk.SurfaceKHR,
    device: Device,
    swapchain: Swapchain,
    command_pool: CommandPool,
    command_buffers: []vk.CommandBuffer,
    render_pass: vk.RenderPass,
    framebuffers: []vk.Framebuffer,
    pipeline_layout: vk.PipelineLayout,
    graphics_pipeline: vk.Pipeline,
    frames_in_flight: FrameInFlight,

    pub fn create(
        allocator: std.mem.Allocator,
        app_name: []const u8,
        window_handle: anytype,
        width: u32,
        height: u32,
        enable_validation: bool,
    ) !VulkanContext {
        // Create instance
        var instance = try Instance.create(allocator, app_name, enable_validation);
        errdefer instance.deinit();

        // Create surface (platform-specific, simplified here)
        const surface = try createSurface(instance.handle, window_handle);
        errdefer vk.destroySurfaceKHR(instance.handle, surface, null);

        // Create device
        var device = try Device.create(allocator, instance.handle, surface);
        errdefer device.deinit();

        // Create swapchain
        var swapchain = try Swapchain.create(allocator, &device, surface, width, height, null);
        errdefer swapchain.deinit(device.logical);

        // Create command pool
        var command_pool = try CommandPool.create(
            device.logical,
            device.physical.queue_families.graphics.?,
            .{ .reset_command_buffer_bit = true },
        );
        errdefer command_pool.deinit();

        // Create render pass
        const render_pass = try createRenderPass(device.logical, swapchain.format);
        errdefer vk.destroyRenderPass(device.logical, render_pass, null);

        // Create framebuffers
        const framebuffers = try createFramebuffers(
            allocator,
            device.logical,
            render_pass,
            swapchain.image_views,
            swapchain.extent,
        );
        errdefer {
            for (framebuffers) |fb| vk.destroyFramebuffer(device.logical, fb, null);
            allocator.free(framebuffers);
        }

        // Create pipeline
        const pipeline_layout = try createPipelineLayout(device.logical);
        errdefer vk.destroyPipelineLayout(device.logical, pipeline_layout, null);

        const graphics_pipeline = try createGraphicsPipeline(
            allocator,
            device.logical,
            render_pass,
            pipeline_layout,
            swapchain.extent,
        );
        errdefer vk.destroyPipeline(device.logical, graphics_pipeline, null);

        // Create command buffers
        const command_buffers = try command_pool.allocateBuffers(
            allocator,
            @intCast(swapchain.images.len),
            .primary,
        );
        errdefer command_pool.freeBuffers(allocator, command_buffers);

        // Create frame sync objects
        var frames_in_flight = try FrameInFlight.create(allocator, device.logical, 2);
        errdefer frames_in_flight.deinit();

        return VulkanContext{
            .allocator = allocator,
            .instance = instance,
            .surface = surface,
            .device = device,
            .swapchain = swapchain,
            .command_pool = command_pool,
            .command_buffers = command_buffers,
            .render_pass = render_pass,
            .framebuffers = framebuffers,
            .pipeline_layout = pipeline_layout,
            .graphics_pipeline = graphics_pipeline,
            .frames_in_flight = frames_in_flight,
        };
    }

    pub fn deinit(self: *VulkanContext) void {
        _ = self.device.waitIdle() catch {};

        self.frames_in_flight.deinit();
        self.command_pool.freeBuffers(self.allocator, self.command_buffers);
        vk.destroyPipeline(self.device.logical, self.graphics_pipeline, null);
        vk.destroyPipelineLayout(self.device.logical, self.pipeline_layout, null);

        for (self.framebuffers) |fb| {
            vk.destroyFramebuffer(self.device.logical, fb, null);
        }
        self.allocator.free(self.framebuffers);

        vk.destroyRenderPass(self.device.logical, self.render_pass, null);
        self.command_pool.deinit();
        self.swapchain.deinit(self.device.logical);
        self.device.deinit();
        vk.destroySurfaceKHR(self.instance.handle, self.surface, null);
        self.instance.deinit();
    }

    pub fn drawFrame(self: *VulkanContext) !void {
        const sync = self.frames_in_flight.getCurrentSync();

        // Wait for previous frame
        try sync.waitForFence(std.math.maxInt(u64));

        // Acquire next image
        const image_index = self.swapchain.acquireNextImage(
            self.device.logical,
            sync.image_available,
            .null_handle,
        ) catch |err| {
            if (err == error.OutOfDateKHR) {
                // TODO: Handle swapchain recreation
                return;
            }
            return err;
        };

        try sync.resetFence();

        // Record command buffer
        const cmd = self.command_buffers[image_index];
        try vk.resetCommandBuffer(cmd, .{});

        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{},
            .p_inheritance_info = null,
        };
        try vk.beginCommandBuffer(cmd, &begin_info);

        const clear_color = vk.ClearValue{
            .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 1.0 } },
        };

        const render_pass_info = vk.RenderPassBeginInfo{
            .render_pass = self.render_pass,
            .framebuffer = self.framebuffers[image_index],
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapchain.extent,
            },
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear_color),
        };

        vk.cmdBeginRenderPass(cmd, &render_pass_info, .@"inline");
        vk.cmdBindPipeline(cmd, .graphics, self.graphics_pipeline);

        const viewport = vk.Viewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swapchain.extent.width),
            .height = @floatFromInt(self.swapchain.extent.height),
            .min_depth = 0.0,
            .max_depth = 1.0,
        };
        vk.cmdSetViewport(cmd, 0, 1, @ptrCast(&viewport));

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain.extent,
        };
        vk.cmdSetScissor(cmd, 0, 1, @ptrCast(&scissor));

        vk.cmdDraw(cmd, 3, 1, 0, 0);
        vk.cmdEndRenderPass(cmd);

        try vk.endCommandBuffer(cmd);

        // Submit
        const wait_semaphores = [_]vk.Semaphore{sync.image_available};
        const wait_stages = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
        const signal_semaphores = [_]vk.Semaphore{sync.render_finished};
        const cmd_buffers = [_]vk.CommandBuffer{cmd};

        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &wait_semaphores,
            .p_wait_dst_stage_mask = @ptrCast(&wait_stages),
            .command_buffer_count = 1,
            .p_command_buffers = &cmd_buffers,
            .signal_semaphore_count = 1,
            .p_signal_semaphores = &signal_semaphores,
        };

        try vk.queueSubmit(self.device.graphics_queue, 1, @ptrCast(&submit_info), sync.in_flight_fence);

        // Present
        const swapchains = [_]vk.SwapchainKHR{self.swapchain.handle};
        const image_indices = [_]u32{image_index};

        const present_info = vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &signal_semaphores,
            .swapchain_count = 1,
            .p_swapchains = &swapchains,
            .p_image_indices = &image_indices,
            .p_results = null,
        };

        _ = vk.queuePresentKHR(self.device.present_queue, &present_info) catch |err| {
            if (err == error.OutOfDateKHR or err == error.SuboptimalKHR) {
                // TODO: Handle swapchain recreation
                return;
            }
            return err;
        };

        self.frames_in_flight.advance();
    }
};

fn createSurface(instance: vk.Instance, window_handle: anytype) !vk.SurfaceKHR {
    // This is a placeholder - actual implementation depends on windowing system
    // For GLFW: glfwCreateWindowSurface
    // For SDL: SDL_Vulkan_CreateSurface
    _ = instance;
    _ = window_handle;
    return error.NotImplemented;
}

fn createRenderPass(device: vk.Device, format: vk.Format) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .format = format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment_ref),
        .p_input_attachments = null,
        .p_resolve_attachments = null,
        .p_depth_stencil_attachment = null,
        .preserve_attachment_count = 0,
        .p_preserve_attachments = null,
    };

    const dependency = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
        .dependency_flags = .{},
    };

    const render_pass_info = vk.RenderPassCreateInfo{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 1,
        .p_dependencies = @ptrCast(&dependency),
    };

    return try vk.createRenderPass(device, &render_pass_info, null);
}

fn createFramebuffers(
    allocator: std.mem.Allocator,
    device: vk.Device,
    render_pass: vk.RenderPass,
    image_views: []vk.ImageView,
    extent: vk.Extent2D,
) ![]vk.Framebuffer {
    const framebuffers = try allocator.alloc(vk.Framebuffer, image_views.len);
    errdefer allocator.free(framebuffers);

    for (image_views, 0..) |view, i| {
        const attachments = [_]vk.ImageView{view};

        const framebuffer_info = vk.FramebufferCreateInfo{
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = &attachments,
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        };

        framebuffers[i] = try vk.createFramebuffer(device, &framebuffer_info, null);
    }

    return framebuffers;
}

fn createPipelineLayout(device: vk.Device) !vk.PipelineLayout {
    const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
        .set_layout_count = 0,
        .p_set_layouts = null,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    };

    return try vk.createPipelineLayout(device, &pipeline_layout_info, null);
}

fn createGraphicsPipeline(
    allocator: std.mem.Allocator,
    device: vk.Device,
    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    extent: vk.Extent2D,
) !vk.Pipeline {
    _ = allocator; // Reserved for future shader loading/allocation
    // Load shaders (hardcoded SPIR-V for now)
    const vert_shader_module = try createShaderModule(device, @embedFile("shaders/triangle.vert.spv"));
    defer vk.destroyShaderModule(device, vert_shader_module, null);

    const frag_shader_module = try createShaderModule(device, @embedFile("shaders/triangle.frag.spv"));
    defer vk.destroyShaderModule(device, frag_shader_module, null);

    const vert_stage_info = vk.PipelineShaderStageCreateInfo{
        .stage = .{ .vertex_bit = true },
        .module = vert_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
    };

    const frag_stage_info = vk.PipelineShaderStageCreateInfo{
        .stage = .{ .fragment_bit = true },
        .module = frag_shader_module,
        .p_name = "main",
        .p_specialization_info = null,
    };

    const shader_stages = [_]vk.PipelineShaderStageCreateInfo{ vert_stage_info, frag_stage_info };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = null,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = null,
    };

    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    const viewport = vk.Viewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0.0,
        .max_depth = 1.0,
    };

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    const viewport_state = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = @ptrCast(&viewport),
        .scissor_count = 1,
        .p_scissors = @ptrCast(&scissor),
    };

    const rasterizer = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .line_width = 1.0,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_slope_factor = 0.0,
    };

    const multisampling = vk.PipelineMultisampleStateCreateInfo{
        .sample_shading_enable = vk.FALSE,
        .rasterization_samples = .{ .@"1_bit" = true },
        .min_sample_shading = 1.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
    };

    const color_blending = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_blend_attachment),
        .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
    };

    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic_state = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    const pipeline_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .p_stages = &shader_stages,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &rasterizer,
        .p_multisample_state = &multisampling,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &color_blending,
        .p_dynamic_state = &dynamic_state,
        .layout = pipeline_layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try vk.createGraphicsPipelines(device, .null_handle, 1, @ptrCast(&pipeline_info), null, @ptrCast(&pipeline));

    return pipeline;
}

fn createShaderModule(device: vk.Device, code: []const u8) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = code.len,
        .p_code = @ptrCast(@alignCast(code.ptr)),
    };

    return try vk.createShaderModule(device, &create_info, null);
}
