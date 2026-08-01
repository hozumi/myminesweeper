const std = @import("std");
const rl = @import("raylib");

const grid_size = 25;
const tile_padding = 1;
const tile_size = grid_size - (tile_padding * 2);
// Board size in tiles. The monitor can only shrink this, never grow it.
const preferred_num_x_tile = 32;
const preferred_num_y_tile = 18;
// Space the window manager takes for the title bar, plus the macOS menu bar.
// raylib exposes no work-area query (GetMonitorWidth/Height report the whole
// video mode), so this has to be an allowance.
const window_chrome_height = 80;
// Frames to wait for a resize to reach the framebuffer callback. Neither
// XResizeWindow nor Cocoa's setFrame invokes it synchronously.
const resize_settle_frames = 10;
const bomb_ratio = 0.2;
const auto_flip_delay_ms = 10;
const tile_font_size = 14;
const target_fps = 60;
// A 3x3 window holds at most 9 bombs, so every label is a single digit. Kept as
// one table rather than a field per tile.
const digit_str = [_][:0]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };

const Tile = struct {
    is_bomb: bool,
    num_3x3_bomb: u8,
    flipped_at: ?i64,
    is_marked: bool,

    /// No field defaults: adding a field should break every construction site
    /// rather than silently pick a value. This is the one initial state.
    const fresh: Tile = .{
        .is_bomb = false,
        .num_3x3_bomb = 0,
        .flipped_at = null,
        .is_marked = false,
    };
};

const Board = struct {
    /// (num_x_tile + 2) * (num_y_tile + 2) tiles, row major, with the one-tile
    /// border that the 3x3 neighbour scans read. Sized to the board, so the
    /// extent and the storage cannot disagree.
    tiles: []Tile,
    num_x_tile: usize,
    num_y_tile: usize,

    const Self = @This();

    fn init(gpa: std.mem.Allocator, rand: *const std.Random, num_x_tile: usize, num_y_tile: usize) !Self {
        const tiles = try gpa.alloc(Tile, (num_x_tile + 2) * (num_y_tile + 2));
        // alloc hands back uninitialized memory, and the border is read by the
        // neighbour scans, so every tile including the border gets a value.
        @memset(tiles, .fresh);
        const self: Self = .{ .tiles = tiles, .num_x_tile = num_x_tile, .num_y_tile = num_y_tile };

        for (1..num_y_tile + 1) |y| {
            for (self.row(y)[1..][0..num_x_tile]) |*tile| {
                tile.is_bomb = rand.float(f64) < bomb_ratio;
            }
        }
        for (1..num_y_tile + 1) |y| {
            for (self.row(y)[1..][0..num_x_tile], 1..) |*tile, x| {
                var bomb_count: u8 = 0;
                for (y - 1..y + 2) |ry| {
                    for (self.row(ry)[x - 1 ..][0..3]) |*r_tile| {
                        if (r_tile.is_bomb) {
                            bomb_count += 1;
                        }
                    }
                }
                tile.num_3x3_bomb = bomb_count;
            }
        }
        return self;
    }

    fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        gpa.free(self.tiles);
    }

    fn stride(self: Self) usize {
        return self.num_x_tile + 2;
    }

    /// Row y of the storage, border included. y is 0 for the top border.
    fn row(self: Self, y: usize) []Tile {
        return self.tiles[y * self.stride() ..][0..self.stride()];
    }
};

fn pumpFrame() void {
    rl.beginDrawing();
    rl.clearBackground(.white);
    rl.endDrawing();
}

// Ratio between GLFW screen coordinates and logical pixels, measured rather
// than derived from the platform name. SetWindowSize takes screen coordinates,
// which are points on macOS and Wayland but physical pixels on X11, while
// GetScreenWidth always reports logical pixels. Asking for a known size and
// reading back what it became gives the factor without encoding which platform
// behaves how, so it also survives raylib changing its mind.
// GetRenderWidth is only ever written by the framebuffer callback, so it tells
// us whether the resize has actually landed yet.
fn measureWindowUnits() f32 {
    const probe = grid_size * 8;
    const render_before = rl.getRenderWidth();
    rl.setWindowSize(probe, probe);
    var frames: u32 = 0;
    while (rl.getRenderWidth() == render_before and frames < resize_settle_frames) : (frames += 1) {
        pumpFrame();
    }
    if (rl.getRenderWidth() == render_before) {
        // The probe never landed, so GetScreenWidth still holds what SetWindowSize
        // wrote and the ratio comes out as 1.0. Right for platforms that size
        // windows in logical units, too small by the content scale elsewhere.
        std.debug.print("WARNING: window unit probe did not settle, assuming logical\n", .{});
    }
    return @as(f32, probe) / @as(f32, @floatFromInt(@max(1, rl.getScreenWidth())));
}

fn toLogical(window_units_value: i32, window_units: f32) i32 {
    return @intFromFloat(@as(f32, @floatFromInt(window_units_value)) / window_units);
}

fn toWindowUnits(logical_value: i32, window_units: f32) i32 {
    return @intFromFloat(@as(f32, @floatFromInt(logical_value)) * window_units);
}

fn mouseOnTile(board: *Board, mouse_pos: rl.Vector2) ?*Tile {
    const mouse_x: usize = @intFromFloat(mouse_pos.x);
    const mouse_y: usize = @intFromFloat(mouse_pos.y);
    const tile_x = mouse_x / grid_size;
    const tile_y = mouse_y / grid_size;
    const x_gap = mouse_x % grid_size;
    const y_gap = mouse_y % grid_size;
    if (tile_x < board.num_x_tile
        and tile_y < board.num_y_tile
        // avoid edge click
        and (tile_padding < x_gap and x_gap < grid_size - tile_padding)
        and (tile_padding < y_gap and y_gap < grid_size - tile_padding)) {
        return &board.row(tile_y + 1)[tile_x + 1];
    } else {
        return null;
    }
}

