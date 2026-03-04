const std = @import("std");
const Core = @import("core.zig");
const za = Core.za;
const sdl3 = Core.sdl3;
const obj = @import("obj");
const Buffer = @import("buffer.zig");
const Vertex = @import("vertex.zig").Vertex;

// External data for the primitive cube
const cube_data = @import("cube_data.zig");

const Mesh = @This();

// --- GPU Handles ---
vertex_buffer: Buffer,
index_buffer: Buffer,
index_count: u32,

/// Intermediate CPU-side storage for mesh data.
/// This allows parsing/generation to happen independently of the GPU context.
pub const MeshData = struct {
    vertices: std.ArrayListUnmanaged(Vertex) = .{},
    indices: std.ArrayListUnmanaged(u32) = .{},

    pub fn deinit(self: *MeshData, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.indices.deinit(allocator);
    }

    /// Takes the CPU data and creates the GPU buffers.
    pub fn upload(self: MeshData, core: *Core, copy_pass: sdl3.gpu.CopyPass) !Mesh {
        const v_buf = try Buffer.createWithData(
            core,
            copy_pass,
            std.mem.sliceAsBytes(self.vertices.items),
            .{ .vertex = true },
        );

        const i_buf = try Buffer.createWithData(
            core,
            copy_pass,
            std.mem.sliceAsBytes(self.indices.items),
            .{ .index = true },
        );

        return .{
            .vertex_buffer = v_buf,
            .index_buffer = i_buf,
            .index_count = @intCast(self.indices.items.len),
        };
    }
};

// --- CPU Loading Logic ---

/// Parses raw OBJ text into MeshData.
/// No GPU device or command buffer required here.
pub fn loadObj(allocator: std.mem.Allocator, data: []const u8) !MeshData {
    var model = try obj.parseObj(allocator, data);
    defer model.deinit(allocator);

    var unique_vertices = std.AutoHashMap(obj.Mesh.Index, u32).init(allocator);
    defer unique_vertices.deinit();

    var out_vertices: std.ArrayListUnmanaged(Vertex) = .{};
    errdefer out_vertices.deinit(allocator);
    var out_indices: std.ArrayListUnmanaged(u32) = .{};
    errdefer out_indices.deinit(allocator);

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
                        try out_vertices.append(allocator, .{ .position = pos, .uv = uv });
                    }
                    try out_indices.append(allocator, result.value_ptr.*);
                }
            }
            face_offset += v_count;
        }
    }

    return MeshData{ .vertices = out_vertices, .indices = out_indices };
}

/// Generates a cube MeshData using data from an external file.
pub fn loadCube(allocator: std.mem.Allocator) !MeshData {
    var out_vertices: std.ArrayListUnmanaged(Vertex) = .{};
    errdefer out_vertices.deinit(allocator);
    var out_indices: std.ArrayListUnmanaged(u32) = .{};
    errdefer out_indices.deinit(allocator);

    try out_vertices.appendSlice(allocator, &cube_data.vertices);
    try out_indices.appendSlice(allocator, &cube_data.indices);

    return MeshData{ .vertices = out_vertices, .indices = out_indices };
}

// --- GPU Runtime Logic ---

pub fn deinit(self: Mesh, core: *Core) void {
    self.vertex_buffer.deinit(core);
    self.index_buffer.deinit(core);
}

pub fn draw(self: Mesh, renderpass: sdl3.gpu.RenderPass) void {
    renderpass.bindIndexBuffer(.{ .buffer = self.index_buffer.handle, .offset = 0 }, .indices_32bit);
    renderpass.bindVertexBuffers(0, &.{.{
        .buffer = self.vertex_buffer.handle,
        .offset = 0,
    }});
    renderpass.drawIndexedPrimitives(self.index_count, 1, 0, 0, 0);
}
