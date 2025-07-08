const std = @import("std");
const rl = @import("raylib");

const screen_width = 800;
const screen_height = 450;
const grid_size = 25;
const tile_padding = 1;
const tile_size = grid_size - (tile_padding * 2);
const num_x_tile = screen_width / grid_size;
const num_y_tile = screen_height / grid_size;
const bomb_ratio = 0.2;
const auto_flip_delay_micro = 10_000;
const tile_font_size = 14;
const target_fps = 60;

const Tile = struct {
    is_bomb: bool = false,
    num_3x3_bomb: u8 = 0,
    flipped_at: ?i64 = null,
    is_marked: bool = false,
    rect: rl.Rectangle = .{.x = 0, .y = 0, .width = 0, .height = 0},
    font_pos_x: i32 = 0,
    font_pos_y: i32 = 0,
};

const Board = struct {
    tile2d: [num_y_tile+2][num_x_tile+2]Tile,

    const Self = @This();

    const rand: std.Random = std.crypto.random;

    fn init(self: *Self) void {
        for (self.tile2d[1..][0..num_y_tile], 0..) |*line, y| {
            for (line[1..][0..num_x_tile], 0..) |*tile, x| {
                tile.* = .{};
                tile.is_bomb = rand.float(f64) < bomb_ratio;
                const inner_x = x * grid_size + tile_padding;
                const inner_y = y * grid_size + tile_padding;
                const r: rl.Rectangle = .{
                    .x = @floatFromInt(inner_x),
                    .y = @floatFromInt(inner_y),
                    .width = tile_size,
                    .height = tile_size,
                };
                tile.rect = r;
                tile.font_pos_x = @intCast(inner_x + 6);
                tile.font_pos_y = @intCast(inner_y + 4);
            }
        }
        for (self.tile2d[1..][0..num_y_tile], 1..) |*line, y| {
            for (line[1..][0..num_x_tile], 1..) |*tile, x| {
                var bomb_count: u8 = 0;
                for (self.tile2d[y-1..][0..3]) |r_line| {
                    for (r_line[x-1..][0..3]) |r_tile| {
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

fn mouseOnTile(board: *Board, mouse_pos: rl.Vector2) ?*Tile {
    const mouse_x: usize = @intFromFloat(mouse_pos.x);
    const mouse_y: usize = @intFromFloat(mouse_pos.y);
    const tile_x = mouse_x / grid_size;
    const tile_y = mouse_y / grid_size;
    const x_gap = mouse_x % grid_size;
    const y_gap = mouse_y % grid_size;
    if (tile_x <= num_x_tile
        and tile_y <= num_y_tile
        // avoid edge click
        and (tile_padding < x_gap and x_gap < grid_size - tile_padding)
        and (tile_padding < y_gap and y_gap < grid_size - tile_padding)) {
        return &board.tile2d[tile_y+1][tile_x+1];
    } else {
        return null;
    }
}

pub fn main() anyerror!void {
    // Initialization
    //--------------------------------------------------------------------------------------
    var board: Board = undefined;
    board.init();

    rl.initWindow(screen_width, screen_height, "myminesweeper");
    defer rl.closeWindow();

    rl.setTargetFPS(target_fps);
    //--------------------------------------------------------------------------------------

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        // Update variable
        const mouse_pos = rl.getMousePosition();
        if (rl.isMouseButtonReleased(.left)) {
            if (mouseOnTile(&board, mouse_pos)) |tile| {
                tile.flipped_at = std.time.microTimestamp();
            }
        } else if (rl.isMouseButtonReleased(.right)) {
            if (mouseOnTile(&board, mouse_pos)) |tile| {
                tile.is_marked = true;
            }
        }
        const now_micro = std.time.microTimestamp();
        for (board.tile2d[1..][0..num_y_tile], 1..) |*line, y| {
            auto_flip_x: for (line[1..][0..num_x_tile], 1..) |*tile, x| {
                if (tile.flipped_at == null) {
                    for (board.tile2d[y-1..][0..3], y-1..) |r_line, ry| {
                        for (r_line[x-1..][0..3], x-1..) |r_tile, rx| {
                            if (x != rx or y != ry) {
                                if (r_tile.flipped_at) |flipped_at| {
                                    if (r_tile.num_3x3_bomb <= 0 and flipped_at + auto_flip_delay_micro < now_micro) {
                                        tile.flipped_at = now_micro;
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

        for (board.tile2d[1..][0..num_y_tile]) |line| {
            for (line[1..][0..num_x_tile]) |tile| {
                if (tile.flipped_at) |_| {
                    if (tile.is_bomb) {
                        rl.drawRectangleRec(tile.rect, .red);
                    } else {
                        rl.drawRectangleRec(tile.rect, .gray);
                    }
                    var buf: [2]u8 = undefined;
                    const num_str = try std.fmt.bufPrintZ(&buf, comptime "{}", .{tile.num_3x3_bomb});
                    rl.drawText(num_str, tile.font_pos_x, tile.font_pos_y, tile_font_size, .black);
                } else if (tile.is_marked) {
                    if (tile.is_bomb) {
                        rl.drawRectangleRec(tile.rect, .sky_blue);
                    } else {
                        rl.drawRectangleRec(tile.rect, .dark_purple);
                    }
                } else {
                    rl.drawRectangleRec(tile.rect, .light_gray);
                }
            }
        }
        //----------------------------------------------------------------------------------
    }
}
