pub const sdl3 = @import("sdl3");
const std = @import("std");

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

    pub fn renderpass(self: Frame, clear_color: sdl3.pixels.FColor) !sdl3.gpu.RenderPass {
        const render_pass = self.command_buffer.beginRenderPass(&.{sdl3.gpu.ColorTargetInfo{
            .texture = self.texture,
            .clear_color = clear_color,
            .load = .clear,
            .store = .store,
        }}, null);
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

const PipelineInfo = struct {
    vertex_shader: sdl3.gpu.Shader,
    fragment_shader: sdl3.gpu.Shader,
};

pub fn createPipeline(self: *Self, info: PipelineInfo) !sdl3.gpu.GraphicsPipeline {
    const pipeline = try self.device.createGraphicsPipeline(
        .{
            .vertex_shader = info.vertex_shader,
            .fragment_shader = info.fragment_shader,
            .target_info = .{
                .color_target_descriptions = &.{
                    sdl3.gpu.ColorTargetDescription{
                        .format = try self.device.getSwapchainTextureFormat(self.window),
                    },
                },
            },
        },
    );

    return pipeline;
}
