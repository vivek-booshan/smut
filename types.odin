package smut

import "core:sys/posix"

GUTTER_W :: 5

CONTROLC0 :: 32
DEL :: 127
BEL :: '\a'
TAB :: '\t'
LF :: '\n'
CR :: '\r'
ESC :: '\e'
BACKSPACE :: 8

Key :: enum u8 {
	NONE      = 0,
	LEADER    = 1, // ctrl a
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
	Select,
	Switch,
}

Glyph :: struct {
	char: rune,
	fg:   u32,
	bg:   u32,
	mode: GlyphMode,
}

BLACK :: 999
WHITE :: 999
DEFAULT_FG :: BLACK
DEFAULT_BG :: WHITE
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
	main_cursor_x:        int,
	main_cursor_y:        int,
	scroll_top:           int,
	scroll_bottom:        int,
	pty_cursor_x:         int,
	pty_cursor_y:         int,
	mode:                 Mode,

	// Selection state
	selection_start_y:    int,
	is_selecting:         bool,

	// Command Buffer
	cmd_buf:              [16]rune,
	cmd_idx:              int,

	// --- SCROLLBACK ---
	scrollback:           [dynamic][]Glyph,
	scroll_offset:        int,
	total_lines_scrolled: int,

	// --- PARSER STATE ---
	ansi_state:           AnsiState,
	parser_params:        [dynamic]int,
	parser_current_param: int,
	parser_has_param:     bool,
	parser_private:       rune, // stores '?' or '<' etc
	parser_intermediate:  rune, // stores '!' or '$' etc

	// Buffers
	utf8_buf:             [4]u8,
	utf8_len:             int,
	osc_buf:              [dynamic]u8,

	// OUTPUT BUFFER
	reply_buf:            [dynamic]u8,

	// ALTERNATE SCREEN BUFFER
	in_alt_screen:        bool,
	alt_grid:             [dynamic]Glyph,
	alt_cursor_x:         int,
	alt_cursor_y:         int,
	resize:               bool,
	current_attr:         Glyph,

	// Cursor State
	cursor_style:         int,
	cursor_visible:       bool,
}

