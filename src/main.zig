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
        });

        break :blk pipeline;
    };
    defer core.device.releaseGraphicsPipeline(pipeline);

    var vertices = [_]Core.Vertex{
        .{ .position = za.Vec3.new(0.0, 0.5, 0.0), .color = za.GenericVector(4, u8).new(255, 0, 0, 255) },
        .{ .position = za.Vec3.new(0.5, -0.5, 0.0), .color = za.GenericVector(4, u8).new(0, 255, 0, 255) },
        .{ .position = za.Vec3.new(-0.5, -0.5, 0.0), .color = za.GenericVector(4, u8).new(0, 0, 255, 255) },
    };

    // 2. Upload the data to a GPU Vertex Buffer
    const vertex_buffer = try core.uploadData(Core.Vertex, &vertices, .{ .vertex = true });
    defer core.device.releaseBuffer(vertex_buffer);

    var quit = false;
    while (!quit) {
        if (try core.beginFrame()) |frame| {
            {
                const renderpass = try frame.renderpass(.{ .r = 255, .g = 255, .b = 0, .a = 255 });
                renderpass.bindGraphicsPipeline(pipeline);
                renderpass.bindVertexBuffers(0, &.{.{
                    .buffer = vertex_buffer,
                    .offset = 0,
                }});
                renderpass.drawPrimitives(3, 1, 0, 0);
                defer renderpass.end();
            }

            try frame.end();
        }

        while (Core.poll()) |event|
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                else => {},
            };
    }
}
