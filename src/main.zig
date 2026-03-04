const std = @import("std");
const Core = @import("core.zig");
const sdl3 = Core.sdl3;
const za = Core.za;

const Camera = @import("camera.zig");
const Mesh = @import("mesh.zig");
const Texture = @import("texture.zig");
const Pipeline = @import("pipeline.zig");
const Upload = @import("upload.zig");
const AssetManager = @import("asset_manager.zig");

pub fn main() !void {
    // --- 1. System Setup ---
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    _ = try sdl3.setMemoryFunctionsByAllocator(allocator);

    var core = try Core.init(.{
        .title = "SDL Codotaku - Asset Manager Refactor",
        .width = 800,
        .height = 600,
        .debug_mode = true,
        .allocator = allocator,
        .staging_chunk_size = 1024 * 1024,
    });
    defer core.deinit();

    const window_size = try core.window.getSizeInPixels();
    var width: u32 = @intCast(window_size.@"0");
    var height: u32 = @intCast(window_size.@"1");

    // --- 2. Asset Manager & Loading ---
    var assets = AssetManager.init(core, allocator);
    // assets.deinit() will now handle releasing all GPU textures/meshes automatically
    defer assets.deinit();

    var upload = try Upload.begin(core);

    // Assets are loaded via the manager.
    // Internally, it loads CPU data, uploads to GPU, then frees CPU data.
    const tex_viking = try assets.loadTexture(&upload, "Content/Images/viking_room.png");
    const tex_sky = try assets.loadCubemap(&upload, "skybox", .{
        "Content/Images/skybox/posx.png", "Content/Images/skybox/negx.png",
        "Content/Images/skybox/posy.png", "Content/Images/skybox/negy.png",
        "Content/Images/skybox/posz.png", "Content/Images/skybox/negz.png",
    });

    const mesh_viking = try assets.loadMeshObj(&upload, "viking_room", @embedFile("viking_room.obj"));
    const mesh_sky = try assets.loadMeshCube(&upload, "sky_cube");

    try upload.end();

    // --- 3. Pipeline & Graphics State ---
    var camera = Camera.init(za.Vec3.new(1.8, 1.8, 1.8), za.Vec3.new(0.0, 0.5, 0.0), za.Vec3.up());
    var depth_texture = try Texture.initDepth(core, width, height);
    defer depth_texture.deinit(core);

    const sampler = try Texture.createSampler(core, .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
    });
    defer core.device.releaseSampler(sampler);

    const main_pipeline = try Pipeline.init(core, .{
        .vert_spec = .{ .filename = "TexturedQuadWithMatrix.vert", .uniform_buffer_count = 1 },
        .frag_spec = .{ .filename = "TexturedQuad.frag", .sampler_count = 1 },
        .depth_test = true,
    });
    defer main_pipeline.deinit(core);

    const sky_pipeline = try Pipeline.init(core, .{
        .vert_spec = .{ .filename = "Skybox.vert", .uniform_buffer_count = 1 },
        .frag_spec = .{ .filename = "Skybox.frag", .sampler_count = 1 },
        .depth_test = true,
        .depth_write = false,
    });
    defer sky_pipeline.deinit(core);

    // --- 4. Main Loop ---
    var start_ticks = sdl3.timer.getMillisecondsSinceInit();
    var quit = false;
    while (!quit) {
        const current_ticks = sdl3.timer.getMillisecondsSinceInit();
        const dt = @as(f32, @floatFromInt(current_ticks - start_ticks)) / 1000.0;
        start_ticks = current_ticks;

        camera.update(dt);

        if (try core.beginFrame()) |frame| {
            const renderpass = try frame.renderpass(.{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 }, depth_texture.handle);

            // Draw Skybox
            sky_pipeline.bind(renderpass);
            renderpass.bindFragmentSamplers(0, &.{.{ .texture = assets.getTexture(tex_sky).handle, .sampler = sampler }});

            const proj = camera.getProjMatrix(za.Vec2.new(@floatFromInt(width), @floatFromInt(height)));
            var view = camera.getViewMatrix();
            view.data[3][0] = 0;
            view.data[3][1] = 0;
            view.data[3][2] = 0;

            const sky_mvp = za.Mat4.mul(proj, view);
            frame.command_buffer.pushVertexUniformData(0, std.mem.asBytes(&sky_mvp));
            assets.getMesh(mesh_sky).draw(renderpass);

            // Draw Scene
            main_pipeline.bind(renderpass);
            renderpass.bindFragmentSamplers(0, &.{.{ .texture = assets.getTexture(tex_viking).handle, .sampler = sampler }});

            const mat = camera.getDescriptorMatrix(za.Vec2.new(@floatFromInt(width), @floatFromInt(height)));
            frame.command_buffer.pushVertexUniformData(0, std.mem.asBytes(&mat));
            assets.getMesh(mesh_viking).draw(renderpass);

            renderpass.end();
            try frame.end();
        }

        while (Core.poll()) |event| {
            camera.onEvent(event.toSdl(), core.window.value);
            switch (event) {
                .quit => quit = true,
                .window_resized => |ev| {
                    width = @intCast(ev.width);
                    height = @intCast(ev.height);
                    depth_texture.deinit(core);
                    depth_texture = try Texture.initDepth(core, width, height);
                },
                else => {},
            }
        }
    }
}
