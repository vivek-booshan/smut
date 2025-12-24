package smut

import "core:sys/posix"

GUTTER_W :: 4

Key :: enum u8 {
	NONE      = 0,
	CTRLB     = 2,
	BACKSPACE = 8,
	TAB       = 9,
	ENTER     = 13,
	ESCAPE    = 27,
	DELETE    = 127,
}

AnsiState :: enum {
	Ground,
	Escape, // After ESC
	CSI, // After ESC [
	STR, // After ESC ] (OSC), ESC P (DCS), ESC ^ (PM), ESC _ (APC)
	Charset, // After ESC ( or ESC )
	Esc_Test, // After ESC #
}

Mode :: enum {
	Insert,
	Motion,
	Select,
	Switch,
}

Screen :: struct {
	grid:                 [dynamic]u8,
	dirty:                [dynamic]bool,
	width:                int,
	height:               int,
	cursor_x:             int,
	cursor_y:             int,
	pty_cursor_x:         int,
	pty_cursor_y:         int,
	mode:                 Mode,

	// Selection state
	selection_start_y:    int,
	is_selecting:         bool,

	// Command Buffer
	cmd_buf:              [16]u8,
	cmd_idx:              int,

	// --- SCROLLBACK ---
	scrollback:           [dynamic][]u8,
	scroll_offset:        int,
	total_lines_scrolled: int,

	// ANSI State Machine
	ansi_state:           AnsiState,
	ansi_buf:             [64]u8,
	ansi_idx:             int,

	// String Buffer for OSC/DCS Sequences
	str_buf:              [256]u8,
	str_idx:              int,
	str_type:             u8,

	// ALTERNATE SCREEN BUFFER
	in_alt_screen:        bool,
	alt_grid:             [dynamic]u8,
	alt_cursor_x:         int,
	alt_cursor_y:         int,
	resize:               bool,
}

