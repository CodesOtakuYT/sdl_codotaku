const std = @import("std");
const Core = @import("core.zig");
const za = Core.za;
const sdl3 = Core.sdl3;

const Self = @This();

vertex_buffer: sdl3.gpu.Buffer,
index_buffer: sdl3.gpu.Buffer,
index_count: u32,

pub fn initCube(core: *Core) !Self {
    // We define 4 vertices per face to allow for unique UV mapping per face.
    const vertices = [_]Core.Vertex{
        // Front Face (Z+)
        .{ .position = za.Vec3.new(-0.5, 0.5, 0.5), .uv = za.Vec2.new(0, 0) }, // 0
        .{ .position = za.Vec3.new(0.5, 0.5, 0.5), .uv = za.Vec2.new(1, 0) }, // 1
        .{ .position = za.Vec3.new(0.5, -0.5, 0.5), .uv = za.Vec2.new(1, 1) }, // 2
        .{ .position = za.Vec3.new(-0.5, -0.5, 0.5), .uv = za.Vec2.new(0, 1) }, // 3

        // Back Face (Z-)
        .{ .position = za.Vec3.new(0.5, 0.5, -0.5), .uv = za.Vec2.new(0, 0) }, // 4
        .{ .position = za.Vec3.new(-0.5, 0.5, -0.5), .uv = za.Vec2.new(1, 0) }, // 5
        .{ .position = za.Vec3.new(-0.5, -0.5, -0.5), .uv = za.Vec2.new(1, 1) }, // 6
        .{ .position = za.Vec3.new(0.5, -0.5, -0.5), .uv = za.Vec2.new(0, 1) }, // 7

        // Left Face (X-)
        .{ .position = za.Vec3.new(-0.5, 0.5, -0.5), .uv = za.Vec2.new(0, 0) }, // 8
        .{ .position = za.Vec3.new(-0.5, 0.5, 0.5), .uv = za.Vec2.new(1, 0) }, // 9
        .{ .position = za.Vec3.new(-0.5, -0.5, 0.5), .uv = za.Vec2.new(1, 1) }, // 10
        .{ .position = za.Vec3.new(-0.5, -0.5, -0.5), .uv = za.Vec2.new(0, 1) }, // 11

        // Right Face (X+)
        .{ .position = za.Vec3.new(0.5, 0.5, 0.5), .uv = za.Vec2.new(0, 0) }, // 12
        .{ .position = za.Vec3.new(0.5, 0.5, -0.5), .uv = za.Vec2.new(1, 0) }, // 13
        .{ .position = za.Vec3.new(0.5, -0.5, -0.5), .uv = za.Vec2.new(1, 1) }, // 14
        .{ .position = za.Vec3.new(0.5, -0.5, 0.5), .uv = za.Vec2.new(0, 1) }, // 15

        // Top Face (Y+)
        .{ .position = za.Vec3.new(-0.5, 0.5, -0.5), .uv = za.Vec2.new(0, 0) }, // 16
        .{ .position = za.Vec3.new(0.5, 0.5, -0.5), .uv = za.Vec2.new(1, 0) }, // 17
        .{ .position = za.Vec3.new(0.5, 0.5, 0.5), .uv = za.Vec2.new(1, 1) }, // 18
        .{ .position = za.Vec3.new(-0.5, 0.5, 0.5), .uv = za.Vec2.new(0, 1) }, // 19

        // Bottom Face (Y-)
        .{ .position = za.Vec3.new(-0.5, -0.5, 0.5), .uv = za.Vec2.new(0, 0) }, // 20
        .{ .position = za.Vec3.new(0.5, -0.5, 0.5), .uv = za.Vec2.new(1, 0) }, // 21
        .{ .position = za.Vec3.new(0.5, -0.5, -0.5), .uv = za.Vec2.new(1, 1) }, // 22
        .{ .position = za.Vec3.new(-0.5, -0.5, -0.5), .uv = za.Vec2.new(0, 1) }, // 23
    };

    const indices = [_]u32{
        0, 1, 2, 2, 3, 0, // Front
        4, 5, 6, 6, 7, 4, // Back
        8, 9, 10, 10, 11, 8, // Left
        12, 13, 14, 14, 15, 12, // Right
        16, 17, 18, 18, 19, 16, // Top
        20, 21, 22, 22, 23, 20, // Bottom
    };

    const buffers = try core.uploadBuffers(&.{
        Core.makeUpload(Core.Vertex, &vertices, .{ .vertex = true }),
        Core.makeUpload(u32, &indices, .{ .index = true }),
    });
    defer core.allocator.free(buffers);

    return .{
        .vertex_buffer = buffers[0],
        .index_buffer = buffers[1],
        .index_count = @intCast(indices.len),
    };
}

pub fn deinit(self: Self, core: *Core) void {
    core.device.releaseBuffer(self.vertex_buffer);
    core.device.releaseBuffer(self.index_buffer);
}

pub fn draw(self: Self, renderpass: sdl3.gpu.RenderPass) void {
    renderpass.bindIndexBuffer(.{ .buffer = self.index_buffer, .offset = 0 }, .indices_32bit);
    renderpass.bindVertexBuffers(0, &.{.{
        .buffer = self.vertex_buffer,
        .offset = 0,
    }});
    renderpass.drawIndexedPrimitives(self.index_count, 1, 0, 0, 0);
}
