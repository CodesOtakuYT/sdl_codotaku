pub const sdl3 = @import("sdl3");
const std = @import("std");
pub const za = @import("zalgebra");

const Self = @This();

allocator: std.mem.Allocator,
device: sdl3.gpu.Device,
window: sdl3.video.Window,
shaders_base_path: []const u8,
shader_backend: ShaderBackend,

const ShaderBackend = struct {
    format: sdl3.gpu.ShaderFormatFlags,
    subdir: []const u8,
    ext: []const u8,
    entrypoint: [:0]const u8,
};

const Info = struct {
    title: [:0]const u8,
    width: usize,
    height: usize,
    debug_mode: bool,
    driver_name: ?[:0]const u8 = null,
    allocator: std.mem.Allocator,
};

pub fn init(info: Info) !Self {
    const init_flags = sdl3.InitFlags{ .video = true };
    try sdl3.init(init_flags);
    errdefer sdl3.shutdown();

    const device = try sdl3.gpu.Device.init(.{
        .spirv = true,
        .dxil = true,
        .msl = true,
    }, info.debug_mode, info.driver_name);

    const window = try sdl3.video.Window.init(info.title, info.width, info.height, .{
        .hidden = true,
        .resizable = true,
    });
    errdefer window.deinit();

    try device.claimWindow(window);

    const backend_formats = device.getShaderFormats();

    const shader_backend: ShaderBackend = if (backend_formats.spirv)
        .{ .format = .{ .spirv = true }, .subdir = "SPIRV", .ext = ".spv", .entrypoint = "main" }
    else if (backend_formats.msl)
        .{ .format = .{ .msl = true }, .subdir = "MSL", .ext = ".msl", .entrypoint = "main0" }
    else if (backend_formats.dxil)
        .{ .format = .{ .dxil = true }, .subdir = "DXIL", .ext = ".dxil", .entrypoint = "main" }
    else
        return error.UnrecognizedShaderFormat;

    const base_path = try sdl3.filesystem.getBasePath();

    const shaders_base_path = try std.fmt.allocPrint(
        info.allocator,
        "{s}Content/Shaders/Compiled/{s}/",
        .{ base_path, shader_backend.subdir },
    );
    errdefer info.allocator.free(shaders_base_path);

    try window.show();

    return .{
        .device = device,
        .window = window,
        .shaders_base_path = shaders_base_path,
        .allocator = info.allocator,
        .shader_backend = shader_backend,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.shaders_base_path);
    self.device.releaseWindow(self.window);
    self.window.deinit();
    self.device.deinit();
    sdl3.shutdown();
}

pub fn poll() ?sdl3.events.Event {
    return sdl3.events.poll();
}

const Frame = struct {
    command_buffer: sdl3.gpu.CommandBuffer,
    texture: sdl3.gpu.Texture,
    width: u32,
    height: u32,

    pub fn end(self: Frame) !void {
        try self.command_buffer.submit();
    }

    pub fn renderpass(self: Frame, clear_color: sdl3.pixels.FColor, depth_texture: ?sdl3.gpu.Texture) !sdl3.gpu.RenderPass {
        const depth_info: ?sdl3.gpu.DepthStencilTargetInfo = if (depth_texture) |dt| .{
            .texture = dt,
            .cycle = true,
            .clear_depth = 1.0,
            .clear_stencil = 0,
            .load = .clear,
            .store = .store,
            .stencil_load = .clear,
            .stencil_store = .store,
        } else null;

        const render_pass = self.command_buffer.beginRenderPass(&.{sdl3.gpu.ColorTargetInfo{
            .texture = self.texture,
            .clear_color = clear_color,
            .load = .clear,
            .store = .store,
        }}, if (depth_info) |di| di else null);

        render_pass.setViewport(.{ .max_depth = 1, .region = .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(self.width),
            .h = @floatFromInt(self.height),
        } });
        render_pass.setScissor(.{
            .x = 0,
            .y = 0,
            .w = @intCast(self.width),
            .h = @intCast(self.height),
        });
        return render_pass;
    }
};

pub fn beginFrame(self: *Self) !?Frame {
    const command_buffer = try self.device.acquireCommandBuffer();

    const swapchain = try command_buffer.waitAndAcquireSwapchainTexture(self.window);

    if (swapchain.@"0") |texture| {
        return Frame{
            .command_buffer = command_buffer,
            .texture = texture,
            .width = swapchain.@"1",
            .height = swapchain.@"2",
        };
    }

    return null;
}

const ShaderInfo = struct {
    filename: [:0]const u8,
    sampler_count: u32 = 0,
    uniform_buffer_count: u32 = 0,
    storage_buffer_count: u32 = 0,
    storage_texture_count: u32 = 0,
};

