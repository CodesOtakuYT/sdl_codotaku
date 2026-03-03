const std = @import("std");
const Core = @import("core.zig");
const za = Core.za;
const sdl3 = Core.sdl3;
const obj = @import("obj");
const Buffer = @import("buffer.zig"); // Import our new abstraction
const Vertex = Core.Vertex;

const Self = @This();

vertex_buffer: Buffer,
index_buffer: Buffer,
index_count: u32,

pub fn init(core: *Core, vertices: []Vertex, indices: []u32) !Self {
    // Use the new batch upload API from buffer.zig
    const buffers = try Buffer.uploadBatch(core, &.{
        Buffer.asUpload(Vertex, vertices, .{ .vertex = true }),
        Buffer.asUpload(u32, indices, .{ .index = true }),
    });
    // We can still free the slice returned by uploadBatch
    defer core.allocator.free(buffers);

    return .{
        .vertex_buffer = buffers[0],
        .index_buffer = buffers[1],
        .index_count = @intCast(indices.len),
    };
}

pub fn initCube(core: *Core) !Self {
    var vertices = [_]Core.Vertex{
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

    var indices = [_]u32{
        0, 1, 2, 2, 3, 0, // Front
        4, 5, 6, 6, 7, 4, // Back
        8, 9, 10, 10, 11, 8, // Left
        12, 13, 14, 14, 15, 12, // Right
        16, 17, 18, 18, 19, 16, // Top
        20, 21, 22, 22, 23, 20, // Bottom
    };

    return .init(core, &vertices, &indices);
}

pub fn initObj(core: *Core, data: []const u8) !Self {
    // ... (OBJ parsing logic remains identical)
    var model = try obj.parseObj(core.allocator, data);
    defer model.deinit(core.allocator);

    var unique_vertices = std.AutoHashMap(obj.Mesh.Index, u32).init(core.allocator);
    defer unique_vertices.deinit();

    var out_vertices = std.ArrayList(Vertex).empty;
    defer out_vertices.deinit(core.allocator);
    var out_indices = std.ArrayList(u32).empty;
    defer out_indices.deinit(core.allocator);

    for (model.meshes) |m| {
        var face_offset: usize = 0;
        for (m.num_vertices) |v_count| {
            for (0..v_count - 2) |i| {
                const corner_indices = [_]usize{ 0, i + 1, i + 2 };
                for (corner_indices) |idx_offset| {
                    const idx = m.indices[face_offset + idx_offset];
                    const result = try unique_vertices.getOrPut(idx);
                    if (!result.found_existing) {
                        const v_base = idx.vertex.? * 3;
                        const pos = za.Vec3.new(
                            model.vertices[v_base],
                            model.vertices[v_base + 1],
                            model.vertices[v_base + 2],
                        );
                        var uv = za.Vec2.new(0.0, 0.0);
                        if (idx.tex_coord) |t_idx| {
                            const t_base = t_idx * 2;
                            uv = za.Vec2.new(model.tex_coords[t_base], 1.0 - model.tex_coords[t_base + 1]);
                        }
                        result.value_ptr.* = @intCast(out_vertices.items.len);
                        try out_vertices.append(core.allocator, .{ .position = pos, .uv = uv });
                    }
                    try out_indices.append(core.allocator, result.value_ptr.*);
                }
            }
            face_offset += v_count;
        }
    }

    return .init(core, out_vertices.items, out_indices.items);
}

pub fn deinit(self: Self, core: *Core) void {
    // Explicitly using the Buffer's deinit logic
    self.vertex_buffer.deinit(core);
    self.index_buffer.deinit(core);
}

pub fn draw(self: Self, renderpass: sdl3.gpu.RenderPass) void {
    // Reference the .handle inside our Buffer structs
    renderpass.bindIndexBuffer(.{ .buffer = self.index_buffer.handle, .offset = 0 }, .indices_32bit);
    renderpass.bindVertexBuffers(0, &.{.{
        .buffer = self.vertex_buffer.handle,
        .offset = 0,
    }});
    renderpass.drawIndexedPrimitives(self.index_count, 1, 0, 0, 0);
}
