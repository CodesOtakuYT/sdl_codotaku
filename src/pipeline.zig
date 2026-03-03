const std = @import("std");
const Core = @import("core.zig");
const sdl3 = Core.sdl3;
const Shader = @import("shader.zig");
const Vertex = @import("vertex.zig").Vertex;

const Self = @This();

handle: sdl3.gpu.GraphicsPipeline,

pub const Config = struct {
    vert_spec: Shader.Config,
    frag_spec: Shader.Config,
    depth_test: bool = false,
    depth_write: bool = true,
    /// Allows overriding the primitive type (e.g., .triangle_strip)
    primitive_type: sdl3.gpu.PrimitiveType = .triangle_list,
};

/// Initializes shaders and creates the graphics pipeline in one go
pub fn init(core: *Core, config: Config) !Self {
    // 1. Initialize Shaders internally
    const v_shader = try Shader.init(core, config.vert_spec);
    defer v_shader.deinit(core);

    const f_shader = try Shader.init(core, config.frag_spec);
    defer f_shader.deinit(core);

    // 2. Define Vertex Input State from our Vertex abstraction
    const vertex_attrs = Vertex.getAttributes();
    const vertex_buffers = [_]sdl3.gpu.VertexBufferDescription{Vertex.getBufferDescription()};

    // 3. Create the actual GPU Pipeline
    const handle = try core.device.createGraphicsPipeline(.{
        .vertex_shader = v_shader.handle,
        .fragment_shader = f_shader.handle,
        .primitive_type = config.primitive_type,

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
                    // You can add blending config here later
                },
            },
            .depth_stencil_format = if (config.depth_test) .depth16_unorm else null,
        },

        .vertex_input_state = sdl3.gpu.VertexInputState{
            .vertex_buffer_descriptions = &vertex_buffers,
            .vertex_attributes = &vertex_attrs,
        },
    });

    return .{ .handle = handle };
}

pub fn deinit(self: Self, core: *Core) void {
    core.device.releaseGraphicsPipeline(self.handle);
}

pub fn bind(self: Self, render_pass: sdl3.gpu.RenderPass) void {
    render_pass.bindGraphicsPipeline(self.handle);
}
