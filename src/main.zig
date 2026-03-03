const Core = @import("core.zig");
const sdl3 = Core.sdl3;
const std = @import("std");
const za = Core.za;

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

    var depth_texture = try core.createDepthTexture(width, height);
    defer core.device.releaseTexture(depth_texture);

    const pipeline = blk: {
        const vertex_shader = try core.loadShader(.{
            .filename = "PositionColor.vert",
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
        .{ .position = za.Vec3.new(0.0, 0.5, 0.0), .color = za.GenericVector(4, u8).new(255, 0, 0, 255) },
        .{ .position = za.Vec3.new(0.5, -0.5, 0.0), .color = za.GenericVector(4, u8).new(0, 255, 0, 255) },
        .{ .position = za.Vec3.new(-0.5, -0.5, 0.0), .color = za.GenericVector(4, u8).new(0, 0, 255, 255) },
    };
    const indices = [_]u32{ 0, 1, 2 };

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

    var quit = false;
    while (!quit) {
        if (try core.beginFrame()) |frame| {
            {
                const renderpass = try frame.renderpass(.{ .r = 255, .g = 255, .b = 0, .a = 255 }, depth_texture);
                renderpass.bindGraphicsPipeline(pipeline);
                renderpass.bindIndexBuffer(.{ .buffer = index_buffer, .offset = 0 }, .indices_32bit);
                renderpass.bindVertexBuffers(0, &.{.{
                    .buffer = vertex_buffer,
                    .offset = 0,
                }});
                renderpass.drawIndexedPrimitives(indices.len, 1, 0, 0, 0);
                defer renderpass.end();
            }

            try frame.end();
        }

        while (Core.poll()) |event|
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
            };
    }
}
