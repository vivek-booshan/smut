package smut

import "core:sys/posix"

GUTTER_W :: 5

CONTROLC0 :: 32
DEL :: 127
BEL :: 0x07
TAB :: 0x09
LF :: 0x0a // new line / line feed
CR :: 0x0d // carriage return
ESC :: 0x1b // 27
BACKSPACE :: 8
CUP :: 0x48 // cursor up
ED :: 0x4a // Erase in Display
SGR :: 0x6D // Set Graphic Rendition
SM :: 0x68 // Set Mode

Key :: enum u8 {
	NONE      = 0,
	CTRLB     = 2,
	BACKSPACE = 8,
	TAB       = 9,
	ENTER     = 13,
	ESCAPE    = 27,
	DELETE    = 127,
	ESCSEQ    = 0x1b,
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

	// ANSI State Machine
	ansi_state:           AnsiState,
	ansi_buf:             [64]u8,
	ansi_idx:             int,

	// String Buffer for OSC/DCS Sequences
	str_buf:              [256]rune,
	str_idx:              int,
	str_type:             rune,

	// ALTERNATE SCREEN BUFFER
	in_alt_screen:        bool,
	alt_grid:             [dynamic]Glyph,
	alt_cursor_x:         int,
	alt_cursor_y:         int,
	resize:               bool,
	current_attr:         Glyph,
}

