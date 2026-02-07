package smut

SCROLLUP :: 64
SCROLLDOWN :: 65

MAX_PARAMS :: 16

SGR_Code :: enum int {
	RESET          = 0,
	BOLD           = 1,
	FAINT          = 2,
	ITALIC         = 3,
	UNDERLINE      = 4,
	BLINK          = 5,
	REVERSE        = 7,
	INVISIBLE      = 8,
	STRIKE         = 9,
	NORMAL_WEIGHT  = 22,
	NOT_ITALIC     = 23,
	NOT_UNDERLINED = 24,
	NOT_BLINKING   = 25,
	NOT_REVERSED   = 27,
	NOT_INVISIBLE  = 28,
	NOT_STRUCK     = 29,
	FG_EXTENDED    = 38,
	FG_DEFAULT     = 39,
	BG_EXTENDED    = 48,
	BG_DEFAULT     = 49,
}

ansi_parser :: proc(s: ^Screen) -> (int, [MAX_PARAMS]int) {
	params: [MAX_PARAMS]int
	p_idx := 0
	current_val := 0
	has_val := false

	for i in 0 ..< s.ansi_idx {
		char := s.ansi_buf[i]
		if char >= '0' && char <= '9' {
			current_val = (current_val * 10) + int(char - '0')
			has_val = true
		} else if char == ';' || char == ':' {
			if p_idx < len(params) {
				params[p_idx] = current_val
				p_idx += 1
			}
			current_val = 0
			has_val = false
		}
	}

	// Finalize the last parameter
	if has_val && p_idx < len(params) {
		params[p_idx] = current_val
		p_idx += 1
	}

	return p_idx, params
}

handle_csi_sequence :: proc(s: ^Screen, b: u8) {

	// Switch
	p_idx, params := ansi_parser(s)
	// SGR mouse protocol : \x1b[<button;x;yM
	is_mouse := s.ansi_idx > 0 && s.ansi_buf[0] == '<'
	// Dispatcher
	switch b {
	case 'H', 'f':
		// CUP - Cursor Position (Absolute)
		// Standard: \x1b[row;colH (1-based)
		r := p_idx > 0 ? params[0] : 1
		c := p_idx > 1 ? params[1] : 1

		s.cursor_y = clamp(r - 1, 0, s.height - 2)
		s.cursor_x = clamp(c - 1, 0, s.width - 1)

	case 'A':
		// CUU - Cursor Up
		dist := p_idx > 0 ? max(1, params[0]) : 1
		s.cursor_y = max(0, s.cursor_y - dist)

	case 'B':
		// CUD - Cursor Down
		dist := p_idx > 0 ? max(1, params[0]) : 1
		limit := s.scroll_bottom > 0 ? s.scroll_bottom : s.height - 2
		s.cursor_y = min(limit, s.cursor_y + dist)

	case 'C':
		// CUF - Cursor Forward
		dist := p_idx > 0 ? max(1, params[0]) : 1
		s.cursor_x = min(s.width - 1, s.cursor_x + dist)

	case 'D':
		// CUB - Cursor Back
		dist := p_idx > 0 ? max(1, params[0]) : 1
		s.cursor_x = max(0, s.cursor_x - dist)

	case 'J':
		// ED - Erase in Display
		mode := p_idx > 0 ? params[0] : 0
		handle_erase_in_display(s, mode)

	case 'K':
		// EL - Erase in Line
		mode := p_idx > 0 ? params[0] : 0
		handle_erase_in_line(s, mode)
	case 'h':
		// DEC Private Mode Set
		blank := blank_glyph(s)
		is_private := s.ansi_idx > 0 && s.ansi_buf[0] == '?'
		if is_private && params[0] == 1049 {
			if !s.in_alt_screen {
				s.in_alt_screen = true

				s.main_cursor_x = s.cursor_x
				s.main_cursor_y = s.cursor_y

				s.scroll_top = 0
				s.scroll_bottom = s.height - 1

				s.cursor_x, s.cursor_y = 0, 0
				s.pty_cursor_x, s.pty_cursor_y = 0, 0

				for i in 0 ..< len(s.alt_grid) {s.alt_grid[i] = blank}
				for i in 0 ..< len(s.dirty) {s.dirty[i] = true}
			}
		}
	case 'l':
		// DEC Private Mode Reset
		if params[0] == 1049 {
			if s.in_alt_screen {
				s.in_alt_screen = false
				s.cursor_x = s.main_cursor_x
				s.cursor_y = s.main_cursor_y
				for i in 0 ..< s.height {s.dirty[i] = true}
			}
		}
	case 'r':
		// DECSTBM - set scrolling region
		top := p_idx > 0 ? params[0] : 1
		bot := p_idx > 1 ? params[1] : s.height

		s.scroll_top = clamp(top - 1, 0, s.height - 1)
		s.scroll_bottom = clamp(bot - 1, 0, s.height - 1)

		s.cursor_x, s.cursor_y = 0, 0
	case 'L':
		// IL - Insert Line
		num := p_idx > 0 ? max(1, params[0]) : 1
		handle_insert_lines(s, num)
	case 'M':
		// DL - Delete Line
		if is_mouse && p_idx >= 3 {
			button := params[0]
			if button == SCROLLUP {
				s.scroll_offset = min(len(s.scrollback), s.scroll_offset + 3)
			} else if button == SCROLLDOWN {
				s.scroll_offset = max(0, s.scroll_offset - 3)
			}
		} else {
			num := p_idx > 0 ? max(1, params[0]) : 1
			handle_delete_lines(s, num)
		}
	case SGR:
		// SGR - Select Graphic Rendition
		if is_mouse && p_idx >= 3 {
			button := params[0]
			if button == SCROLLUP {
				s.scroll_offset = min(len(s.scrollback), s.scroll_offset + 3)
			} else if button == SCROLLDOWN {
				s.scroll_offset = max(0, s.scroll_offset - 3)
			}
		} else {
			handle_sgr_sequence(s, p_idx, params)
		}
	}
	s.pty_cursor_x = s.cursor_x
	s.pty_cursor_y = s.cursor_y
}


