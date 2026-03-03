pub const sdl3 = @import("sdl3");
const std = @import("std");
pub const za = @import("zalgebra");

const Self = @This();

allocator: std.mem.Allocator,
device: sdl3.gpu.Device,
window: sdl3.video.Window,
shaders_base_path: []const u8,
shader_backend: ShaderBackend,

const ShaderBackend = struct {
    format: sdl3.gpu.ShaderFormatFlags,
    subdir: []const u8,
    ext: []const u8,
    entrypoint: [:0]const u8,
};

const Info = struct {
    title: [:0]const u8,
    width: usize,
    height: usize,
    debug_mode: bool,
    driver_name: ?[:0]const u8 = null,
    allocator: std.mem.Allocator,
};

pub fn init(info: Info) !Self {
    const init_flags = sdl3.InitFlags{ .video = true };
    try sdl3.init(init_flags);
    errdefer sdl3.shutdown();

    const device = try sdl3.gpu.Device.init(.{
        .spirv = true,
        .dxil = true,
        .msl = true,
    }, info.debug_mode, info.driver_name);

    const window = try sdl3.video.Window.init(info.title, info.width, info.height, .{
        .hidden = true,
        .resizable = true,
    });
    errdefer window.deinit();

    try device.claimWindow(window);

    const backend_formats = device.getShaderFormats();

    const shader_backend: ShaderBackend = if (backend_formats.spirv)
        .{ .format = .{ .spirv = true }, .subdir = "SPIRV", .ext = ".spv", .entrypoint = "main" }
    else if (backend_formats.msl)
        .{ .format = .{ .msl = true }, .subdir = "MSL", .ext = ".msl", .entrypoint = "main0" }
    else if (backend_formats.dxil)
        .{ .format = .{ .dxil = true }, .subdir = "DXIL", .ext = ".dxil", .entrypoint = "main" }
    else
        return error.UnrecognizedShaderFormat;

    const base_path = try sdl3.filesystem.getBasePath();

    const shaders_base_path = try std.fmt.allocPrint(
        info.allocator,
        "{s}Content/Shaders/Compiled/{s}/",
        .{ base_path, shader_backend.subdir },
    );
    errdefer info.allocator.free(shaders_base_path);

    try window.show();

    return .{
        .device = device,
        .window = window,
        .shaders_base_path = shaders_base_path,
        .allocator = info.allocator,
        .shader_backend = shader_backend,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.shaders_base_path);
    self.device.releaseWindow(self.window);
    self.window.deinit();
    self.device.deinit();
    sdl3.shutdown();
}

pub fn poll() ?sdl3.events.Event {
    return sdl3.events.poll();
}

const Frame = struct {
    command_buffer: sdl3.gpu.CommandBuffer,
    texture: sdl3.gpu.Texture,
    width: u32,
    height: u32,

    pub fn end(self: Frame) !void {
        try self.command_buffer.submit();
    }

    pub fn renderpass(self: Frame, clear_color: sdl3.pixels.FColor, depth_texture: ?sdl3.gpu.Texture) !sdl3.gpu.RenderPass {
        const depth_info: ?sdl3.gpu.DepthStencilTargetInfo = if (depth_texture) |dt| .{
            .texture = dt,
            .cycle = true,
            .clear_depth = 1.0,
            .clear_stencil = 0,
            .load = .clear,
            .store = .store,
            .stencil_load = .clear,
            .stencil_store = .store,
        } else null;

        const render_pass = self.command_buffer.beginRenderPass(&.{sdl3.gpu.ColorTargetInfo{
            .texture = self.texture,
            .clear_color = clear_color,
            .load = .clear,
            .store = .store,
        }}, if (depth_info) |di| di else null);

        render_pass.setViewport(.{ .max_depth = 1, .region = .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(self.width),
            .h = @floatFromInt(self.height),
        } });
        render_pass.setScissor(.{
            .x = 0,
            .y = 0,
            .w = @intCast(self.width),
            .h = @intCast(self.height),
        });
        return render_pass;
    }
};