pub fn loadShader(
    self: *Self,
    info: ShaderInfo,
) !sdl3.gpu.Shader {
    const stage: sdl3.gpu.ShaderStage = if (std.mem.indexOf(u8, info.filename, ".vert") != null)
        .vertex
    else if (std.mem.indexOf(u8, info.filename, ".frag") != null)
        .fragment
    else
        return error.InvalidShaderStage;

    const shader_path = try std.fmt.allocPrintSentinel(
        self.allocator,
        "{s}{s}{s}",
        .{ self.shaders_base_path, info.filename, self.shader_backend.ext },
        0,
    );
    defer self.allocator.free(shader_path);

    errdefer std.debug.print("{s}", .{sdl3.errors.get().?});
    const code = try sdl3.io_stream.loadFile(shader_path);
    defer sdl3.free(code);

    return self.device.createShader(.{
        .code = code,
        .entry_point = self.shader_backend.entrypoint,
        .format = self.shader_backend.format,
        .stage = stage,
        .num_samplers = info.sampler_count,
        .num_uniform_buffers = info.uniform_buffer_count,
        .num_storage_buffers = info.storage_buffer_count,
        .num_storage_textures = info.storage_texture_count,
    });
}

const PipelineInfo = struct {
    vertex_shader: sdl3.gpu.Shader,
    fragment_shader: sdl3.gpu.Shader,
    depth_test: bool = false,
};

pub const Vertex = struct {
    position: za.Vec3,
    uv: za.Vec2,
};

pub fn createPipeline(self: *Self, info: PipelineInfo) !sdl3.gpu.GraphicsPipeline {
    return self.device.createGraphicsPipeline(.{
        .vertex_shader = info.vertex_shader,
        .fragment_shader = info.fragment_shader,
        .depth_stencil_state = if (info.depth_test) sdl3.gpu.DepthStencilState{
            .enable_depth_test = true,
            .enable_depth_write = true,
            .compare = .less,
            .write_mask = 0xFF,
        } else .{},
        .target_info = sdl3.gpu.GraphicsPipelineTargetInfo{
            .color_target_descriptions = &.{
                sdl3.gpu.ColorTargetDescription{
                    .format = try self.device.getSwapchainTextureFormat(self.window),
                },
            },
            .depth_stencil_format = if (info.depth_test) .depth16_unorm else null,
        },
        .vertex_input_state = sdl3.gpu.VertexInputState{
            .vertex_buffer_descriptions = &.{
                sdl3.gpu.VertexBufferDescription{
                    .input_rate = .vertex,
                    .slot = 0,
                    .pitch = @sizeOf(Vertex),
                },
            },
            .vertex_attributes = &.{
                sdl3.gpu.VertexAttribute{
                    .buffer_slot = 0,
                    .format = .f32x3,
                    .location = 0,
                    .offset = @offsetOf(Vertex, "position"),
                },
                sdl3.gpu.VertexAttribute{
                    .buffer_slot = 0,
                    .format = .f32x2,
                    .location = 1,
                    .offset = @offsetOf(Vertex, "uv"),
                },
            },
        },
    });
}

pub fn createBuffer(self: *Self, size: u32, usage: sdl3.gpu.BufferUsageFlags) !sdl3.gpu.Buffer {
    const buffer = try self.device.createBuffer(.{ .size = size, .usage = usage });
    return buffer;
}

const BufferUpload = struct {
    data: []const u8,
    usage: sdl3.gpu.BufferUsageFlags,
};

pub fn uploadBuffers(self: *Self, uploads: []const BufferUpload) ![]sdl3.gpu.Buffer {
    // Calculate total size and per-buffer offsets
    var total_size: u32 = 0;
    const offsets = try self.allocator.alloc(u32, uploads.len);
    defer self.allocator.free(offsets);

    for (uploads, 0..) |upload, i| {
        offsets[i] = total_size;
        total_size += @intCast(upload.data.len);
    }

    // Create all GPU buffers
    const buffers = try self.allocator.alloc(sdl3.gpu.Buffer, uploads.len);
    errdefer self.allocator.free(buffers);

    for (uploads, 0..) |upload, i| {
        buffers[i] = try self.createBuffer(@intCast(upload.data.len), upload.usage);
    }

    // Single transfer buffer for everything
    const transfer_buffer = try self.device.createTransferBuffer(.{
        .size = total_size,
        .usage = .upload,
    });
    defer self.device.releaseTransferBuffer(transfer_buffer);

    // Map once and copy all data at their respective offsets
    const mapped_data = try self.device.mapTransferBuffer(transfer_buffer, false);
    for (uploads, 0..) |upload, i| {
        @memcpy(mapped_data[offsets[i]..][0..upload.data.len], upload.data);
    }
    self.device.unmapTransferBuffer(transfer_buffer);

    // Single command buffer and copy pass for all uploads
    const command_buffer = try self.device.acquireCommandBuffer();
    {
        const copy_pass = command_buffer.beginCopyPass();
        defer copy_pass.end();

        for (uploads, 0..) |upload, i| {
            copy_pass.uploadToBuffer(.{
                .transfer_buffer = transfer_buffer,
                .offset = offsets[i],
            }, .{
                .buffer = buffers[i],
                .offset = 0,
                .size = @intCast(upload.data.len),
            }, false);
        }
    }
    try command_buffer.submit();

    return buffers;
}

