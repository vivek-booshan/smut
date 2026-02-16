package smut

GUTTER_W :: 6

KEY_ESC :: 27
KEY_LEADER :: 1

Action :: enum {
	None,
	CreateTab = 'c',
	NextTab = 'l',
	PrevTab = 'h',
	CloseTab = 'q',
	Redraw = 'R',
	Quit = 'Q',
	Insert = 'i',
	Motion = 'n',
	Visual = 's',
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

MouseMode :: enum {
	None,
	X10,
	ButtonEvent,
	AnyEvent,
}

Glyph :: struct {
	mode: GlyphMode,
	char: rune,
	fg:   u32,
	bg:   u32,
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
	pty_cursor_x:         int,
	pty_cursor_y:         int,
	scroll_top:           int,
	scroll_bottom:        int,
	mode:                 Mode,
	is_selecting:         bool,
	selection_start_x:    int,
	selection_start_y:    int,
	cmd_buf:              [16]rune,
	cmd_idx:              int,
	scrollback:           [dynamic][]Glyph,
	scroll_offset:        int,
	total_lines_scrolled: int,
	ansi_state:           AnsiState,
	parser_params:        [dynamic]int,
	parser_current_param: int,
	parser_has_param:     bool,
	parser_private:       rune,
	parser_intermediate:  rune,
	utf8_buf:             [4]u8,
	utf8_len:             int,
	osc_buf:              [dynamic]u8,
	reply_buf:            [dynamic]u8,
	in_alt_screen:        bool,
	alt_grid:             [dynamic]Glyph,
	main_cursor_x:        int,
	main_cursor_y:        int,
	current_attr:         Glyph,
	cursor_style:         int,
	cursor_visible:       bool,
	needs_redraw:         bool,
	mouse_mode:           MouseMode,
	input_buf:            [dynamic]u8,
}

