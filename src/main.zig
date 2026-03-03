const Core = @import("core.zig");
const sdl3 = Core.sdl3;
const std = @import("std");
const za = Core.za;
const Camera = @import("camera.zig");
const Mesh = @import("mesh.zig");
const Texture = @import("texture.zig");

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

    const skybox_pipeline = blk: {
        const vertex_shader = try core.loadShader(.{
            .filename = "Skybox.vert",
            .uniform_buffer_count = 1,
        });
        defer core.device.releaseShader(vertex_shader);

        const fragment_shader = try core.loadShader(.{
            .filename = "Skybox.frag",
            .sampler_count = 1,
        });
        defer core.device.releaseShader(fragment_shader);

        // We want depth test = true (to draw behind),
        // but we'll use a specific mesh/state trick
        break :blk try core.createPipeline(.{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .depth_test = true,
            .depth_write = false,
        });
    };
    defer core.device.releaseGraphicsPipeline(skybox_pipeline);

    const texture = try Texture.loadPNG(&core, "Content/Images/viking_room.png");
    defer texture.deinit(&core);

    const skybox_texture = try Texture.loadCubemap(&core, .{
        "Content/Images/skybox/posx.png", // +X
        "Content/Images/skybox/negx.png", // -X
        "Content/Images/skybox/posy.png", // +Y
        "Content/Images/skybox/negy.png", // -Y
        "Content/Images/skybox/posz.png", // +Z
        "Content/Images/skybox/negz.png", // -Z
    });
    defer skybox_texture.deinit(&core);

    var mesh = try Mesh.initObj(&core, @embedFile("viking_room.obj"));
    defer mesh.deinit(&core);

    var sky_mesh = try Mesh.initCube(&core);
    defer sky_mesh.deinit(&core);

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

                renderpass.bindGraphicsPipeline(skybox_pipeline);
                renderpass.bindFragmentSamplers(0, &.{.{
                    .texture = skybox_texture.handle,
                    .sampler = sampler,
                }});

                // Calculate Skybox Matrix: (Proj * (View without translation))
                const proj = camera.getProjMatrix(za.Vec2.new(@floatFromInt(width), @floatFromInt(height)));
                var view = camera.getViewMatrix();

                // Strip translation (Column 3 in zalgebra/GLM math)
                view.data[3][0] = 0;
                view.data[3][1] = 0;
                view.data[3][2] = 0;

                const sky_mvp = za.Mat4.mul(proj, view);

                frame.command_buffer.pushVertexUniformData(0, std.mem.asBytes(&sky_mvp));
                sky_mesh.draw(renderpass);

                renderpass.bindGraphicsPipeline(pipeline);

                // 4. Bind Texture and Sampler
                renderpass.bindFragmentSamplers(0, &.{.{
                    .texture = texture.handle,
                    .sampler = sampler,
                }});

                const mat = camera.getDescriptorMatrix(za.Vec2.new(@floatFromInt(width), @floatFromInt(height)));
                frame.command_buffer.pushVertexUniformData(0, std.mem.asBytes(&mat));

                mesh.draw(renderpass);

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
