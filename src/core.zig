pub const sdl3 = @import("sdl3");
const std = @import("std");
pub const za = @import("zalgebra");

const StagingBelt = @import("staging_belt.zig");

const Self = @This();

// --- Hardware & OS Context ---
allocator: std.mem.Allocator,
device: sdl3.gpu.Device,
window: sdl3.video.Window,

// --- Memory Management ---
staging_belt: StagingBelt,

// --- Shader Backend Metadata ---
shaders_base_path: []const u8,
shader_backend: ShaderBackend,

pub const ShaderBackend = struct {
    format: sdl3.gpu.ShaderFormatFlags,
    subdir: []const u8,
    ext: []const u8,
    entrypoint: [:0]const u8,
};

pub const Info = struct {
    title: [:0]const u8,
    width: usize,
    height: usize,
    debug_mode: bool,
    driver_name: ?[:0]const u8 = null,
    allocator: std.mem.Allocator,
    // Default to 1MB chunks for the staging belt
    staging_chunk_size: u32 = 1024 * 1024,
};

pub fn init(info: Info) !*Self {
    try sdl3.init(.{ .video = true });
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
    errdefer {
        window.deinit();
        device.deinit();
    }

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

    const self = try info.allocator.create(Self);
    self.* = .{
        .device = device,
        .window = window,
        .shaders_base_path = shaders_base_path,
        .allocator = info.allocator,
        .shader_backend = shader_backend,
        .staging_belt = StagingBelt.init(self, info.staging_chunk_size),
    };

    try window.show();
    return self;
}

pub fn deinit(self: *Self) void {
    const allocator = self.allocator;

    // Clean up memory management
    self.staging_belt.deinit();

    // Clean up SDL3 resources
    allocator.free(self.shaders_base_path);
    self.device.releaseWindow(self.window);
    self.window.deinit();
    self.device.deinit();
    sdl3.shutdown();

    // Free the Core struct itself
    allocator.destroy(self);
}

pub fn poll() ?sdl3.events.Event {
    return sdl3.events.poll();
}

// --- Frame Management ---

pub const Frame = struct {
    core: *Self,
    command_buffer: sdl3.gpu.CommandBuffer,
    texture: sdl3.gpu.Texture,
    width: u32,
    height: u32,

    /// Submits the command buffer and synchronizes the staging belt.
    pub fn end(self: Frame) !void {
        // Acquire a fence so the belt knows when the GPU is done with this frame's data
        const fence = try self.command_buffer.submitAndAcquireFence();

        // Move active chunks to the 'closed' queue associated with this fence
        try self.core.staging_belt.finish(fence);

        // The belt will release the fence once it recalls the chunks
        self.core.device.releaseFence(fence);
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

        const rp = self.command_buffer.beginRenderPass(&.{.{
            .texture = self.texture,
            .clear_color = clear_color,
            .load = .clear,
            .store = .store,
        }}, depth_info);

        rp.setViewport(.{
            .max_depth = 1.0,
            .region = .{
                .x = 0,
                .y = 0,
                .w = @floatFromInt(self.width),
                .h = @floatFromInt(self.height),
            },
        });

        rp.setScissor(.{
            .x = 0,
            .y = 0,
            .w = @intCast(self.width),
            .h = @intCast(self.height),
        });

        return rp;
    }
};

pub fn beginFrame(self: *Self) !?Frame {
    try self.staging_belt.recall();

    const cb = try self.device.acquireCommandBuffer();

    // Attempt to acquire the swapchain texture
    const swapchain = try cb.waitAndAcquireSwapchainTexture(self.window);

    if (swapchain.@"0") |texture| {
        return Frame{
            .core = self,
            .command_buffer = cb,
            .texture = texture,
            .width = swapchain.@"1",
            .height = swapchain.@"2",
        };
    }

    // If we couldn't get a texture (e.g., window minimized), discard the command buffer
    try cb.submit();
    return null;
}