pub fn beginFrame(self: *Self) !?Frame {
    const command_buffer = try self.device.acquireCommandBuffer();

    const swapchain = try command_buffer.waitAndAcquireSwapchainTexture(self.window);

    if (swapchain.@"0") |texture| {
        return Frame{
            .command_buffer = command_buffer,
            .texture = texture,
            .width = swapchain.@"1",
            .height = swapchain.@"2",
        };
    }

    return null;
}

const ShaderInfo = struct {
    filename: [:0]const u8,
    sampler_count: u32 = 0,
    uniform_buffer_count: u32 = 0,
    storage_buffer_count: u32 = 0,
    storage_texture_count: u32 = 0,
};

pub fn loadShader(
    self: *Self,
    info: ShaderInfo,
) !sdl3.gpu.Shader {
    const stage: sdl3.gpu.ShaderStage = if (std.mem.indexOf(u8, info.filename, ".vert") != null)
        .vertex
    else if (std.mem.indexOf(u8, info.filename, ".frag") != null)
        .fragment
    else
        return error.InvalidShaderStage;

    const shader_path = try std.fmt.allocPrintSentinel(
        self.allocator,
        "{s}{s}{s}",
        .{ self.shaders_base_path, info.filename, self.shader_backend.ext },
        0,
    );
    defer self.allocator.free(shader_path);

    errdefer std.debug.print("{s}", .{sdl3.errors.get().?});
    const code = try sdl3.io_stream.loadFile(shader_path);
    defer sdl3.free(code);

    return self.device.createShader(.{
        .code = code,
        .entry_point = self.shader_backend.entrypoint,
        .format = self.shader_backend.format,
        .stage = stage,
        .num_samplers = info.sampler_count,
        .num_uniform_buffers = info.uniform_buffer_count,
        .num_storage_buffers = info.storage_buffer_count,
        .num_storage_textures = info.storage_texture_count,
    });
}

pub const Vertex = struct {
    position: za.Vec3,
    uv: za.Vec2,
};

const PipelineInfo = struct {
    vertex_shader: sdl3.gpu.Shader,
    fragment_shader: sdl3.gpu.Shader,
    depth_test: bool = false,
    depth_write: bool = true, // Added this field
};

pub fn createPipeline(self: *Self, info: PipelineInfo) !sdl3.gpu.GraphicsPipeline {
    return self.device.createGraphicsPipeline(.{
        .vertex_shader = info.vertex_shader,
        .fragment_shader = info.fragment_shader,
        .depth_stencil_state = if (info.depth_test) sdl3.gpu.DepthStencilState{
            .enable_depth_test = true,
            .enable_depth_write = info.depth_write, // Use the new field here
            .compare = .less_or_equal, // .less_equal is better for skyboxes
            .write_mask = if (info.depth_write) 0xFF else 0,
        } else .{},
        .target_info = sdl3.gpu.GraphicsPipelineTargetInfo{
            .color_target_descriptions = &.{
                sdl3.gpu.ColorTargetDescription{
                    .format = try self.device.getSwapchainTextureFormat(self.window),
                },
            },
            .depth_stencil_format = if (info.depth_test) .depth16_unorm else null,
        },
        .vertex_input_state = sdl3.gpu.VertexInputState{
            .vertex_buffer_descriptions = &.{
                sdl3.gpu.VertexBufferDescription{
                    .input_rate = .vertex,
                    .slot = 0,
                    .pitch = @sizeOf(Vertex),
                },
            },
            .vertex_attributes = &.{
                sdl3.gpu.VertexAttribute{
                    .buffer_slot = 0,
                    .format = .f32x3,
                    .location = 0,
                    .offset = @offsetOf(Vertex, "position"),
                },
                sdl3.gpu.VertexAttribute{
                    .buffer_slot = 0,
                    .format = .f32x2,
                    .location = 1,
                    .offset = @offsetOf(Vertex, "uv"),
                },
            },
        },
    });
}

pub fn createDepthTexture(self: *Self, width: u32, height: u32) !sdl3.gpu.Texture {
    return self.device.createTexture(.{
        .width = width,
        .height = height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = .no_multisampling,
        .format = .depth16_unorm,
        .usage = .{ .depth_stencil_target = true },
    });
}

pub fn createSampler(self: *Self, info: sdl3.gpu.SamplerCreateInfo) !sdl3.gpu.Sampler {
    return try self.device.createSampler(info);
}
