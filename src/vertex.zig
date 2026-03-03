const std = @import("std");
const za = @import("zalgebra");
const sdl3 = @import("sdl3");

pub const Vertex = struct {
    position: za.Vec3,
    uv: za.Vec2,

    pub fn getAttributes() [2]sdl3.gpu.VertexAttribute {
        return .{
            .{
                .buffer_slot = 0,
                .format = .f32x3,
                .location = 0,
                .offset = @offsetOf(Vertex, "position"),
            },
            .{
                .buffer_slot = 0,
                .format = .f32x2,
                .location = 1,
                .offset = @offsetOf(Vertex, "uv"),
            },
        };
    }

    pub fn getBufferDescription() sdl3.gpu.VertexBufferDescription {
        return .{
            .input_rate = .vertex,
            .slot = 0,
            .pitch = @sizeOf(Vertex),
        };
    }
};
