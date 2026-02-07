package smut

import "core:sys/posix"

GUTTER_W :: 5

Key :: enum u8 {
	NONE      = 0,
	LEADER    = 1,
	BACKSPACE = 8,
	TAB       = 9,
	ENTER     = 13,
	ESCAPE    = 27,
	DELETE    = 127,
	ESCSEQ    = 0x1b,
}

AnsiState :: enum {
	Ground,
	Escape,
	Escape_Intermediate,
	CSI_Entry,
	CSI_Param,
	CSI_Intermediate,
	CSI_Ignore,
	DCS_Entry,
	DCS_Param,
	DCS_Intermediate,
	DCS_Passthrough,
	DCS_Ignore,
	OSC_String,
	SOS_PM_APC_String,
}

Mode :: enum {
	Insert,
	Motion,
	Visual,
	Switch,
}

Glyph :: struct {
	char: rune,
	fg:   u32,
	bg:   u32,
	mode: GlyphMode,
}

DEFAULT_FG :: 999
DEFAULT_BG :: 999

GlyphMode :: bit_set[GlyphAttr;u16]
GlyphAttr :: enum u16 {
	Bold,
	Faint,
	Italic,
	Underline,
	Blink,
	Reverse,
	Invisible,
	StrikeThrough,
	TrueColorFG,
	TrueColorBG,
}

Screen :: struct {
	grid:                 [dynamic]Glyph,
	dirty:                [dynamic]bool,
	width:                int,
	height:               int,
	cursor_x:             int,
	cursor_y:             int,

	// PTY State
	main_cursor_x:        int,
	main_cursor_y:        int,
	scroll_top:           int,
	scroll_bottom:        int,
	pty_cursor_x:         int,
	pty_cursor_y:         int,
	mode:                 Mode,

	// Selection
	selection_start_x:    int,
	selection_start_y:    int,
	is_selecting:         bool,

	// Command State
	cmd_buf:              [16]rune,
	cmd_idx:              int,

	// History
	scrollback:           [dynamic][]Glyph,
	scroll_offset:        int,
	total_lines_scrolled: int,

	// Parser
	ansi_state:           AnsiState,
	parser_params:        [dynamic]int,
	parser_current_param: int,
	parser_has_param:     bool,
	parser_private:       rune,
	parser_intermediate:  rune,

	// Buffers
	utf8_buf:             [4]u8,
	utf8_len:             int,
	osc_buf:              [dynamic]u8,
	reply_buf:            [dynamic]u8,

	// Alt Screen
	in_alt_screen:        bool,
	alt_grid:             [dynamic]Glyph,
	alt_cursor_x:         int,
	alt_cursor_y:         int,

	// Cursor
	cursor_style:         int,
	cursor_visible:       bool,

	// Stuff
	resize:               bool,
	current_attr:         Glyph,
}

