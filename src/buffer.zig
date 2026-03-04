const std = @import("std");
const Core = @import("core.zig");
const sdl3 = Core.sdl3;
const StagingBelt = @import("staging_belt.zig");

const Self = @This();

handle: sdl3.gpu.Buffer,
size: u32,

/// Create a destination GPU buffer
pub fn init(core: *Core, size: u32, usage: sdl3.gpu.BufferUsageFlags) !Self {
    const handle = try core.device.createBuffer(.{ .size = size, .usage = usage });
    return .{ .handle = handle, .size = size };
}

pub fn deinit(self: Self, core: *Core) void {
    core.device.releaseBuffer(self.handle);
}

/// Uploads data to a NEW buffer using the Staging Belt.
/// This replaces the old complex batchUpload.
pub fn createWithData(core: *Core, copy_pass: sdl3.gpu.CopyPass, data: []const u8, usage: sdl3.gpu.BufferUsageFlags) !Self {
    const self = try Self.init(core, @intCast(data.len), usage);

    // Request a slice from the belt
    const allocation = try core.staging_belt.allocateSpace(@intCast(data.len), StagingBelt.COPY_BUFFER_ALIGNMENT);

    // Map, Copy, Unmap
    const mapped = try core.device.mapTransferBuffer(allocation.chunk.buffer, false);
    @memcpy(mapped[allocation.offset..][0..data.len], data);
    core.device.unmapTransferBuffer(allocation.chunk.buffer);

    // Record the GPU copy command
    copy_pass.uploadToBuffer(.{
        .transfer_buffer = allocation.chunk.buffer,
        .offset = allocation.offset,
    }, .{
        .buffer = self.handle,
        .offset = 0,
        .size = @intCast(data.len),
    }, false);

    return self;
}
