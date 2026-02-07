package smut

import "core:fmt"
import "core:unicode/utf8"

ALT_SCREEN :: 1049

parser_clear :: proc(s: ^Screen) {
	clear(&s.parser_params)
	s.parser_current_param = 0
	s.parser_has_param = false
	s.parser_private = 0
	s.parser_intermediate = 0
}

parser_collect_param :: proc(s: ^Screen, b: u8) {
	if !s.parser_has_param {
		s.parser_has_param = true
		s.parser_current_param = 0
	}
	s.parser_current_param = (s.parser_current_param * 10) + int(b - '0')
}

parser_push_param :: proc(s: ^Screen) {
	if s.parser_has_param {
		append(&s.parser_params, s.parser_current_param)
	} else {
		append(&s.parser_params, 0)
	}
	s.parser_current_param = 0
	s.parser_has_param = false
}

handle_utf8_input :: proc(s: ^Screen, b: u8) {
	if s.utf8_len < len(s.utf8_buf) {
		s.utf8_buf[s.utf8_len] = b
		s.utf8_len += 1
	}

	r, width := utf8.decode_rune(s.utf8_buf[:s.utf8_len])
	if r != utf8.RUNE_ERROR {
		write_rune_to_grid(s, r, s.in_alt_screen ? s.width : s.width - GUTTER_W)
		s.utf8_len = 0
	} else if width == 0 || width == 1 && s.utf8_len >= 4 {
		// Invalid or stuck, reset
		s.utf8_len = 0
	}
}


handle_ansi_byte :: proc(s: ^Screen, b: u8) {
	// 1. High Priority Control Characters (Executable anywhere)
	if b == 0x18 || b == 0x1a { 	// CAN or SUB
		s.ansi_state = .Ground
		return
	}

	#partial switch s.ansi_state {
	case .Ground:
		if b == ESC {
			s.ansi_state = .Escape
		} else if b < 32 {
			handle_control_char(s, rune(b), s.in_alt_screen ? s.width : s.width - GUTTER_W)
		} else {
			handle_utf8_input(s, b)
		}

	case .Escape:
		parser_clear(s)
		switch b {
		case '[':
			s.ansi_state = .CSI_Entry
		case ']', 'P', '^', '_':
			clear(&s.osc_buf)
			if b == 'P' do s.ansi_state = .DCS_Entry
			else if b == ']' do s.ansi_state = .OSC_String
			else do s.ansi_state = .SOS_PM_APC_String
		case ' ', '#', '%', '(', ')', '*', '+', '-', '.', '/':
			s.parser_intermediate = rune(b)
			s.ansi_state = .Escape_Intermediate
		case:
			handle_esc_dispatch(s, b)
			s.ansi_state = .Ground
		}

	case .Escape_Intermediate:
		if b >= 0x30 && b <= 0x7E {
			handle_esc_dispatch(s, b)
			s.ansi_state = .Ground
		}

	case .CSI_Entry:
		switch b {
		case '0' ..= '9':
			parser_collect_param(s, b)
			s.ansi_state = .CSI_Param
		case ';', ':':
			parser_push_param(s)
			s.ansi_state = .CSI_Param
		case '<', '=', '>', '?':
			s.parser_private = rune(b)
			s.ansi_state = .CSI_Param
		case 0x40 ..= 0x7E:
			handle_csi_dispatch(s, b)
			s.ansi_state = .Ground
		case:
			if b >= 0x20 && b <= 0x2F {
				s.parser_intermediate = rune(b)
				s.ansi_state = .CSI_Intermediate
			} else {
				s.ansi_state = .CSI_Ignore
			}
		}

	case .CSI_Param:
		switch b {
		case '0' ..= '9':
			parser_collect_param(s, b)
		case ';', ':':
			parser_push_param(s)
		case 0x40 ..= 0x7E:
			parser_push_param(s)
			handle_csi_dispatch(s, b)
			s.ansi_state = .Ground
		case:
			if b >= 0x20 && b <= 0x2F {
				parser_push_param(s)
				s.parser_intermediate = rune(b)
				s.ansi_state = .CSI_Intermediate
			} else {
				s.ansi_state = .CSI_Ignore
			}
		}

	case .CSI_Intermediate:
		switch b {
		case 0x40 ..= 0x7E:
			handle_csi_dispatch(s, b)
			s.ansi_state = .Ground
		case:
			if !(b >= 0x20 && b <= 0x2F) {
				s.ansi_state = .CSI_Ignore
			}
		}

	case .CSI_Ignore:
		if b >= 0x40 && b <= 0x7E {
			s.ansi_state = .Ground
		}

	case .OSC_String:
		if b == BEL {
			handle_osc_dispatch(s)
			s.ansi_state = .Ground
		} else if b == ESC { 	// Possible ST (ESC \)
			handle_osc_dispatch(s)
			s.ansi_state = .Escape
		} else {
			append(&s.osc_buf, b)
		}

	case:
		// Fallback for DCS/SOS states not fully implemented
		if b == BEL || b == ESC {
			s.ansi_state = .Ground
		}
	}
}


