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

		s.cursor_y = clamp(r - 1, 0, s.height - 1)
		s.cursor_x = clamp(c - 1, 0, s.width - 1)

	case 'A':
		// CUU - Cursor Up
		dist := p_idx > 0 ? max(1, params[0]) : 1
		s.cursor_y = max(0, s.cursor_y - dist)

	case 'B':
		// CUD - Cursor Down
		dist := p_idx > 0 ? max(1, params[0]) : 1
		s.cursor_y = min(s.height - 1, s.cursor_y + dist)

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

	case 'm': // SGR - Select Graphic Rendition
	// This handles colors. For now, we ignore or pass through.
	// A Suckless multiplexer usually just tracks the "current color"
	// to apply it to new characters in the grid.
	}

	// 3. MANDATORY: Sync PTY trackers
	// Without this, G and INSERT mode snapping will be off
	s.pty_cursor_x = s.cursor_x
	s.pty_cursor_y = s.cursor_y
}

handle_erase_in_line :: proc(s: ^Screen, mode: int) {
	row_start := s.cursor_y * s.width
	switch mode {
	case 0:
		// Clear from cursor to end of line
		for x in s.cursor_x ..< s.width {s.grid[row_start + x] = 0}
	case 1:
		// Clear from start of line to cursor
		for x in 0 ..< s.cursor_x + 1 {s.grid[row_start + x] = 0}
	case 2:
		// Clear whole line
		for x in 0 ..< s.width {s.grid[row_start + x] = 0}
	}
	s.dirty[s.cursor_y] = true
}

handle_erase_in_display :: proc(s: ^Screen, mode: int) {
	switch mode {
	case 0:
		// Clear from cursor to end of screen
		// Clear current line from cursor
		handle_erase_in_line(s, 0)
		// Clear all lines below
		for y in s.cursor_y + 1 ..< s.height {
			for x in 0 ..< s.width {s.grid[y * s.width + x] = 0}
			s.dirty[y] = true
		}
	case 2:
		// Clear whole screen
		for i in 0 ..< len(s.grid) {s.grid[i] = 0}
		for i in 0 ..< s.height {s.dirty[i] = true}
	}
}

