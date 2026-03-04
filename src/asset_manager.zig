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

/// Internal state for an asset currently residing in a Staging Buffer
/// awaiting completion of the GPU copy command.
const UploadingAsset = struct {
    name: []u8,
    fence: sdl3.gpu.Fence,
    resource: union(enum) {
        texture: Texture,
        mesh: Mesh,
    },
};

const Self = @This();

allocator: std.mem.Allocator,
core: *Core,

// --- Registries (Main Thread Only) ---
// Only assets that are fully uploaded and ready for draw calls live here.
textures: std.ArrayListUnmanaged(Texture) = .{},
texture_paths: std.StringHashMapUnmanaged(AssetHandle) = .{},
meshes: std.ArrayListUnmanaged(Mesh) = .{},
mesh_paths: std.StringHashMapUnmanaged(AssetHandle) = .{},

// --- Async State ---
uploading: std.ArrayListUnmanaged(UploadingAsset) = .{},
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

    // 2. Cleanup assets still in the middle of GPU upload
    for (self.uploading.items) |u| {
        self.allocator.free(u.name);
        self.core.device.releaseFence(u.fence);
        switch (u.resource) {
            .texture => |t| t.deinit(self.core),
            .mesh => |m| m.deinit(self.core),
        }
    }
    self.uploading.deinit(self.allocator);

    // 3. Cleanup GPU Resources in registries
    for (self.textures.items) |t| t.deinit(self.core);
    for (self.meshes.items) |m| m.deinit(self.core);
    self.textures.deinit(self.allocator);
    self.meshes.deinit(self.allocator);

    // 4. Cleanup String Table Paths
    var tex_iter = self.texture_paths.iterator();
    while (tex_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
    self.texture_paths.deinit(self.allocator);

    var mesh_iter = self.mesh_paths.iterator();
    while (mesh_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
    self.mesh_paths.deinit(self.allocator);

    // 5. Cleanup internal structures
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

pub fn update(self: *Self) !void {
    // Phase 1: Retire finished GPU uploads
    // Check if the GPU has finished processing the fences for pending assets.
    var u_idx: usize = 0;
    while (u_idx < self.uploading.items.len) {
        const u = &self.uploading.items[u_idx];
        if (self.core.device.queryFence(u.fence)) {
            const finished = self.uploading.swapRemove(u_idx);
            self.core.device.releaseFence(finished.fence);

            switch (finished.resource) {
                .texture => |tex| {
                    const handle: AssetHandle = @intCast(self.textures.items.len);
                    try self.textures.append(self.allocator, tex);
                    try self.texture_paths.put(self.allocator, finished.name, handle);
                },
                .mesh => |mesh| {
                    const handle: AssetHandle = @intCast(self.meshes.items.len);
                    try self.meshes.append(self.allocator, mesh);
                    try self.mesh_paths.put(self.allocator, finished.name, handle);
                },
            }
            // Do not increment u_idx, swapRemove moves a new element here
        } else {
            u_idx += 1;
        }
    }

    // Phase 2: Start new uploads for items that finished CPU loading.
    // We process one per frame to maintain smooth frame times.
    if (self.result_channel.tryPop()) |res| {
        var upload = try Upload.begin(self.core);
        var r = res;
        switch (r) {
            .texture => |*t| {
                const tex = try t.data.upload(self.core, upload.copy_pass);
                t.data.deinit(self.allocator);

                const fence = try upload.submitAsync();
                try self.uploading.append(self.allocator, .{
                    .name = t.name,
                    .fence = fence,
                    .resource = .{ .texture = tex },
                });
            },
            .mesh => |*m| {
                const mesh = try m.data.upload(self.core, upload.copy_pass);
                m.data.deinit(self.allocator);

                const fence = try upload.submitAsync();
                try self.uploading.append(self.allocator, .{
                    .name = m.name,
                    .fence = fence,
                    .resource = .{ .mesh = mesh },
                });
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
