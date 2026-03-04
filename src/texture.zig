const std = @import("std");
const Core = @import("core.zig");
const sdl3 = Core.sdl3;

const Self = @This();

handle: sdl3.gpu.Texture,
width: u32,
height: u32,

pub fn init(core: *Core, w: u32, h: u32, format: sdl3.gpu.TextureFormat, layers: u32, usage: sdl3.gpu.TextureUsageFlags) !Self {
    const handle = try core.device.createTexture(.{
        .texture_type = if (layers == 6) .cube else if (layers > 1) .two_dimensional_array else .two_dimensional,
        .format = format,
        .width = @max(w, 1),
        .height = @max(h, 1),
        .layer_count_or_depth = layers,
        .num_levels = 1,
        .sample_count = .no_multisampling,
        .usage = usage,
    });
    return .{ .handle = handle, .width = w, .height = h };
}

pub fn initDepth(core: *Core, w: u32, h: u32) !Self {
    return try Self.init(core, w, h, .depth16_unorm, 1, .{ .depth_stencil_target = true });
}

pub fn createSampler(core: *Core, info: sdl3.gpu.SamplerCreateInfo) !sdl3.gpu.Sampler {
    return try core.device.createSampler(info);
}

pub fn deinit(self: Self, core: *Core) void {
    core.device.releaseTexture(self.handle);
}

pub fn loadPNG(core: *Core, path: [:0]const u8) !Self {
    const raw_surface = try sdl3.surface.Surface.initFromPngFile(path);
    defer raw_surface.deinit();
    const surface = try raw_surface.convertFormat(.array_rgba_32);
    defer surface.deinit();

    const w: u32 = @intCast(surface.value.w);
    const h: u32 = @intCast(surface.value.h);
    const texture = try Self.init(core, w, h, .r8g8b8a8_unorm, 1, .{ .sampler = true });
    errdefer texture.deinit(core);

    const cmd = try core.device.acquireCommandBuffer();
    const copy_pass = cmd.beginCopyPass();
    const row_size = w * 4;

    const staging_slice = try core.staging_belt.writeTexture(
        copy_pass,
        .{ .texture = texture.handle, .width = w, .height = h, .depth = 1 },
        row_size * h,
    );

    const src_pixels: [*]const u8 = @ptrCast(surface.value.pixels.?);
    const pitch: u32 = @intCast(surface.value.pitch);
    for (0..h) |y| {
        @memcpy(staging_slice[y * row_size .. (y + 1) * row_size], src_pixels[y * pitch .. y * pitch + row_size]);
    }

    copy_pass.end();
    const fence = try cmd.submitAndAcquireFence();
    try core.staging_belt.finish(fence);
    try core.device.waitForFences(true, &.{fence});
    core.device.releaseFence(fence);

    return texture;
}

pub fn loadCubemap(core: *Core, paths: [6][:0]const u8) !Self {
    var converted: [6]sdl3.surface.Surface = undefined;
    for (paths, 0..) |path, i| {
        const s = try sdl3.surface.Surface.initFromPngFile(path);
        converted[i] = try s.convertFormat(.array_rgba_32);
        s.deinit();
    }
    defer for (converted) |s| s.deinit();

    const w: u32 = @intCast(converted[0].value.w);
    const h: u32 = @intCast(converted[0].value.h);
    const row_size = w * 4;
    const face_size = row_size * h;

    const texture = try Self.init(core, w, h, .r8g8b8a8_unorm, 6, .{ .sampler = true });
    errdefer texture.deinit(core);

    const cmd = try core.device.acquireCommandBuffer();
    const copy_pass = cmd.beginCopyPass();

    for (converted, 0..) |face, i| {
        const staging_slice = try core.staging_belt.writeTexture(
            copy_pass,
            .{ .texture = texture.handle, .width = w, .height = h, .depth = 1, .layer = @intCast(i) },
            face_size,
        );

        const src_pixels: [*]const u8 = @ptrCast(face.value.pixels.?);
        const pitch: u32 = @intCast(face.value.pitch);
        for (0..h) |y| {
            @memcpy(staging_slice[y * row_size .. (y + 1) * row_size], src_pixels[y * pitch .. y * pitch + row_size]);
        }
    }

    copy_pass.end();
    const fence = try cmd.submitAndAcquireFence();
    // Finish moves active chunks to closed list. Only do this once per submission.
    try core.staging_belt.finish(fence);

    try core.device.waitForFences(true, &.{fence});
    core.device.releaseFence(fence);

    return texture;
}