handle_sgr_sequence :: proc(s: ^Screen, p_idx: int, params: [MAX_PARAMS]int) {
	if p_idx == 0 {
		reset_attr(s)
		return
	}

	i := 0
	for i < p_idx {
		val := params[i]

		// Handle Offset-based colors first
		switch val {
		case 30 ..= 37:
			s.current_attr.fg = u32(val - 30)
			s.current_attr.mode -= {.TrueColorFG}
			i += 1
			continue
		case 90 ..= 97:
			s.current_attr.fg = u32(val - 90 + 8)
			s.current_attr.mode -= {.TrueColorFG}
			i += 1
			continue
		case 40 ..= 47:
			s.current_attr.bg = u32(val - 40)
			s.current_attr.mode -= {.TrueColorBG}
			i += 1
			continue
		case 100 ..= 107:
			s.current_attr.bg = u32(val - 100 + 8)
			s.current_attr.mode -= {.TrueColorBG}
			i += 1
			continue
		}

		// Handle named SGR codes
		code := SGR_Code(val)
		switch code {
		case .RESET:
			reset_attr(s)
		case .BOLD:
			s.current_attr.mode += {.Bold}
		case .FAINT:
			s.current_attr.mode += {.Faint}
		case .ITALIC:
			s.current_attr.mode += {.Italic}
		case .UNDERLINE:
			s.current_attr.mode += {.Underline}
		case .BLINK:
			s.current_attr.mode += {.Blink}
		case .REVERSE:
			s.current_attr.mode += {.Reverse}
		case .INVISIBLE:
			s.current_attr.mode += {.Invisible}
		case .STRIKE:
			s.current_attr.mode += {.StrikeThrough}

		case .NORMAL_WEIGHT:
			s.current_attr.mode -= {.Bold, .Faint}
		case .NOT_ITALIC:
			s.current_attr.mode -= {.Italic}
		case .NOT_UNDERLINED:
			s.current_attr.mode -= {.Underline}
		case .NOT_BLINKING:
			s.current_attr.mode -= {.Blink}
		case .NOT_REVERSED:
			s.current_attr.mode -= {.Reverse}
		case .NOT_INVISIBLE:
			s.current_attr.mode -= {.Invisible}
		case .NOT_STRUCK:
			s.current_attr.mode -= {.StrikeThrough}

		case .FG_EXTENDED:
			i += 1
			if i < p_idx {
				if params[i] == 5 && i + 1 < p_idx {
					s.current_attr.fg = u32(params[i + 1])
					s.current_attr.mode -= {.TrueColorFG}
					i += 1
				} else if params[i] == 2 && i + 3 < p_idx {
					r, g, b := u32(params[i + 1]), u32(params[i + 2]), u32(params[i + 3])
					s.current_attr.fg = (r << 16) | (g << 8) | b
					s.current_attr.mode += {.TrueColorFG}
					i += 3
				}
			}

		case .FG_DEFAULT:
			s.current_attr.fg = DEFAULT_FG
			s.current_attr.mode -= {.TrueColorFG}

		case .BG_EXTENDED:
			i += 1
			if i < p_idx {
				if params[i] == 5 && i + 1 < p_idx {
					s.current_attr.bg = u32(params[i + 1])
					s.current_attr.mode -= {.TrueColorBG}
					i += 1
				} else if params[i] == 2 && i + 3 < p_idx {
					r, g, b := u32(params[i + 1]), u32(params[i + 2]), u32(params[i + 3])
					s.current_attr.bg = (r << 16) | (g << 8) | b
					s.current_attr.mode += {.TrueColorBG}
					i += 3
				}
			}

		case .BG_DEFAULT:
			s.current_attr.bg = DEFAULT_BG
			s.current_attr.mode -= {.TrueColorBG}
		}
		i += 1
	}
}


