package smut

import "core:sys/posix"

GUTTER_W :: 4

Screen :: struct {
	grid:              [dynamic]u8,
	width:             int,
	height:            int,
	cursor_x:          int,
	cursor_y:          int,
	mode:              enum {
		Normal,
		Insert,
	},

	// --- New Fields ---
	selection_start_y: int, // Tracks where 'x' or 'X' started
	is_selecting:      bool, // Whether we are currently highlighting a range
	cmd_digit_buf:     [8]u8, // Stores digits for 10j, 5x, etc.
	cmd_digit_idx:     int,
	ansi_state:        enum {
		Ground,
		Escape,
		Bracket,
	},
	ansi_buf:          [32]u8,
	ansi_idx:          int,
}

screen: Screen
should_resize := true

