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

pub fn end(self: Self) !void {
    self.copy_pass.end();
    const fence = try self.cmd.submitAndAcquireFence();

    // Tell the belt this fence tracks the current chunks
    try self.core.staging_belt.finish(fence);

    // Block until the GPU is actually done (important for startup loading)
    try self.core.device.waitForFences(true, &.{fence});
    self.core.device.releaseFence(fence);
}