// Typed helper to make call sites cleaner
pub fn makeUpload(comptime T: type, data: []const T, usage: sdl3.gpu.BufferUsageFlags) BufferUpload {
    return .{
        .data = std.mem.sliceAsBytes(data),
        .usage = usage,
    };
}

pub fn createTexture(self: *Self, w: u32, h: u32, format: sdl3.gpu.TextureFormat) !sdl3.gpu.Texture {
    return self.device.createTexture(.{
        .format = format,
        .width = w,
        .height = h,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .usage = .{ .sampler = true },
    });
}

pub fn createDepthTexture(self: *Self, width: u32, height: u32) !sdl3.gpu.Texture {
    return self.device.createTexture(.{
        .width = width,
        .height = height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = .no_multisampling,
        .format = .depth16_unorm,
        .usage = .{ .depth_stencil_target = true },
    });
}

pub fn createSampler(self: *Self, info: sdl3.gpu.SamplerCreateInfo) !sdl3.gpu.Sampler {
    return try self.device.createSampler(info);
}

pub fn uploadTexture(self: *Self, texture: sdl3.gpu.Texture, pixels: []const u8, width: u32, height: u32) !void {
    // 1. Create a transfer buffer large enough for the pixel data
    const transfer_buffer = try self.device.createTransferBuffer(.{
        .size = @intCast(pixels.len),
        .usage = .upload,
    });
    defer self.device.releaseTransferBuffer(transfer_buffer);

    // 2. Map the buffer and copy the CPU pixel data into it
    const mapped_data = try self.device.mapTransferBuffer(transfer_buffer, false);
    @memcpy(mapped_data[0..pixels.len], pixels);
    self.device.unmapTransferBuffer(transfer_buffer);

    // 3. Acquire a command buffer to perform the copy
    const command_buffer = try self.device.acquireCommandBuffer();

    // 4. Record the copy command from the transfer buffer to the texture
    {
        const copy_pass = command_buffer.beginCopyPass();
        defer copy_pass.end();

        copy_pass.uploadToTexture(.{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        }, .{
            .texture = texture,
            .width = width,
            .height = height,
            .depth = 1,
        }, false);
    }

    // 5. Submit and wait for the GPU to finish the transfer
    try command_buffer.submit();
}

pub fn loadTexturePNG(self: *Self, path: [:0]const u8) !sdl3.gpu.Texture {
    // 1. Load the image into an SDL Surface
    // SDL3's loadSurface is the equivalent of the old IMG_Load or SDL_LoadPNG
    const raw_surface = try sdl3.surface.Surface.initFromPngFile(path);
    defer raw_surface.deinit();

    // 2. Convert to RGBA32 to ensure 4 bytes per pixel (R, G, B, A)
    // This matches the .r8g8b8a8_unorm GPU format
    const surface = try raw_surface.convertFormat(.array_rgba_32);
    defer surface.deinit();

    const width: u32 = @intCast(surface.value.w);
    const height: u32 = @intCast(surface.value.h);
    const bpp: u32 = 4;
    const row_size = width * bpp;
    const total_size = row_size * height;

    // 3. Create the GPU Texture
    const texture = try self.createTexture(width, height, .r8g8b8a8_unorm);
    errdefer self.device.releaseTexture(texture);

    // 4. Prepare the pixel data for upload
    // We allocate a temporary buffer to ensure pixels are tightly packed
    // (removing any SDL pitch/padding)
    const tight_pixels = try self.allocator.alloc(u8, total_size);
    defer self.allocator.free(tight_pixels);

    const src_pixels: [*]const u8 = @ptrCast(surface.value.pixels.?);
    const pitch: usize = @intCast(surface.value.pitch);

    for (0..height) |y| {
        const src_offset = y * pitch;
        const dst_offset = y * row_size;
        @memcpy(tight_pixels[dst_offset .. dst_offset + row_size], src_pixels[src_offset .. src_offset + row_size]);
    }

    // 5. Upload to GPU using our existing helper
    try self.uploadTexture(texture, tight_pixels, width, height);

    return texture;
}
