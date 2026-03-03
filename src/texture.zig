const std = @import("std");
const Core = @import("core.zig");
const sdl3 = Core.sdl3;

const Self = @This();

handle: sdl3.gpu.Texture,
width: u32,
height: u32,

/// Basic initialization for a raw GPU texture
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

    return .{
        .handle = handle,
        .width = w,
        .height = h,
    };
}

/// Specialized initializer for Depth Textures
pub fn initDepth(core: *Core, w: u32, h: u32) !Self {
    return try Self.init(core, w, h, .depth16_unorm, 1, .{ .depth_stencil_target = true });
}

/// Factory for Samplers
pub fn createSampler(core: *Core, info: sdl3.gpu.SamplerCreateInfo) !sdl3.gpu.Sampler {
    return try core.device.createSampler(info);
}

pub fn deinit(self: Self, core: *Core) void {
    core.device.releaseTexture(self.handle);
}

// --- Loading Logic ---

/// Loads a standard 2D texture from a PNG file
pub fn loadPNG(core: *Core, path: [:0]const u8) !Self {
    const raw_surface = try sdl3.surface.Surface.initFromPngFile(path);
    defer raw_surface.deinit();

    const surface = try raw_surface.convertFormat(.array_rgba_32);
    defer surface.deinit();

    const w: u32 = @intCast(surface.value.w);
    const h: u32 = @intCast(surface.value.h);
    const bpp: u32 = 4;
    const row_size = w * bpp;
    const total_size = row_size * h;

    const texture = try Self.init(core, w, h, .r8g8b8a8_unorm, 1, .{ .sampler = true });
    errdefer texture.deinit(core);

    const tight_pixels = try core.allocator.alloc(u8, total_size);
    defer core.allocator.free(tight_pixels);

    const src_pixels: [*]const u8 = @ptrCast(surface.value.pixels.?);
    const pitch: usize = @intCast(surface.value.pitch);

    for (0..h) |y| {
        @memcpy(
            tight_pixels[y * row_size .. (y + 1) * row_size],
            src_pixels[y * pitch .. y * pitch + row_size],
        );
    }

    try texture.upload(core, tight_pixels);
    return texture;
}

/// Loads 6 PNGs into a single Cubemap texture
pub fn loadCubemap(core: *Core, paths: [6][:0]const u8) !Self {
    var surfaces: [6]sdl3.surface.Surface = undefined;
    var converted: [6]sdl3.surface.Surface = undefined;

    for (paths, 0..) |path, i| {
        surfaces[i] = try sdl3.surface.Surface.initFromPngFile(path);
        converted[i] = try surfaces[i].convertFormat(.array_rgba_32);
        surfaces[i].deinit();
    }
    defer for (converted) |s| s.deinit();

    const w: u32 = @intCast(converted[0].value.w);
    const h: u32 = @intCast(converted[0].value.h);
    const bpp: u32 = 4;
    const face_size = w * h * bpp;
    const total_size = face_size * 6;

    const texture = try Self.init(core, w, h, .r8g8b8a8_unorm, 6, .{ .sampler = true });
    errdefer texture.deinit(core);

    const all_faces_pixels = try core.allocator.alloc(u8, total_size);
    defer core.allocator.free(all_faces_pixels);

    for (converted, 0..) |face, i| {
        const src_pixels: [*]const u8 = @ptrCast(face.value.pixels.?);
        const pitch: usize = @intCast(face.value.pitch);
        const face_offset = i * face_size;
        const row_size = w * bpp;

        for (0..h) |y| {
            @memcpy(
                all_faces_pixels[face_offset + (y * row_size) .. face_offset + (y + 1) * row_size],
                src_pixels[y * pitch .. y * pitch + row_size],
            );
        }
    }

    const transfer_buffer = try core.device.createTransferBuffer(.{
        .size = @intCast(total_size),
        .usage = .upload,
    });
    defer core.device.releaseTransferBuffer(transfer_buffer);

    const mapped = try core.device.mapTransferBuffer(transfer_buffer, false);
    @memcpy(mapped[0..total_size], all_faces_pixels);
    core.device.unmapTransferBuffer(transfer_buffer);

    const cmd = try core.device.acquireCommandBuffer();
    {
        const copy_pass = cmd.beginCopyPass();
        defer copy_pass.end();

        for (0..6) |i| {
            copy_pass.uploadToTexture(.{
                .transfer_buffer = transfer_buffer,
                .offset = @intCast(i * face_size),
            }, .{
                .texture = texture.handle,
                .width = w,
                .height = h,
                .depth = 1,
                .layer = @intCast(i),
            }, false);
        }
    }
    try cmd.submit();

    return texture;
}

fn upload(self: Self, core: *Core, pixels: []const u8) !void {
    const transfer_buffer = try core.device.createTransferBuffer(.{
        .size = @intCast(pixels.len),
        .usage = .upload,
    });
    defer core.device.releaseTransferBuffer(transfer_buffer);

    const mapped_data = try core.device.mapTransferBuffer(transfer_buffer, false);
    @memcpy(mapped_data[0..pixels.len], pixels);
    core.device.unmapTransferBuffer(transfer_buffer);

    const command_buffer = try core.device.acquireCommandBuffer();
    {
        const copy_pass = command_buffer.beginCopyPass();
        defer copy_pass.end();

        copy_pass.uploadToTexture(.{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        }, .{
            .texture = self.handle,
            .width = self.width,
            .height = self.height,
            .depth = 1,
        }, false);
    }
    try command_buffer.submit();
}
