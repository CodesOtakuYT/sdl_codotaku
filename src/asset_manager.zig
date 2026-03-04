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

const LoadRequest = union(enum) {
    png: []const u8,
    cubemap: struct { name: []u8, paths: [6][]u8 },
    obj: struct { name: []u8, data: []u8 },
    cube: []u8,
};

const Self = @This();

allocator: std.mem.Allocator,
core: *Core,

textures: std.ArrayListUnmanaged(Texture) = .{},
texture_paths: std.StringHashMapUnmanaged(AssetHandle) = .{},

meshes: std.ArrayListUnmanaged(Mesh) = .{},
mesh_paths: std.StringHashMapUnmanaged(AssetHandle) = .{},

request_channel: *Channel(LoadRequest),
result_channel: *Channel(LoadResult),
thread: std.Thread,

pub fn init(core: *Core, allocator: std.mem.Allocator) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const req_buf = try allocator.alloc(LoadRequest, 64);
    errdefer allocator.free(req_buf);

    const res_buf = try allocator.alloc(LoadResult, 64);
    errdefer allocator.free(res_buf);

    self.* = .{
        .allocator = allocator,
        .core = core,
        .request_channel = try allocator.create(Channel(LoadRequest)),
        .result_channel = try allocator.create(Channel(LoadResult)),
        .thread = undefined,
    };

    self.request_channel.* = Channel(LoadRequest).init(req_buf);
    self.result_channel.* = Channel(LoadResult).init(res_buf);

    self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});

    return self;
}

pub fn deinit(self: *Self) void {
    self.request_channel.close();
    self.thread.join();

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

    for (self.textures.items) |t| t.deinit(self.core);
    for (self.meshes.items) |m| m.deinit(self.core);

    self.textures.deinit(self.allocator);
    self.meshes.deinit(self.allocator);

    var tex_iter = self.texture_paths.iterator();
    while (tex_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
    self.texture_paths.deinit(self.allocator);

    var mesh_iter = self.mesh_paths.iterator();
    while (mesh_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
    self.mesh_paths.deinit(self.allocator);

    const req_items = self.request_channel.queue.items[0 .. self.request_channel.queue.mask + 1];
    const res_items = self.result_channel.queue.items[0 .. self.result_channel.queue.mask + 1];

    self.allocator.free(req_items);
    self.allocator.free(res_items);

    self.allocator.destroy(self.request_channel);
    self.allocator.destroy(self.result_channel);
    self.allocator.destroy(self);
}

fn workerLoop(self: *Self) void {
    while (self.request_channel.pop()) |req| {
        switch (req) {
            .png => |path| {
                const path_z = self.allocator.dupeZ(u8, path) catch continue;
                defer self.allocator.free(path_z);
                const data = Texture.loadPNGData(self.allocator, path_z) catch continue;
                self.result_channel.push(.{ .texture = .{ .name = self.allocator.dupe(u8, path) catch unreachable, .data = data } }) catch return;
            },
            .cubemap => |cm| {
                // Ensure all 6 paths are null-terminated for the loader
                var paths_z: [6][:0]const u8 = undefined;
                for (cm.paths, 0..) |p, i| {
                    paths_z[i] = self.allocator.dupeZ(u8, p) catch unreachable;
                }
                defer for (paths_z) |p| self.allocator.free(p);
                defer for (cm.paths) |p| self.allocator.free(p);

                const data = Texture.loadCubemapData(self.allocator, paths_z) catch {
                    self.allocator.free(cm.name);
                    continue;
                };
                self.result_channel.push(.{ .texture = .{ .name = cm.name, .data = data } }) catch return;
            },
            .obj => |obj_req| {
                const data = Mesh.loadObj(self.allocator, obj_req.data) catch {
                    self.allocator.free(obj_req.name);
                    self.allocator.free(obj_req.data);
                    continue;
                };
                self.result_channel.push(.{ .mesh = .{ .name = obj_req.name, .data = data } }) catch return;
                self.allocator.free(obj_req.data);
            },
            .cube => |name| {
                const data = Mesh.loadCube(self.allocator) catch {
                    self.allocator.free(name);
                    continue;
                };
                self.result_channel.push(.{ .mesh = .{ .name = name, .data = data } }) catch return;
            },
        }
    }
}

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
    try self.request_channel.push(.{ .png = path });
}

pub fn requestCubemap(self: *Self, name: []const u8, paths: [6][:0]const u8) !void {
    if (self.texture_paths.contains(name)) return;
    var owned_paths: [6][]u8 = undefined;
    for (paths, 0..) |p, i| owned_paths[i] = try self.allocator.dupe(u8, p);

    try self.request_channel.push(.{ .cubemap = .{ .name = try self.allocator.dupe(u8, name), .paths = owned_paths } });
}

pub fn requestMeshObj(self: *Self, name: []const u8, data: []const u8) !void {
    if (self.mesh_paths.contains(name)) return;
    try self.request_channel.push(.{ .obj = .{ .name = try self.allocator.dupe(u8, name), .data = try self.allocator.dupe(u8, data) } });
}

pub fn requestMeshCube(self: *Self, name: []const u8) !void {
    if (self.mesh_paths.contains(name)) return;
    try self.request_channel.push(.{ .cube = try self.allocator.dupe(u8, name) });
}

pub fn getTexture(self: *Self, name: []const u8) ?Texture {
    const handle = self.texture_paths.get(name) orelse return null;
    return self.textures.items[handle];
}

pub fn getMesh(self: *Self, name: []const u8) ?Mesh {
    const handle = self.mesh_paths.get(name) orelse return null;
    return self.meshes.items[handle];
}