handle_esc_dispatch :: proc(s: ^Screen, b: u8) {
	switch b {
	case 'c': // RIS
	// NOTE(Vivek): Full Reset logic would go here
	case 'D':
		// IND
		handle_control_char(s, '\n', s.width)
	case 'M':
		// RI
		s.cursor_y = max(0, s.cursor_y - 1)
	}
}

handle_osc_dispatch :: proc(s: ^Screen) {
	// NOTE(Vivek): Window Title handling etc.
}

handle_csi_dispatch :: proc(s: ^Screen, final: u8) {
	params := s.parser_params[:]

	get_p :: proc(p: []int, idx: int, def: int) -> int {
		if idx < len(p) {
			val := p[idx]
			if val == 0 do return def
			return val
		}
		return def
	}

	switch final {
	case 'c':
		// DA - Device Status Report
		if s.parser_private == '>' {
			// Secondary Device Attribute 
			// Request: CSI > c
			// Response: CSI > 41 ; 350 ; 0 c (VT420 / xterm compatible)
			resp := "\x1b[>41;350;0c"
			append(&s.reply_buf, ..transmute([]u8)resp)
		} else {
			// Primary Device Attribute
			// Request: CSI c
			// Response: CSI ? 62 ; c (VT220)
			resp := "\x1b[?62;c"
			append(&s.reply_buf, ..transmute([]u8)resp)
		}
	case 'n':
		// DSR - Device Status Report
		status := get_p(params, 0, 0)
		switch status {
		case 5:
			// Report Status OK
			resp := "\x1b[0n"
			append(&s.reply_buf, ..transmute([]u8)resp)
		case 6:
			// CPR - Cursor Position Report
			r := s.cursor_y + 1
			c := s.cursor_x + 1
			resp := fmt.tprintf("\x1b[%d;%dR", r, c)
			append(&s.reply_buf, ..transmute([]u8)resp)
		}
	case '@':
		// ICH - Insert Character
		handle_insert_char(s, get_p(params, 0, 1))
	case 'A':
		// CUU
		dist := get_p(params, 0, 1)
		s.cursor_y = max(0, s.cursor_y - dist)
	case 'B':
		// CUD
		dist := get_p(params, 0, 1)
		limit := s.scroll_bottom > 0 ? s.scroll_bottom : s.height - 2
		s.cursor_y = min(limit, s.cursor_y + dist)
	case 'C':
		// CUF
		dist := get_p(params, 0, 1)
		s.cursor_x = min(s.width - 1, s.cursor_x + dist)
	case 'D':
		// CUB
		dist := get_p(params, 0, 1)
		s.cursor_x = max(0, s.cursor_x - dist)
	case 'd':
		// VPA - Vertical Position Absolute
		r := get_p(params, 0, 1)
		s.cursor_y = clamp(r - 1, 0, s.height - 1)
	case 'G':
		// CHA - Cursor Horizontal Absolute
		c := get_p(params, 0, 1)
		s.cursor_x = clamp(c - 1, 0, s.width - 1)
	case 'H', 'f':
		// CUP
		r := get_p(params, 0, 1)
		c := get_p(params, 1, 1)
		s.cursor_y = clamp(r - 1, 0, s.height - 2)
		s.cursor_x = clamp(c - 1, 0, s.width - 1)
	case 'J':
		// ED
		handle_erase_in_display(s, get_p(params, 0, 0))
	case 'K':
		// EL
		handle_erase_in_line(s, get_p(params, 0, 0))
	case 'L':
		// IL
		handle_insert_lines(s, get_p(params, 0, 1))
	case 'M':
		// DL
		if s.parser_private == '<' {
			// Mouse Release
		} else {
			handle_delete_lines(s, get_p(params, 0, 1))
		}
	case 'P':
		// DCH - Delete Character
		handle_delete_char(s, get_p(params, 0, 1))
	case 'S':
		// SU - Scroll Up
		handle_scroll_up(s, get_p(params, 0, 1))
	case 'T':
		// SD - Scroll Down
		handle_scroll_down(s, get_p(params, 0, 1))
	case 'X':
		// ECH - Erase Character
		handle_erase_char(s, get_p(params, 0, 1))
	case 'm':
		// SGR
		handle_sgr_sequence(s, params)
	case 'h':
		// SM
		if s.parser_private == '?' {
			mode := get_p(params, 0, 0)
			if mode == ALT_SCREEN && !s.in_alt_screen {
				s.in_alt_screen = true
				s.main_cursor_x = s.cursor_x
				s.main_cursor_y = s.cursor_y
				s.scroll_top = 0
				s.scroll_bottom = s.height - 1
				s.cursor_x, s.cursor_y = 0, 0
				s.pty_cursor_x, s.pty_cursor_y = 0, 0
				blank := blank_glyph(s)
				for i in 0 ..< len(s.alt_grid) {s.alt_grid[i] = blank}
				for i in 0 ..< len(s.dirty) {s.dirty[i] = true}
				resize_screen(s, master_fd)
			} else if mode == 25 {
				s.cursor_visible = true
			}
		}
	case 'l':
		// RM
		if s.parser_private == '?' {
			mode := get_p(params, 0, 0)
			if mode == ALT_SCREEN && s.in_alt_screen {
				s.in_alt_screen = false
				s.cursor_x = s.main_cursor_x
				s.cursor_y = s.main_cursor_y
				for i in 0 ..< s.height {s.dirty[i] = true}
				resize_screen(s, master_fd)
			} else if mode == 25 {
				s.cursor_visible = false
			}
		}
	case 'q':
		// DECSUSR - Set Cursor Style
		// Sequence : CSI Ps SP q
		if s.parser_intermediate == ' ' {
			style := get_p(params, 0, 0)
			s.cursor_style = style
		}
	case 'r':
		// DECSTBM
		top := get_p(params, 0, 1)
		bot := get_p(params, 1, s.height)
		s.scroll_top = clamp(top - 1, 0, s.height - 1)
		s.scroll_bottom = clamp(bot - 1, 0, s.height - 1)
		s.cursor_x, s.cursor_y = 0, 0
	}

	s.pty_cursor_x = s.cursor_x
	s.pty_cursor_y = s.cursor_y
}

