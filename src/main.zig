const Core = @import("core.zig");
const sdl3 = Core.sdl3;
const std = @import("std");
const za = Core.za;
const Camera = @import("camera.zig");

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;

    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();
    _ = try sdl3.setMemoryFunctionsByAllocator(allocator);

    var core = try Core.init(.{
        .title = "SDL Codotaku",
        .width = 800,
        .height = 600,
        .debug_mode = true,
        .allocator = allocator,
    });
    defer core.deinit();

    const window_size = try core.window.getSizeInPixels();
    var width: u32 = @intCast(window_size.@"0");
    var height: u32 = @intCast(window_size.@"1");

    var camera = Camera.init(za.Vec3.new(1.8, 1.8, 1.8), za.Vec3.new(0.0, 0.5, 0.0), za.Vec3.up());

    var depth_texture = try core.createDepthTexture(width, height);
    defer core.device.releaseTexture(depth_texture);

    const pipeline = blk: {
        const vertex_shader = try core.loadShader(.{
            .filename = "PositionColorTransform.vert",
            .uniform_buffer_count = 1,
        });
        defer core.device.releaseShader(vertex_shader);

        const fragment_shader = try core.loadShader(.{
            .filename = "SolidColor.frag",
        });
        defer core.device.releaseShader(fragment_shader);

        const pipeline = try core.createPipeline(.{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .depth_test = true,
        });

        break :blk pipeline;
    };
    defer core.device.releaseGraphicsPipeline(pipeline);

    const vertices = [_]Core.Vertex{
        // Front face
        .{ .position = za.Vec3.new(-0.5, 0.5, 0.5), .color = za.GenericVector(4, u8).new(255, 0, 0, 255) }, // 0
        .{ .position = za.Vec3.new(0.5, 0.5, 0.5), .color = za.GenericVector(4, u8).new(0, 255, 0, 255) }, // 1
        .{ .position = za.Vec3.new(0.5, -0.5, 0.5), .color = za.GenericVector(4, u8).new(0, 0, 255, 255) }, // 2
        .{ .position = za.Vec3.new(-0.5, -0.5, 0.5), .color = za.GenericVector(4, u8).new(255, 255, 255, 255) }, // 3
        // Back face
        .{ .position = za.Vec3.new(-0.5, 0.5, -0.5), .color = za.GenericVector(4, u8).new(255, 0, 255, 255) }, // 4
        .{ .position = za.Vec3.new(0.5, 0.5, -0.5), .color = za.GenericVector(4, u8).new(255, 255, 0, 255) }, // 5
        .{ .position = za.Vec3.new(0.5, -0.5, -0.5), .color = za.GenericVector(4, u8).new(0, 255, 255, 255) }, // 6
        .{ .position = za.Vec3.new(-0.5, -0.5, -0.5), .color = za.GenericVector(4, u8).new(0, 0, 0, 255) }, // 7
    };

    const indices = [_]u32{
        // Front
        0, 1, 2, 2, 3, 0,
        // Right
        1, 5, 6, 6, 2, 1,
        // Back
        5, 4, 7, 7, 6, 5,
        // Left
        4, 0, 3, 3, 7, 4,
        // Bottom
        3, 2, 6, 6, 7, 3,
        // Top
        4, 5, 1, 1, 0, 4,
    };

    const buffers = try core.uploadBuffers(&.{
        Core.makeUpload(Core.Vertex, &vertices, .{ .vertex = true }),
        Core.makeUpload(u32, &indices, .{ .index = true }),
    });
    defer {
        for (buffers) |buffer| {
            core.device.releaseBuffer(buffer);
        }
        allocator.free(buffers);
    }

    const vertex_buffer = buffers[0];
    const index_buffer = buffers[1];

    var start_ticks = sdl3.timer.getMillisecondsSinceInit();

    var quit = false;
    while (!quit) {
        const current_ticks = sdl3.timer.getMillisecondsSinceInit();

        const dt = @as(f32, @floatFromInt(current_ticks - start_ticks)) / 1000.0;
        start_ticks = current_ticks;
        camera.update(dt);

        if (try core.beginFrame()) |frame| {
            {
                const renderpass = try frame.renderpass(.{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 255 }, depth_texture);
                renderpass.bindGraphicsPipeline(pipeline);
                renderpass.bindIndexBuffer(.{ .buffer = index_buffer, .offset = 0 }, .indices_32bit);
                renderpass.bindVertexBuffers(0, &.{.{
                    .buffer = vertex_buffer,
                    .offset = 0,
                }});
                const mat = camera.getDescriptorMatrix(za.Vec2.new(@floatFromInt(width), @floatFromInt(height)));
                frame.command_buffer.pushVertexUniformData(0, std.mem.asBytes(&mat));
                renderpass.drawIndexedPrimitives(indices.len, 1, 0, 0, 0);
                defer renderpass.end();
            }

            try frame.end();
        }

        while (Core.poll()) |event| {
            camera.onEvent(event.toSdl(), core.window.value);
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                .window_resized => |ev| {
                    width = @intCast(ev.width);
                    height = @intCast(ev.height);

                    core.device.releaseTexture(depth_texture);
                    depth_texture = try core.createDepthTexture(width, height);
                },
                else => {},
            }
        }
    }
}
