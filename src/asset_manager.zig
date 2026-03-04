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

// Registries
textures: std.ArrayListUnmanaged(Texture),
texture_paths: std.StringHashMapUnmanaged(AssetHandle),

meshes: std.ArrayListUnmanaged(Mesh),
mesh_paths: std.StringHashMapUnmanaged(AssetHandle),

pub fn init(core: *Core, allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .core = core,
        .textures = .empty,
        .texture_paths = .empty,
        .meshes = .empty,
        .mesh_paths = .empty,
    };
}

pub fn deinit(self: *Self) void {
    for (self.textures.items) |t| t.deinit(self.core);
    for (self.meshes.items) |m| m.deinit(self.core);

    self.textures.deinit(self.allocator);
    self.meshes.deinit(self.allocator);
    self.texture_paths.deinit(self.allocator);
    self.mesh_paths.deinit(self.allocator);
}

pub fn loadTexture(self: *Self, upload: *Upload, path: [:0]const u8) !AssetHandle {
    if (self.texture_paths.get(path)) |handle| return handle;

    const tex = try Texture.loadPNG(self.core, upload.copy_pass, path);
    const handle: AssetHandle = @intCast(self.textures.items.len);

    try self.textures.append(self.allocator, tex);
    try self.texture_paths.put(self.allocator, try self.allocator.dupe(u8, path), handle);

    return handle;
}

pub fn loadCubemap(self: *Self, upload: *Upload, name: []const u8, paths: [6][:0]const u8) !AssetHandle {
    if (self.texture_paths.get(name)) |handle| return handle;

    const tex = try Texture.loadCubemap(self.core, upload.copy_pass, paths);
    const handle: AssetHandle = @intCast(self.textures.items.len);

    try self.textures.append(self.allocator, tex);
    try self.texture_paths.put(self.allocator, try self.allocator.dupe(u8, name), handle);

    return handle;
}

pub fn loadMeshObj(self: *Self, upload: *Upload, name: []const u8, data: []const u8) !AssetHandle {
    if (self.mesh_paths.get(name)) |handle| return handle;

    const mesh = try Mesh.initObj(self.core, upload.copy_pass, data);
    const handle: AssetHandle = @intCast(self.meshes.items.len);

    try self.meshes.append(self.allocator, mesh);
    try self.mesh_paths.put(self.allocator, try self.allocator.dupe(u8, name), handle);

    return handle;
}

pub fn loadMeshCube(self: *Self, upload: *Upload, name: []const u8) !AssetHandle {
    if (self.mesh_paths.get(name)) |handle| return handle;

    const mesh = try Mesh.initCube(self.core, upload.copy_pass);
    const handle: AssetHandle = @intCast(self.meshes.items.len);

    try self.meshes.append(self.allocator, mesh);
    try self.mesh_paths.put(self.allocator, try self.allocator.dupe(u8, name), handle);

    return handle;
}

pub fn getTexture(self: Self, handle: AssetHandle) Texture {
    return self.textures.items[handle];
}

pub fn getMesh(self: Self, handle: AssetHandle) Mesh {
    return self.meshes.items[handle];
}
