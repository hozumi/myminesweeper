const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

const grid_size = 25;
const tile_padding = 1;
const tile_size = grid_size - (tile_padding * 2);
// Board size in tiles. The monitor can only shrink this, never grow it, so it
// doubles as the tile2d bound.
const preferred_num_x_tile = 32;
const preferred_num_y_tile = 18;
// Space the window manager takes for the title bar, plus the macOS menu bar.
// raylib exposes no work-area query (GetMonitorWidth/Height report the whole
// video mode), so this has to be an allowance.
const window_chrome_height = 80;
const bomb_ratio = 0.2;
const auto_flip_delay_ms = 10;
const tile_font_size = 14;
const target_fps = 60;
// A 3x3 window holds at most 9 bombs, so every label is a single digit. Kept as
// one table rather than a field per tile.
const digit_str = [_][:0]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };

const Tile = struct {
    is_bomb: bool = false,
    num_3x3_bomb: u8 = 0,
    flipped_at: ?i64 = null,
    is_marked: bool = false,
};

const Board = struct {
    tile2d: [preferred_num_y_tile+2][preferred_num_x_tile+2]Tile,
    num_x_tile: usize,
    num_y_tile: usize,

    const Self = @This();

    fn init(self: *Self, rand: *const std.Random, num_x_tile: usize, num_y_tile: usize) void {
        self.num_x_tile = num_x_tile;
        self.num_y_tile = num_y_tile;
        // Every tile, not just the playfield: the 3x3 neighbour loops read the
        // one-tile border around it.
        for (&self.tile2d) |*line| {
            for (line) |*tile| {
                tile.* = .{};
            }
        }
        for (self.tile2d[1..][0..num_y_tile]) |*line| {
            for (line[1..][0..num_x_tile]) |*tile| {
                tile.is_bomb = rand.float(f64) < bomb_ratio;
            }
        }
        for (self.tile2d[1..][0..num_y_tile], 1..) |*line, y| {
            for (line[1..][0..num_x_tile], 1..) |*tile, x| {
                var bomb_count: u8 = 0;
                for (self.tile2d[y-1..][0..3]) |*r_line| {
                    for (r_line[x-1..][0..3]) |*r_tile| {
                        if (r_tile.is_bomb) {
                            bomb_count += 1;
                        }
                    }
                }
                tile.num_3x3_bomb = bomb_count;
            }
        }
    }
};

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
        return &board.tile2d[tile_y+1][tile_x+1];
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
    // Tile coordinates are logical pixels, but SetWindowSize/SetWindowPosition
    // and GetMonitorWidth/Height are GLFW screen coordinates: points on macOS,
    // where GLFW scales the framebuffer instead, and physical pixels on X11,
    // where raylib grows the window by the content scale. This is the factor
    // between the two.
    const window_units: f32 = if (builtin.os.tag == .macos) 1.0 else rl.getWindowScaleDPI().x;
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

    // Let the resize reach the framebuffer callback before the board is drawn,
    // otherwise the first frame uses the placeholder viewport.
    rl.beginDrawing();
    rl.clearBackground(.white);
    rl.endDrawing();

    // Digit centring offsets. MeasureText needs the default font, which
    // InitWindow has loaded by now. All digits share a width.
    const font_pos_x_adjust = @divTrunc(tile_size - rl.measureText("0", tile_font_size), 2);
    const font_pos_y_adjust = @divTrunc(tile_size - tile_font_size, 2);

    var board: Board = undefined;
    board.init(&secureRand, @intCast(num_x_tile), @intCast(num_y_tile));
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
        for (board.tile2d[1..][0..board.num_y_tile], 1..) |*line, y| {
            auto_flip_x: for (line[1..][0..board.num_x_tile], 1..) |*tile, x| {
                if (tile.flipped_at == null) {
                    for (board.tile2d[y-1..][0..3], y-1..) |*r_line, ry| {
                        for (r_line[x-1..][0..3], x-1..) |*r_tile, rx| {
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

        for (board.tile2d[1..][0..board.num_y_tile], 0..) |*line, y| {
            for (line[1..][0..board.num_x_tile], 0..) |*tile, x| {
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
