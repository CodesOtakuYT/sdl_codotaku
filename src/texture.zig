const std = @import("std");
const Core = @import("core.zig");
const sdl3 = Core.sdl3;

const Texture = @This();

handle: sdl3.gpu.Texture,
width: u32,
height: u32,

/// Intermediate CPU-side storage for pixel data.
/// Can be loaded on any thread without a GPU device.
pub const TextureData = struct {
    width: u32,
    height: u32,
    layers: u32,
    /// Raw pixel data (typically RGBA8)
    pixels: std.ArrayListUnmanaged(u8) = .{},

    pub fn deinit(self: *TextureData, allocator: std.mem.Allocator) void {
        self.pixels.deinit(allocator);
    }

    /// Uploads the pixel data to a GPU texture.
    pub fn upload(self: TextureData, core: *Core, copy_pass: sdl3.gpu.CopyPass) !Texture {
        const format: sdl3.gpu.TextureFormat = .r8g8b8a8_unorm;
        const texture = try Texture.init(core, self.width, self.height, format, self.layers, .{ .sampler = true });
        errdefer texture.deinit(core);

        const face_size = self.width * self.height * 4;

        for (0..self.layers) |i| {
            const staging_slice = try core.staging_belt.writeTexture(
                copy_pass,
                .{ .texture = texture.handle, .width = self.width, .height = self.height, .depth = 1, .layer = @intCast(i) },
                face_size,
            );

            const offset = i * face_size;
            @memcpy(staging_slice, self.pixels.items[offset .. offset + face_size]);
        }

        return texture;
    }
};

// --- CPU Loading Logic ---

/// Decodes a PNG file into CPU memory.
pub fn loadPNGData(allocator: std.mem.Allocator, path: [:0]const u8) !TextureData {
    const raw_surface = try sdl3.surface.Surface.initFromPngFile(path);
    defer raw_surface.deinit();

    // Ensure standard RGBA8 format
    const surface = try raw_surface.convertFormat(.array_rgba_32);
    defer surface.deinit();

    const w: u32 = @intCast(surface.value.w);
    const h: u32 = @intCast(surface.value.h);
    const row_size = w * 4;
    const total_size = row_size * h;

    var pixels = try std.ArrayListUnmanaged(u8).initCapacity(allocator, total_size);
    errdefer pixels.deinit(allocator);

    // Handle pitch/stride differences between SDL surface and tightly packed buffer
    const src_pixels: [*]const u8 = @ptrCast(surface.value.pixels.?);
    const pitch: u32 = @intCast(surface.value.pitch);

    for (0..h) |y| {
        const row = src_pixels[y * pitch .. y * pitch + row_size];
        pixels.appendSliceAssumeCapacity(row);
    }

    return TextureData{
        .width = w,
        .height = h,
        .layers = 1,
        .pixels = pixels,
    };
}

/// Decodes 6 PNG files into a single CPU-side cubemap buffer.
pub fn loadCubemapData(allocator: std.mem.Allocator, paths: [6][:0]const u8) !TextureData {
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

    var pixels = try std.ArrayListUnmanaged(u8).initCapacity(allocator, face_size * 6);
    errdefer pixels.deinit(allocator);

    for (converted) |face| {
        const src_pixels: [*]const u8 = @ptrCast(face.value.pixels.?);
        const pitch: u32 = @intCast(face.value.pitch);
        for (0..h) |y| {
            pixels.appendSliceAssumeCapacity(src_pixels[y * pitch .. y * pitch + row_size]);
        }
    }

    return TextureData{
        .width = w,
        .height = h,
        .layers = 6,
        .pixels = pixels,
    };
}

// --- GPU Logic ---

pub fn init(core: *Core, w: u32, h: u32, format: sdl3.gpu.TextureFormat, layers: u32, usage: sdl3.gpu.TextureUsageFlags) !Texture {
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

pub fn initDepth(core: *Core, w: u32, h: u32) !Texture {
    return try Texture.init(core, w, h, .depth16_unorm, 1, .{ .depth_stencil_target = true });
}

pub fn createSampler(core: *Core, info: sdl3.gpu.SamplerCreateInfo) !sdl3.gpu.Sampler {
    return try core.device.createSampler(info);
}

pub fn deinit(self: Texture, core: *Core) void {
    core.device.releaseTexture(self.handle);
}
