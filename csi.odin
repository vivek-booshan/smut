package smut

ansi_parser :: proc(s: ^Screen) -> (int, [8]int) {
	params: [8]int // Standard ANSI usually needs no more than 2-3
	p_idx := 0
	current_val := 0
	has_val := false

	// 1. Minimalist Parameter Parser
	// We parse the buffer we collected in the CSI state (e.g., "10;20")
	for i in 0 ..< s.ansi_idx {
		char := s.ansi_buf[i]
		if char >= '0' && char <= '9' {
			current_val = (current_val * 10) + int(char - '0')
			has_val = true
		} else if char == ';' {
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

				for i in 0 ..< len(s.alt_grid) {s.alt_grid[i] = rune(0)}
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
		num := p_idx > 0 ? max(1, params[0]) : 1
		handle_delete_lines(s, num)
	case 'm': // SGR - Select Graphic Rendition
	// This handles colors. For now, we ignore or pass through.
	// A Suckless multiplexer usually just tracks the "current color"
	// to apply it to new characters in the grid.
	}

	s.pty_cursor_x = s.cursor_x
	s.pty_cursor_y = s.cursor_y
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
		for x in 0 ..< s.width do grid[start + x] = rune(0)
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
		for x in 0 ..< s.width do grid[start + x] = rune(0)
		s.dirty[y] = true
	}
}

handle_erase_in_line :: proc(s: ^Screen, mode: int) {
	row_start := s.cursor_y * s.width
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	switch mode {
	case 0:
		// Clear from cursor to end of line
		for x in s.cursor_x ..< s.width {grid[row_start + x] = rune(0)}
	case 1:
		// Clear from start of line to cursor
		for x in 0 ..< s.cursor_x + 1 {grid[row_start + x] = rune(0)}
	case 2:
		// Clear whole line
		for x in 0 ..< s.width {grid[row_start + x] = rune(0)}
	}
	s.dirty[s.cursor_y] = true
}

handle_erase_in_display :: proc(s: ^Screen, mode: int) {
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	switch mode {
	case 0:
		// Clear from cursor to end of screen
		// Clear current line from cursor
		handle_erase_in_line(s, 0)
		// Clear all lines below
		for y in s.cursor_y + 1 ..< s.height {
			for x in 0 ..< s.width {grid[y * s.width + x] = rune(0)}
			s.dirty[y] = true
		}
	case 2:
		// Clear whole screen
		for i in 0 ..< len(grid) {grid[i] = rune(0)}
		for i in 0 ..< s.height {s.dirty[i] = true}
	}
}