// --- Text Modification Helpers ---

handle_insert_char :: proc(s: ^Screen, n: int) {
	if n <= 0 do return
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	row_start := s.cursor_y * s.width

	limit := min(n, s.width - s.cursor_x)
	if limit <= 0 do return

	src := row_start + s.cursor_x
	dst := row_start + s.cursor_x + limit
	count := s.width - (s.cursor_x + limit)

	if count > 0 {
		copy(grid[dst:dst + count], grid[src:src + count])
	}

	blank := blank_glyph(s)
	for i in 0 ..< limit {
		grid[src + i] = blank
	}
	s.dirty[s.cursor_y] = true
}

handle_delete_char :: proc(s: ^Screen, n: int) {
	if n <= 0 do return
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	row_start := s.cursor_y * s.width

	limit := min(n, s.width - s.cursor_x)
	if limit <= 0 do return

	src := row_start + s.cursor_x + limit
	dst := row_start + s.cursor_x
	count := s.width - (s.cursor_x + limit)

	if count > 0 {
		copy(grid[dst:dst + count], grid[src:src + count])
	}

	blank := blank_glyph(s)
	clear_start := row_start + s.width - limit
	for i in 0 ..< limit {
		grid[clear_start + i] = blank
	}
	s.dirty[s.cursor_y] = true
}

