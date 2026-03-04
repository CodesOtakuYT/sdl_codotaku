const std = @import("std");
const Core = @import("core.zig");
const sdl3 = Core.sdl3;

const Self = @This();

pub const COPY_BUFFER_ALIGNMENT = 4;

pub const Chunk = struct {
    buffer: sdl3.gpu.TransferBuffer,
    size: u32,
    offset: u32,
    fence: ?sdl3.gpu.Fence = null,

    fn canAllocate(self: Chunk, size: u32, alignment: u32) bool {
        const alloc_start = std.mem.alignForward(u32, self.offset, alignment);
        return (alloc_start + size) <= self.size;
    }

    fn allocate(self: *Chunk, size: u32, alignment: u32) u32 {
        const alloc_start = std.mem.alignForward(u32, self.offset, alignment);
        self.offset = alloc_start + size;
        return alloc_start;
    }
};

core: *Core,
chunk_size: u32,
active_chunks: std.ArrayList(Chunk) = .empty,
closed_chunks: std.ArrayList(Chunk) = .empty,
free_chunks: std.ArrayList(Chunk) = .empty,

pub fn init(core: *Core, chunk_size: u32) Self {
    return .{
        .core = core,
        .chunk_size = chunk_size,
    };
}

pub fn deinit(self: *Self) void {
    const allocator = self.core.allocator;
    for (self.active_chunks.items) |chunk| self.destroyChunk(chunk);
    self.active_chunks.deinit(allocator);
    for (self.closed_chunks.items) |chunk| self.destroyChunk(chunk);
    self.closed_chunks.deinit(allocator);
    for (self.free_chunks.items) |chunk| self.destroyChunk(chunk);
    self.free_chunks.deinit(allocator);
}

fn destroyChunk(self: *Self, chunk: Chunk) void {
    self.core.device.releaseTransferBuffer(chunk.buffer);
    if (chunk.fence) |f| self.core.device.releaseFence(f);
}

pub fn recall(self: *Self) !void {
    var i: usize = 0;
    while (i < self.closed_chunks.items.len) {
        const chunk = &self.closed_chunks.items[i];
        if (chunk.fence) |f| {
            if (self.core.device.queryFence(f)) {
                var finished = self.closed_chunks.swapRemove(i);
                if (finished.fence) |old_f| self.core.device.releaseFence(old_f);
                finished.fence = null;
                // Only keep chunks that match our standard size in the free pool
                // to avoid keeping "jumbo" chunks forever.
                if (finished.size == self.chunk_size) {
                    try self.free_chunks.append(self.core.allocator, finished);
                } else {
                    self.core.device.releaseTransferBuffer(finished.buffer);
                }
                continue;
            }
        }
        i += 1;
    }
}

pub fn writeTexture(
    self: *Self,
    copy_pass: sdl3.gpu.CopyPass,
    dest: sdl3.gpu.TextureRegion,
    size: u32,
) ![]u8 {
    const allocation = try self.allocateSpace(size, COPY_BUFFER_ALIGNMENT);

    copy_pass.uploadToTexture(.{
        .transfer_buffer = allocation.chunk.buffer,
        .offset = allocation.offset,
    }, dest, false);

    const mapped = try self.core.device.mapTransferBuffer(allocation.chunk.buffer, false);
    return mapped[allocation.offset..][0..size];
}

pub fn allocateSpace(self: *Self, size: u32, alignment: u32) !struct { chunk: *Chunk, offset: u32 } {
    // 1. Try active chunks
    for (self.active_chunks.items) |*chunk| {
        if (chunk.canAllocate(size, alignment)) {
            return .{ .chunk = chunk, .offset = chunk.allocate(size, alignment) };
        }
    }

    try self.recall();

    // 2. Try free pool (only for standard sizes)
    if (size <= self.chunk_size and self.free_chunks.items.len > 0) {
        var c = self.free_chunks.pop().?;
        c.offset = 0;
        try self.active_chunks.append(self.core.allocator, c);
        const ref = &self.active_chunks.items[self.active_chunks.items.len - 1];
        return .{ .chunk = ref, .offset = ref.allocate(size, alignment) };
    }

    // 3. Create new chunk (Jumbo or Standard)
    const new_size = @max(self.chunk_size, size + alignment);
    const buf = try self.core.device.createTransferBuffer(.{ .size = new_size, .usage = .upload });
    try self.active_chunks.append(self.core.allocator, .{ .buffer = buf, .size = new_size, .offset = 0 });
    const ref = &self.active_chunks.items[self.active_chunks.items.len - 1];
    return .{ .chunk = ref, .offset = ref.allocate(size, alignment) };
}

pub fn finish(self: *Self, fence: sdl3.gpu.Fence) !void {
    while (self.active_chunks.items.len > 0) {
        var c = self.active_chunks.pop().?;
        self.core.device.unmapTransferBuffer(c.buffer);
        c.fence = fence;
        try self.closed_chunks.append(self.core.allocator, c);
    }
}
