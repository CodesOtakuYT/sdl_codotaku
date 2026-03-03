const Core = @import("core.zig");
const sdl3 = Core.sdl3;
const std = @import("std");
const za = Core.za;
const Camera = @import("camera.zig");
const Mesh = @import("mesh.zig");

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();
    _ = try sdl3.setMemoryFunctionsByAllocator(allocator);

    var core = try Core.init(.{
        .title = "SDL Codotaku - Textured Cube",
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

    // 1. Create a Sampler
    const sampler = try core.createSampler(.{
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .mipmap_mode = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
    });
    defer core.device.releaseSampler(sampler);

    // 2. Load Shaders with Sampler/Uniform counts
    const pipeline = blk: {
        const vertex_shader = try core.loadShader(.{
            .filename = "TexturedQuadWithMatrix.vert", // New Shader
            .uniform_buffer_count = 1,
        });
        defer core.device.releaseShader(vertex_shader);

        const fragment_shader = try core.loadShader(.{
            .filename = "TexturedQuad.frag", // New Shader
            .sampler_count = 1, // Must match the shader!
        });
        defer core.device.releaseShader(fragment_shader);

        break :blk try core.createPipeline(.{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .depth_test = true,
        });
    };
    defer core.device.releaseGraphicsPipeline(pipeline);

    const texture = try core.loadTexturePNG("Content/Images/viking_room.png");
    defer core.device.releaseTexture(texture);

    var cube_mesh = try Mesh.initObj(&core, @embedFile("viking_room.obj"));
    defer cube_mesh.deinit(&core);

    var start_ticks = sdl3.timer.getMillisecondsSinceInit();
    var quit = false;
    while (!quit) {
        const current_ticks = sdl3.timer.getMillisecondsSinceInit();
        const dt = @as(f32, @floatFromInt(current_ticks - start_ticks)) / 1000.0;
        start_ticks = current_ticks;
        camera.update(dt);

        if (try core.beginFrame()) |frame| {
            {
                const renderpass = try frame.renderpass(.{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 }, depth_texture);

                renderpass.bindGraphicsPipeline(pipeline);

                // 4. Bind Texture and Sampler
                renderpass.bindFragmentSamplers(0, &.{.{
                    .texture = texture,
                    .sampler = sampler,
                }});

                const mat = camera.getDescriptorMatrix(za.Vec2.new(@floatFromInt(width), @floatFromInt(height)));
                frame.command_buffer.pushVertexUniformData(0, std.mem.asBytes(&mat));

                cube_mesh.draw(renderpass);

                renderpass.end();
            }
            try frame.end();
        }

        while (Core.poll()) |event| {
            camera.onEvent(event.toSdl(), core.window.value);
            switch (event) {
                .quit => quit = true,
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