handle_erase_char :: proc(s: ^Screen, n: int) {
	if n <= 0 do return
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	row_start := s.cursor_y * s.width
	limit := min(n, s.width - s.cursor_x)

	blank := blank_glyph(s)
	for i in 0 ..< limit {
		grid[row_start + s.cursor_x + i] = blank
	}
	s.dirty[s.cursor_y] = true
}

// --- Line Modification Helpers ---

handle_insert_lines :: proc(s: ^Screen, n: int) {
	if s.cursor_y < s.scroll_top || s.cursor_y > s.scroll_bottom do return
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	num := min(n, s.scroll_bottom - s.cursor_y + 1)

	for y := s.scroll_bottom; y >= s.cursor_y + num; y -= 1 {
		dst := y * s.width
		src := (y - num) * s.width
		copy(grid[dst:dst + s.width], grid[src:src + s.width])
		s.dirty[y] = true
	}

	blank := blank_glyph(s)
	for y := s.cursor_y; y < s.cursor_y + num; y += 1 {
		start := y * s.width
		for x in 0 ..< s.width {grid[start + x] = blank}
		s.dirty[y] = true
	}
}

handle_delete_lines :: proc(s: ^Screen, n: int) {
	if s.cursor_y < s.scroll_top || s.cursor_y > s.scroll_bottom do return
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	num := min(n, s.scroll_bottom - s.cursor_y + 1)

	for y := s.cursor_y; y <= s.scroll_bottom - num; y += 1 {
		dst := y * s.width
		src := (y + num) * s.width
		copy(grid[dst:dst + s.width], grid[src:src + s.width])
		s.dirty[y] = true
	}

	blank := blank_glyph(s)
	for y := s.scroll_bottom - num + 1; y <= s.scroll_bottom; y += 1 {
		start := y * s.width
		for x in 0 ..< s.width {grid[start + x] = blank}
		s.dirty[y] = true
	}
}

handle_scroll_up :: proc(s: ^Screen, n: int) {
	old_y := s.cursor_y
	s.cursor_y = s.scroll_top
	handle_delete_lines(s, n)
	s.cursor_y = old_y
}

handle_scroll_down :: proc(s: ^Screen, n: int) {
	old_y := s.cursor_y
	s.cursor_y = s.scroll_top
	handle_insert_lines(s, n)
	s.cursor_y = old_y
}

handle_erase_in_line :: proc(s: ^Screen, mode: int) {
	row_start := s.cursor_y * s.width
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	blank := blank_glyph(s)

	switch mode {
	case 0:
		// Cursor to end
		for x in s.cursor_x ..< s.width {grid[row_start + x] = blank}
	case 1:
		// Start to cursor
		for x in 0 ..< s.cursor_x + 1 {grid[row_start + x] = blank}
	case 2:
		// Whole line
		for x in 0 ..< s.width {grid[row_start + x] = blank}
	}
	s.dirty[s.cursor_y] = true
}

handle_erase_in_display :: proc(s: ^Screen, mode: int) {
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	blank := blank_glyph(s)
	switch mode {
	case 0:
		// Cursor to end of screen
		handle_erase_in_line(s, 0)
		for y in s.cursor_y + 1 ..< s.height - 1 {
			for x in 0 ..< s.width {grid[y * s.width + x] = blank}
			s.dirty[y] = true
		}
	case 2:
		// Whole screen
		for i in 0 ..< len(grid) {grid[i] = blank}
		for i in 0 ..< s.height {s.dirty[i] = true}
	}
}

blank_glyph :: proc(s: ^Screen) -> Glyph {
	return Glyph {
		char = 0,
		fg = s.current_attr.fg,
		bg = s.current_attr.bg,
		mode = s.current_attr.mode,
	}
}

