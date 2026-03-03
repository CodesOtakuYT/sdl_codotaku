const Core = @import("core.zig");
const sdl3 = Core.sdl3;
const Shader = @import("shader.zig");

const Self = @This();

handle: sdl3.gpu.GraphicsPipeline,

pub const Config = struct {
    vert: Shader,
    frag: Shader,
    depth_test: bool = false,
    depth_write: bool = true,
};

pub fn init(core: *Core, config: Config) !Self {
    const handle = try core.device.createGraphicsPipeline(.{
        .vertex_shader = config.vert.handle,
        .fragment_shader = config.frag.handle,
        .depth_stencil_state = if (config.depth_test) sdl3.gpu.DepthStencilState{
            .enable_depth_test = true,
            .enable_depth_write = config.depth_write,
            .compare = .less_or_equal,
            .write_mask = if (config.depth_write) 0xFF else 0,
        } else .{},
        .target_info = sdl3.gpu.GraphicsPipelineTargetInfo{
            .color_target_descriptions = &.{
                sdl3.gpu.ColorTargetDescription{
                    .format = try core.device.getSwapchainTextureFormat(core.window),
                },
            },
            .depth_stencil_format = if (config.depth_test) .depth16_unorm else null,
        },
        .vertex_input_state = sdl3.gpu.VertexInputState{
            .vertex_buffer_descriptions = &.{
                sdl3.gpu.VertexBufferDescription{
                    .input_rate = .vertex,
                    .slot = 0,
                    .pitch = @sizeOf(Core.Vertex),
                },
            },
            .vertex_attributes = &.{
                sdl3.gpu.VertexAttribute{
                    .buffer_slot = 0,
                    .format = .f32x3,
                    .location = 0,
                    .offset = @offsetOf(Core.Vertex, "position"),
                },
                sdl3.gpu.VertexAttribute{
                    .buffer_slot = 0,
                    .format = .f32x2,
                    .location = 1,
                    .offset = @offsetOf(Core.Vertex, "uv"),
                },
            },
        },
    });

    return .{ .handle = handle };
}

pub fn deinit(self: Self, core: *Core) void {
    core.device.releaseGraphicsPipeline(self.handle);
}
