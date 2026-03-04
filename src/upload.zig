const std = @import("std");
const Core = @import("core.zig");
const sdl3 = Core.sdl3;

const Self = @This();

core: *Core,
cmd: sdl3.gpu.CommandBuffer,
copy_pass: sdl3.gpu.CopyPass,

pub fn begin(core: *Core) !Self {
    const cmd = try core.device.acquireCommandBuffer();
    const copy_pass = cmd.beginCopyPass();
    return .{
        .core = core,
        .cmd = cmd,
        .copy_pass = copy_pass,
    };
}

/// Submits the work and returns a Fence immediately.
/// The caller is responsible for waiting/querying and releasing the fence.
pub fn submitAsync(self: Self) !sdl3.gpu.Fence {
    self.copy_pass.end();
    const fence = try self.cmd.submitAndAcquireFence();

    // Link the staging belt chunks to this fence so they can be recycled
    // once the GPU is done.
    try self.core.staging_belt.finish(fence);

    return fence;
}

/// Traditional blocking end.
/// Useful for initial "Loading..." screens where you want everything ready NOW.
pub fn end(self: Self) !void {
    const fence = try self.submitAsync();

    // Block the CPU until the GPU reaches this fence
    try self.core.device.waitForFences(true, &.{fence});

    // Once we are past the wait, the fence is no longer needed
    self.core.device.releaseFence(fence);
}
