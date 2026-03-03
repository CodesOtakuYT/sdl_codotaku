const std = @import("std");
const Core = @import("core.zig");
const sdl3 = Core.sdl3;

const Self = @This();

handle: sdl3.gpu.Buffer,
size: u32,

/// Create a raw GPU buffer
pub fn init(core: *Core, size: u32, usage: sdl3.gpu.BufferUsageFlags) !Self {
    const handle = try core.device.createBuffer(.{ .size = size, .usage = usage });
    return .{
        .handle = handle,
        .size = size,
    };
}

pub fn deinit(self: Self, core: *Core) void {
    core.device.releaseBuffer(self.handle);
}

/// Helper for single-shot buffer uploads
pub const UploadRequest = struct {
    data: []const u8,
    usage: sdl3.gpu.BufferUsageFlags,
};

/// Uploads multiple data slices to multiple new GPU buffers in one batch
pub fn uploadBatch(core: *Core, requests: []const UploadRequest) ![]Self {
    var total_size: u32 = 0;
    const offsets = try core.allocator.alloc(u32, requests.len);
    defer core.allocator.free(offsets);

    for (requests, 0..) |req, i| {
        offsets[i] = total_size;
        total_size += @intCast(req.data.len);
    }

    const buffers = try core.allocator.alloc(Self, requests.len);
    errdefer core.allocator.free(buffers);

    for (requests, 0..) |req, i| {
        buffers[i] = try Self.init(core, @intCast(req.data.len), req.usage);
    }

    const transfer_buffer = try core.device.createTransferBuffer(.{
        .size = total_size,
        .usage = .upload,
    });
    defer core.device.releaseTransferBuffer(transfer_buffer);

    const mapped_data = try core.device.mapTransferBuffer(transfer_buffer, false);
    for (requests, 0..) |req, i| {
        @memcpy(mapped_data[offsets[i]..][0..req.data.len], req.data);
    }
    core.device.unmapTransferBuffer(transfer_buffer);

    const command_buffer = try core.device.acquireCommandBuffer();
    {
        const copy_pass = command_buffer.beginCopyPass();
        defer copy_pass.end();

        for (requests, 0..) |req, i| {
            copy_pass.uploadToBuffer(.{
                .transfer_buffer = transfer_buffer,
                .offset = offsets[i],
            }, .{
                .buffer = buffers[i].handle,
                .offset = 0,
                .size = @intCast(req.data.len),
            }, false);
        }
    }
    try command_buffer.submit();

    return buffers;
}

/// Convenience wrapper to turn any slice into an UploadRequest
pub fn asUpload(comptime T: type, data: []const T, usage: sdl3.gpu.BufferUsageFlags) UploadRequest {
    return .{
        .data = std.mem.sliceAsBytes(data),
        .usage = usage,
    };
}
