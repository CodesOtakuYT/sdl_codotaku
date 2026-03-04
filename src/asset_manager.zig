const std = @import("std");
const Core = @import("core.zig");
const Texture = @import("texture.zig");
const Mesh = @import("mesh.zig");
const Upload = @import("upload.zig");
const Channel = @import("channel.zig").Channel;
const sdl3 = Core.sdl3;

pub const AssetHandle = u32;

const LoadResult = union(enum) {
    texture: struct { name: []u8, data: Texture.TextureData },
    mesh: struct { name: []u8, data: Mesh.MeshData },
};

const Self = @This();

allocator: std.mem.Allocator,
core: *Core,

// Registries - Only modified on Main Thread via update()
textures: std.ArrayListUnmanaged(Texture) = .{},
texture_paths: std.StringHashMapUnmanaged(AssetHandle) = .{},
meshes: std.ArrayListUnmanaged(Mesh) = .{},
mesh_paths: std.StringHashMapUnmanaged(AssetHandle) = .{},

// Threading - Pointer to global pool owned by the caller
pool: *std.Thread.Pool,
result_channel: *Channel(LoadResult),

pub fn init(core: *Core, pool: *std.Thread.Pool, allocator: std.mem.Allocator) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const res_buf = try allocator.alloc(LoadResult, 128);
    errdefer allocator.free(res_buf);

    self.* = .{
        .allocator = allocator,
        .core = core,
        .pool = pool,
        .result_channel = try allocator.create(Channel(LoadResult)),
    };

    self.result_channel.* = Channel(LoadResult).init(res_buf);

    return self;
}

pub fn deinit(self: *Self) void {
    // Note: We do NOT deinit self.pool. The caller is responsible for that.

    // 1. Drain any CPU results remaining in the channel
    while (self.result_channel.tryPop()) |res| {
        var mutable_res = res;
        switch (mutable_res) {
            .texture => |*t| {
                self.allocator.free(t.name);
                t.data.deinit(self.allocator);
            },
            .mesh => |*m| {
                self.allocator.free(m.name);
                m.data.deinit(self.allocator);
            },
        }
    }

    // 2. Cleanup GPU Resources
    for (self.textures.items) |t| t.deinit(self.core);
    for (self.meshes.items) |m| m.deinit(self.core);
    self.textures.deinit(self.allocator);
    self.meshes.deinit(self.allocator);

    // 3. Cleanup Path Strings
    var tex_iter = self.texture_paths.iterator();
    while (tex_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
    self.texture_paths.deinit(self.allocator);

    var mesh_iter = self.mesh_paths.iterator();
    while (mesh_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
    self.mesh_paths.deinit(self.allocator);

    // 4. Cleanup internal structures
    const res_items = self.result_channel.queue.items[0 .. self.result_channel.queue.mask + 1];
    self.allocator.free(res_items);
    self.allocator.destroy(self.result_channel);
    self.allocator.destroy(self);
}

// --- Internal Workers (Executed on Thread Pool) ---

fn doLoadPNG(self: *Self, path: []const u8) void {
    const path_z = self.allocator.dupeZ(u8, path) catch return;
    defer self.allocator.free(path_z);

    const data = Texture.loadPNGData(self.allocator, path_z) catch return;
    self.result_channel.push(.{ .texture = .{ .name = self.allocator.dupe(u8, path) catch unreachable, .data = data } }) catch return;
}

fn doLoadCubemap(self: *Self, name: []u8, paths: [6][]u8) void {
    defer self.allocator.free(name);
    var paths_z: [6][:0]const u8 = undefined;
    for (paths, 0..) |p, i| {
        paths_z[i] = self.allocator.dupeZ(u8, p) catch unreachable;
    }
    defer for (paths_z) |p| self.allocator.free(p);
    defer for (paths) |p| self.allocator.free(p);

    const data = Texture.loadCubemapData(self.allocator, paths_z) catch return;
    self.result_channel.push(.{ .texture = .{ .name = self.allocator.dupe(u8, name) catch unreachable, .data = data } }) catch return;
}

fn doLoadObj(self: *Self, name: []u8, data_raw: []u8) void {
    defer self.allocator.free(data_raw);
    defer self.allocator.free(name);
    const data = Mesh.loadObj(self.allocator, data_raw) catch return;
    self.result_channel.push(.{ .mesh = .{ .name = self.allocator.dupe(u8, name) catch unreachable, .data = data } }) catch return;
}

fn doLoadCube(self: *Self, name: []u8) void {
    defer self.allocator.free(name);
    const data = Mesh.loadCube(self.allocator) catch return;
    self.result_channel.push(.{ .mesh = .{ .name = self.allocator.dupe(u8, name) catch unreachable, .data = data } }) catch return;
}

// --- Public API ---

pub fn update(self: *Self, upload: *Upload) !void {
    while (self.result_channel.tryPop()) |res| {
        var r = res;
        switch (r) {
            .texture => |*t| {
                const tex = try t.data.upload(self.core, upload.copy_pass);
                const handle: AssetHandle = @intCast(self.textures.items.len);
                try self.textures.append(self.allocator, tex);
                try self.texture_paths.put(self.allocator, try self.allocator.dupe(u8, t.name), handle);
                t.data.deinit(self.allocator);
                self.allocator.free(t.name);
            },
            .mesh => |*m| {
                const mesh = try m.data.upload(self.core, upload.copy_pass);
                const handle: AssetHandle = @intCast(self.meshes.items.len);
                try self.meshes.append(self.allocator, mesh);
                try self.mesh_paths.put(self.allocator, try self.allocator.dupe(u8, m.name), handle);
                m.data.deinit(self.allocator);
                self.allocator.free(m.name);
            },
        }
    }
}

pub fn requestTexture(self: *Self, path: []const u8) !void {
    if (self.texture_paths.contains(path)) return;
    try self.pool.spawn(doLoadPNG, .{ self, path });
}

pub fn requestCubemap(self: *Self, name: []const u8, paths: [6][:0]const u8) !void {
    if (self.texture_paths.contains(name)) return;
    var owned_paths: [6][]u8 = undefined;
    for (paths, 0..) |p, i| owned_paths[i] = try self.allocator.dupe(u8, p);
    try self.pool.spawn(doLoadCubemap, .{ self, try self.allocator.dupe(u8, name), owned_paths });
}

pub fn requestMeshObj(self: *Self, name: []const u8, data: []const u8) !void {
    if (self.mesh_paths.contains(name)) return;
    try self.pool.spawn(doLoadObj, .{ self, try self.allocator.dupe(u8, name), try self.allocator.dupe(u8, data) });
}

pub fn requestMeshCube(self: *Self, name: []const u8) !void {
    if (self.mesh_paths.contains(name)) return;
    try self.pool.spawn(doLoadCube, .{ self, try self.allocator.dupe(u8, name) });
}

pub fn getTexture(self: *Self, name: []const u8) ?Texture {
    const handle = self.texture_paths.get(name) orelse return null;
    return self.textures.items[handle];
}

pub fn getMesh(self: *Self, name: []const u8) ?Mesh {
    const handle = self.mesh_paths.get(name) orelse return null;
    return self.meshes.items[handle];
}
