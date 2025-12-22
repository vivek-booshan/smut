package smut

import "core:sys/posix"

GUTTER_W :: 4

Screen :: struct {
	grid:              [dynamic]u8,
	width:             int,
	height:            int,
	cursor_x:          int,
	cursor_y:          int,
	pty_cursor_y:      int,
	mode:              enum {
		Normal,
		Insert,
	},

	// Selection state
	selection_start_y: int,
	is_selecting:      bool,

	// NEW: General Command Buffer for keystroke display
	cmd_buf:           [16]u8,
	cmd_idx:           int,

	// ANSI State Machine
	ansi_state:        enum {
		Ground,
		Escape,
		Bracket,
	},
	ansi_buf:          [32]u8,
	ansi_idx:          int,
}

