const std = @import("std");
const Core = @import("core.zig");
const sdl3 = Core.sdl3;

const Self = @This();

handle: sdl3.gpu.Shader,

pub const Config = struct {
    filename: [:0]const u8,
    sampler_count: u32 = 0,
    uniform_buffer_count: u32 = 0,
    storage_buffer_count: u32 = 0,
    storage_texture_count: u32 = 0,
};

pub fn init(core: *Core, config: Config) !Self {
    const stage: sdl3.gpu.ShaderStage = if (std.mem.indexOf(u8, config.filename, ".vert") != null)
        .vertex
    else if (std.mem.indexOf(u8, config.filename, ".frag") != null)
        .fragment
    else
        return error.InvalidShaderStage;

    const shader_path = try std.fmt.allocPrintSentinel(
        core.allocator,
        "{s}{s}{s}",
        .{ core.shaders_base_path, config.filename, core.shader_backend.ext },
        0,
    );
    defer core.allocator.free(shader_path);

    const code = try sdl3.io_stream.loadFile(shader_path);
    defer sdl3.free(code);

    const handle = try core.device.createShader(.{
        .code = code,
        .entry_point = core.shader_backend.entrypoint,
        .format = core.shader_backend.format,
        .stage = stage,
        .num_samplers = config.sampler_count,
        .num_uniform_buffers = config.uniform_buffer_count,
        .num_storage_buffers = config.storage_buffer_count,
        .num_storage_textures = config.storage_texture_count,
    });

    return .{ .handle = handle };
}

pub fn deinit(self: Self, core: *Core) void {
    core.device.releaseShader(self.handle);
}