handle_insert_lines :: proc(s: ^Screen, n: int) {
	if s.cursor_y < s.scroll_top || s.cursor_y > s.scroll_bottom do return

	grid := s.in_alt_screen ? s.alt_grid : s.grid
	num := min(n, s.scroll_bottom - s.cursor_y + 1)

	// Shift existing lines down
	for y := s.scroll_bottom; y >= s.cursor_y + num; y -= 1 {
		dst := y * s.width
		src := (y - num) * s.width
		copy(grid[dst:dst + s.width], grid[src:src + s.width])
		s.dirty[y] = true
	}

	// Clear the inserted lines
	for y := s.cursor_y; y < s.cursor_y + num; y += 1 {
		start := y * s.width
		for x in 0 ..< s.width {
			grid[start + x] = Glyph {
				char = 0,
				fg   = s.current_attr.fg,
				bg   = s.current_attr.bg,
				mode = s.current_attr.mode,
			}
		}
		s.dirty[y] = true
	}
}

handle_delete_lines :: proc(s: ^Screen, n: int) {
	if s.cursor_y < s.scroll_top || s.cursor_y > s.scroll_bottom do return

	grid := s.in_alt_screen ? s.alt_grid : s.grid
	num := min(n, s.scroll_bottom - s.cursor_y + 1)

	// Shift lines up
	for y := s.cursor_y; y <= s.scroll_bottom - num; y += 1 {
		dst := y * s.width
		src := (y + num) * s.width
		copy(grid[dst:dst + s.width], grid[src:src + s.width])
		s.dirty[y] = true
	}

	// Clear the lines at the bottom of the region
	for y := s.scroll_bottom - num + 1; y <= s.scroll_bottom; y += 1 {
		start := y * s.width
		for x in 0 ..< s.width {
			grid[start + x] = Glyph {
				char = 0,
				fg   = s.current_attr.fg,
				bg   = s.current_attr.bg,
				mode = s.current_attr.mode,
			}
		}
		s.dirty[y] = true
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

handle_erase_in_line :: proc(s: ^Screen, mode: int) {
	row_start := s.cursor_y * s.width
	grid := s.in_alt_screen ? s.alt_grid : s.grid

	blank := blank_glyph(s)
	switch mode {
	case 0:
		// Clear from cursor to end of line
		for x in s.cursor_x ..< s.width {grid[row_start + x] = blank}
	case 1:
		// Clear from start of line to cursor
		for x in 0 ..< s.cursor_x + 1 {grid[row_start + x] = blank}
	case 2:
		// Clear whole line
		for x in 0 ..< s.width {grid[row_start + x] = blank}
	}
	s.dirty[s.cursor_y] = true
}

handle_erase_in_display :: proc(s: ^Screen, mode: int) {
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	blank := blank_glyph(s)
	switch mode {
	case 0:
		// Clear from cursor to end of screen
		// Clear current line from cursor
		handle_erase_in_line(s, 0)
		// Clear all lines below
		for y in s.cursor_y + 1 ..< s.height - 1 {
			for x in 0 ..< s.width {grid[y * s.width + x] = blank}
			s.dirty[y] = true
		}
	case 2:
		// Clear whole screen
		for i in 0 ..< len(grid) {grid[i] = blank}
		for i in 0 ..< s.height {s.dirty[i] = true}
	}
}

reset_attr :: proc(s: ^Screen) {
	s.current_attr.fg = DEFAULT_FG
	s.current_attr.bg = DEFAULT_BG
	s.current_attr.mode = {}
	s.current_attr.char = 0
}