pub fn main(init: std.process.Init) anyerror!void {
    const io = init.io;
    const rng_impl: std.Random.IoSource = .{ .io = io };
    const secureRand: std.Random = rng_impl.interface();
    // Initialization
    //--------------------------------------------------------------------------------------
    // GetMonitorWidth/Height need GLFW up, so the window has to exist before the
    // board size is known. Start hidden to keep the placeholder size off screen.
    rl.setConfigFlags(.{ .window_highdpi = true, .window_hidden = true });
    rl.initWindow(grid_size, grid_size, "myminesweeper");
    defer rl.closeWindow();

    const monitor = rl.getCurrentMonitor();
    const monitor_pos = rl.getMonitorPosition(monitor);
    const monitor_width = rl.getMonitorWidth(monitor);
    const monitor_height = rl.getMonitorHeight(monitor);
    const window_units = measureWindowUnits();
    // The monitor is a cap, not the target: shrink the board only when the
    // preferred size would not fit on screen.
    const avail_width = toLogical(monitor_width, window_units);
    const avail_height = toLogical(monitor_height - window_chrome_height, window_units);
    const num_x_tile: i32 = @max(1, @min(preferred_num_x_tile, @divTrunc(avail_width, grid_size)));
    const num_y_tile: i32 = @max(1, @min(preferred_num_y_tile, @divTrunc(avail_height, grid_size)));
    const window_width = toWindowUnits(num_x_tile * grid_size, window_units);
    const window_height = toWindowUnits(num_y_tile * grid_size, window_units);

    rl.setWindowSize(window_width, window_height);
    rl.setWindowPosition(
        @as(i32, @intFromFloat(monitor_pos.x)) + @divTrunc(monitor_width - window_width, 2),
        @as(i32, @intFromFloat(monitor_pos.y)) + window_chrome_height + @divTrunc(monitor_height - window_chrome_height - window_height, 2),
    );
    rl.clearWindowState(.{ .window_hidden = true });

    rl.setTargetFPS(target_fps);

    // Let the final resize land before the board is drawn, otherwise the first
    // frame uses the previous viewport.
    pumpFrame();

    // Digit centring offsets. MeasureText needs the default font, which
    // InitWindow has loaded by now. All digits share a width.
    const font_pos_x_adjust = @divTrunc(tile_size - rl.measureText("0", tile_font_size), 2);
    const font_pos_y_adjust = @divTrunc(tile_size - tile_font_size, 2);

    var board = try Board.init(init.gpa, &secureRand, @intCast(num_x_tile), @intCast(num_y_tile));
    defer board.deinit(init.gpa);
    //--------------------------------------------------------------------------------------

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        // Update variable
        const mouse_pos = rl.getMousePosition();
        if (rl.isMouseButtonReleased(.left)) {
            if (mouseOnTile(&board, mouse_pos)) |tile| {
                tile.flipped_at = std.Io.Clock.now(.awake, io).toMilliseconds();
            }
        } else if (rl.isMouseButtonReleased(.right)) {
            if (mouseOnTile(&board, mouse_pos)) |tile| {
                tile.is_marked = true;
            }
        }
        const now_ms = std.Io.Clock.now(.awake, io).toMilliseconds();
        for (1..board.num_y_tile + 1) |y| {
            auto_flip_x: for (board.row(y)[1..][0..board.num_x_tile], 1..) |*tile, x| {
                if (tile.flipped_at == null) {
                    for (y - 1..y + 2) |ry| {
                        for (board.row(ry)[x - 1 ..][0..3], x - 1..) |*r_tile, rx| {
                            if (x != rx or y != ry) {
                                if (r_tile.flipped_at) |flipped_at| {
                                    if (r_tile.num_3x3_bomb <= 0 and flipped_at + auto_flip_delay_ms < now_ms) {
                                        tile.flipped_at = now_ms;
                                        continue :auto_flip_x;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.white);

        for (0..board.num_y_tile) |y| {
            for (board.row(y + 1)[1..][0..board.num_x_tile], 0..) |*tile, x| {
                const inner_x: i32 = @intCast(x * grid_size + tile_padding);
                const inner_y: i32 = @intCast(y * grid_size + tile_padding);
                if (tile.flipped_at) |_| {
                    if (tile.is_bomb) {
                        rl.drawRectangle(inner_x, inner_y, tile_size, tile_size, .red);
                    } else {
                        rl.drawRectangle(inner_x, inner_y, tile_size, tile_size, .gray);
                    }
                    rl.drawText(digit_str[tile.num_3x3_bomb], inner_x + font_pos_x_adjust, inner_y + font_pos_y_adjust, tile_font_size, .black);
                } else if (tile.is_marked) {
                    if (tile.is_bomb) {
                        rl.drawRectangle(inner_x, inner_y, tile_size, tile_size, .sky_blue);
                    } else {
                        rl.drawRectangle(inner_x, inner_y, tile_size, tile_size, .dark_purple);
                    }
                } else {
                    rl.drawRectangle(inner_x, inner_y, tile_size, tile_size, .light_gray);
                }
            }
        }
        //----------------------------------------------------------------------------------
    }
}
