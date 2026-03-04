const std = @import("std");
const Core = @import("core.zig");
const Texture = @import("texture.zig");
const Mesh = @import("mesh.zig");
const Upload = @import("upload.zig");
const sdl3 = Core.sdl3;

pub const AssetHandle = u32;

const Self = @This();

allocator: std.mem.Allocator,
core: *Core,

// Registries - Using Unmanaged as per current Zig std style
textures: std.ArrayListUnmanaged(Texture) = .{},
texture_paths: std.StringHashMapUnmanaged(AssetHandle) = .{},

meshes: std.ArrayListUnmanaged(Mesh) = .{},
mesh_paths: std.StringHashMapUnmanaged(AssetHandle) = .{},

pub fn init(core: *Core, allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .core = core,
    };
}

pub fn deinit(self: *Self) void {
    for (self.textures.items) |t| t.deinit(self.core);
    for (self.meshes.items) |m| m.deinit(self.core);

    self.textures.deinit(self.allocator);
    self.meshes.deinit(self.allocator);

    // Clean up the duplicated string keys in the hash maps
    var tex_iter = self.texture_paths.iterator();
    while (tex_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
    self.texture_paths.deinit(self.allocator);

    var mesh_iter = self.mesh_paths.iterator();
    while (mesh_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
    self.mesh_paths.deinit(self.allocator);
}

// --- Texture Loading ---

pub fn loadTexture(self: *Self, upload: *Upload, path: [:0]const u8) !AssetHandle {
    if (self.texture_paths.get(path)) |handle| return handle;

    // 1. Load CPU Data
    var data = try Texture.loadPNGData(self.allocator, path);
    defer data.deinit(self.allocator);

    // 2. Upload to GPU
    const tex = try data.upload(self.core, upload.copy_pass);

    // 3. Cache
    const handle: AssetHandle = @intCast(self.textures.items.len);
    try self.textures.append(self.allocator, tex);
    try self.texture_paths.put(self.allocator, try self.allocator.dupe(u8, path), handle);

    return handle;
}

pub fn loadCubemap(self: *Self, upload: *Upload, name: []const u8, paths: [6][:0]const u8) !AssetHandle {
    if (self.texture_paths.get(name)) |handle| return handle;

    var data = try Texture.loadCubemapData(self.allocator, paths);
    defer data.deinit(self.allocator);

    const tex = try data.upload(self.core, upload.copy_pass);

    const handle: AssetHandle = @intCast(self.textures.items.len);
    try self.textures.append(self.allocator, tex);
    try self.texture_paths.put(self.allocator, try self.allocator.dupe(u8, name), handle);

    return handle;
}

// --- Mesh Loading ---

pub fn loadMeshObj(self: *Self, upload: *Upload, name: []const u8, data_raw: []const u8) !AssetHandle {
    if (self.mesh_paths.get(name)) |handle| return handle;

    // 1. Load CPU Data
    var data = try Mesh.loadObj(self.allocator, data_raw);
    defer data.deinit(self.allocator);

    // 2. Upload to GPU
    const mesh = try data.upload(self.core, upload.copy_pass);

    // 3. Cache
    const handle: AssetHandle = @intCast(self.meshes.items.len);
    try self.meshes.append(self.allocator, mesh);
    try self.mesh_paths.put(self.allocator, try self.allocator.dupe(u8, name), handle);

    return handle;
}

pub fn loadMeshCube(self: *Self, upload: *Upload, name: []const u8) !AssetHandle {
    if (self.mesh_paths.get(name)) |handle| return handle;

    var data = try Mesh.loadCube(self.allocator);
    defer data.deinit(self.allocator);

    const mesh = try data.upload(self.core, upload.copy_pass);

    const handle: AssetHandle = @intCast(self.meshes.items.len);
    try self.meshes.append(self.allocator, mesh);
    try self.mesh_paths.put(self.allocator, try self.allocator.dupe(u8, name), handle);

    return handle;
}

// --- Getters ---

pub fn getTexture(self: Self, handle: AssetHandle) Texture {
    return self.textures.items[handle];
}

pub fn getMesh(self: Self, handle: AssetHandle) Mesh {
    return self.meshes.items[handle];
}
