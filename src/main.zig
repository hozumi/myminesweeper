const std = @import("std");
const rl = @import("raylib");

const screen_width = 800;
const screen_height = 450;
const grid_pixel = 25;
const inner_grid_padding = 1;
const inner_grid_pixel = grid_pixel - (inner_grid_padding * 2);
const num_x = screen_width / grid_pixel;
const num_y = screen_height / grid_pixel;
const bomb_ratio = 0.2;
const auto_flip_delay_micro = 10_000;
const tile_font_size = 14;
const target_fps = 60;

const Tile = struct {
    is_bomb: bool = false,
    num_neighbour_bomb: u8 = 0,
    flipped_at: ?i64 = null,
    is_marked: bool = false,
    rect: rl.Rectangle = .{.x = 0, .y = 0, .width = 0, .height = 0},
    font_pos_x: i32 = 0,
    font_pos_y: i32 = 0,
};

const Board = struct {
    area: [num_y+2][num_x+2]Tile,

    const Self = @This();

    const rand: std.Random = std.crypto.random;

    fn init(self: *Self) void {
        for (self.area[1..][0..num_y], 0..) |*line, y| {
            for (line[1..][0..num_x], 0..) |*item, x| {
                item.* = .{};
                item.is_bomb = rand.float(f64) < bomb_ratio;
                const inner_x = x * grid_pixel + inner_grid_padding;
                const inner_y = y * grid_pixel + inner_grid_padding;
                const r: rl.Rectangle = .{
                    .x = @floatFromInt(inner_x),
                    .y = @floatFromInt(inner_y),
                    .width = inner_grid_pixel,
                    .height = inner_grid_pixel,
                };
                item.rect = r;
                item.font_pos_x = @intCast(inner_x + 6);
                item.font_pos_y = @intCast(inner_y + 4);
            }
        }
        for (self.area[1..][0..num_y], 1..) |*line, y| {
            for (line[1..][0..num_x], 1..) |*item, x| {
                var bomb_count: u8 = 0;
                for (self.area[y-1..][0..3]) |r_line| {
                    for (r_line[x-1..][0..3]) |r_item| {
                        if (r_item.is_bomb) {
                            bomb_count += 1;
                        }
                    }
                }
                item.num_neighbour_bomb = bomb_count;
            }
        }
    }
};

fn mouseOnTile(board: *Board, mousePos: rl.Vector2) ?*Tile {
    for (board.area[1..][0..num_y]) |*line| {
        for (line[1..][0..num_x]) |*item| {
            if (item.rect.x <= mousePos.x
                and mousePos.x <= item.rect.x + item.rect.width
                and item.rect.y <= mousePos.y
                and mousePos.y <= item.rect.y + item.rect.height) {
                return item;
            }
        }
    }
    return null;
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
        const mousePos = rl.getMousePosition();
        if (rl.isMouseButtonReleased(.left)) {
            if (mouseOnTile(&board, mousePos)) |item| {
                item.flipped_at = std.time.microTimestamp();
            }
        } else if (rl.isMouseButtonReleased(.right)) {
            if (mouseOnTile(&board, mousePos)) |item| {
                item.is_marked = true;
            }
        }
        const now_micro = std.time.microTimestamp();
        for (board.area[1..][0..num_y], 1..) |*line, y| {
            auto_flip_x: for (line[1..][0..num_x], 1..) |*item, x| {
                if (item.flipped_at == null) {
                    for (board.area[y-1..][0..3], y-1..) |r_line, ry| {
                        for (r_line[x-1..][0..3], x-1..) |r_item, rx| {
                            if (x != rx or y != ry) {
                                if (r_item.flipped_at) |flipped_at| {
                                    if (r_item.num_neighbour_bomb <= 0 and flipped_at + auto_flip_delay_micro < now_micro) {
                                        item.flipped_at = now_micro;
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

        for (board.area[1..][0..num_y]) |line| {
            for (line[1..][0..num_x]) |item| {
                if (item.flipped_at) |_| {
                    if (item.is_bomb) {
                        rl.drawRectangleRec(item.rect, .red);
                    } else {
                        rl.drawRectangleRec(item.rect, .gray);
                    }
                    var buf: [2]u8 = undefined;
                    const num_str = try std.fmt.bufPrintZ(&buf, comptime "{}", .{item.num_neighbour_bomb});
                    rl.drawText(num_str, item.font_pos_x, item.font_pos_y, tile_font_size, .black);
                } else if (item.is_marked) {
                    if (item.is_bomb) {
                        rl.drawRectangleRec(item.rect, .sky_blue);
                    } else {
                        rl.drawRectangleRec(item.rect, .dark_purple);
                    }
                } else {
                    rl.drawRectangleRec(item.rect, .light_gray);
                }
            }
        }
        //----------------------------------------------------------------------------------
    }
}
