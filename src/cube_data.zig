const Vertex = @import("vertex.zig").Vertex;
const za = @import("zalgebra");

pub const vertices = [_]Vertex{

    // Front Face (Z+)

    .{ .position = za.Vec3.new(-0.5, 0.5, 0.5), .uv = za.Vec2.new(0, 0) },

    .{ .position = za.Vec3.new(0.5, 0.5, 0.5), .uv = za.Vec2.new(1, 0) },

    .{ .position = za.Vec3.new(0.5, -0.5, 0.5), .uv = za.Vec2.new(1, 1) },

    .{ .position = za.Vec3.new(-0.5, -0.5, 0.5), .uv = za.Vec2.new(0, 1) },

    // ... (remaining faces same as before)

    // Back Face (Z-)

    .{ .position = za.Vec3.new(0.5, 0.5, -0.5), .uv = za.Vec2.new(0, 0) },

    .{ .position = za.Vec3.new(-0.5, 0.5, -0.5), .uv = za.Vec2.new(1, 0) },

    .{ .position = za.Vec3.new(-0.5, -0.5, -0.5), .uv = za.Vec2.new(1, 1) },

    .{ .position = za.Vec3.new(0.5, -0.5, -0.5), .uv = za.Vec2.new(0, 1) },

    // Left Face (X-)

    .{ .position = za.Vec3.new(-0.5, 0.5, -0.5), .uv = za.Vec2.new(0, 0) },

    .{ .position = za.Vec3.new(-0.5, 0.5, 0.5), .uv = za.Vec2.new(1, 0) },

    .{ .position = za.Vec3.new(-0.5, -0.5, 0.5), .uv = za.Vec2.new(1, 1) },

    .{ .position = za.Vec3.new(-0.5, -0.5, -0.5), .uv = za.Vec2.new(0, 1) },

    // Right Face (X+)

    .{ .position = za.Vec3.new(0.5, 0.5, 0.5), .uv = za.Vec2.new(0, 0) },

    .{ .position = za.Vec3.new(0.5, 0.5, -0.5), .uv = za.Vec2.new(1, 0) },

    .{ .position = za.Vec3.new(0.5, -0.5, -0.5), .uv = za.Vec2.new(1, 1) },

    .{ .position = za.Vec3.new(0.5, -0.5, 0.5), .uv = za.Vec2.new(0, 1) },

    // Top Face (Y+)

    .{ .position = za.Vec3.new(-0.5, 0.5, -0.5), .uv = za.Vec2.new(0, 0) },

    .{ .position = za.Vec3.new(0.5, 0.5, -0.5), .uv = za.Vec2.new(1, 0) },

    .{ .position = za.Vec3.new(0.5, 0.5, 0.5), .uv = za.Vec2.new(1, 1) },

    .{ .position = za.Vec3.new(-0.5, 0.5, 0.5), .uv = za.Vec2.new(0, 1) },

    // Bottom Face (Y-)

    .{ .position = za.Vec3.new(-0.5, -0.5, 0.5), .uv = za.Vec2.new(0, 0) },

    .{ .position = za.Vec3.new(0.5, -0.5, 0.5), .uv = za.Vec2.new(1, 0) },

    .{ .position = za.Vec3.new(0.5, -0.5, -0.5), .uv = za.Vec2.new(1, 1) },

    .{ .position = za.Vec3.new(-0.5, -0.5, -0.5), .uv = za.Vec2.new(0, 1) },
};

pub const indices = [_]u32{
    0, 1, 2, 2, 3, 0, // Front
    4, 5, 6, 6, 7, 4, // Back
    8, 9, 10, 10, 11, 8, // Left
    12, 13, 14, 14, 15, 12, // Right
    16, 17, 18, 18, 19, 16, // Top
    20, 21, 22, 22, 23, 20, // Bottom
};
