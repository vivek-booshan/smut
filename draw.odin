package smut

import "core:fmt"
import "core:strings"
import "core:sys/darwin"
import "core:sys/posix"

resize_screen :: proc(s: ^Screen, pty_fd: posix.FD) {
	ws: struct {
		r, c, x, y: u16,
	}

	// Get Host Terminal Size using STDOUT 
	if darwin.syscall_ioctl(posix.STDOUT_FILENO, darwin.TIOCGWINSZ, &ws) != -1 && ws.r > 0 {
		s.width = int(ws.c)
		s.height = int(ws.r)
	} else {
		s.width, s.height = 80, 24
	}

	total_cells := s.width * s.height
	if len(s.grid) != total_cells || len(s.dirty) != s.height {
		delete(s.grid)
		s.grid = make([dynamic]u8, total_cells)

		delete(s.dirty)
		s.dirty = make([dynamic]bool, s.height)
		for i in 0 ..< s.height {s.dirty[i] = true}
		s.cursor_x = clamp(s.cursor_x, 0, max(0, s.width - GUTTER_W - 1))
		s.cursor_y = clamp(s.cursor_y, 0, max(0, s.height - 1))
		// if s.cursor_x >= s.width - GUTTER_W {s.cursor_x = max(0, (s.width - GUTTER_W) - 1)}
		// if s.cursor_y >= s.height {s.cursor_y = max(0, s.height - 1)}
	}

	// Update child process of new size minus gutter [cite: 9]
	term_w := max(1, s.width - GUTTER_W)
	set_window_size(pty_fd, term_w, s.height - 1)
}

process_output :: proc(s: ^Screen, data: []u8) {
	term_view_w := max(1, s.width - GUTTER_W)

	for b in data {
		switch s.ansi_state {
		case .Ground:
			switch b {
			case 8, 127:
				// backspace / delete
				if s.cursor_x > 0 {
					s.cursor_x -= 1

					idx := (s.cursor_y * s.width) + s.cursor_x
					if idx < len(s.grid) {
						s.grid[idx] = 0
					}

					if s.cursor_y < len(s.dirty) {
						s.dirty[s.cursor_y] = true
					}
				}
			case 0x1b:
				// ESC
				s.ansi_state = .Escape
				s.ansi_idx = 0
			case '\n':
				s.cursor_y += 1
				handle_scrolling(s)
				s.pty_cursor_y = s.cursor_y
				if s.cursor_y < len(s.dirty) {s.dirty[s.cursor_y] = true}
			case '\r':
				s.cursor_x = 0
			case:
				if b >= 32 {
					if s.cursor_x >= term_view_w {
						s.cursor_x = 0
						s.cursor_y += 1
						handle_scrolling(s)
					}

					idx := (s.cursor_y * s.width) + s.cursor_x
					if idx < len(s.grid) {
						s.grid[idx] = b
						s.cursor_x += 1
						// MARK DIRTY: This line has changed
						if s.cursor_y < len(s.dirty) {s.dirty[s.cursor_y] = true}
					}
					s.pty_cursor_y = s.cursor_y
				}
			}

		case .Escape:
			if b == '[' {
				s.ansi_state = .Bracket
			} else {
				s.ansi_state = .Ground // Unsupported sequence
			}

		case .Bracket:
			if b >= 0x40 && b <= 0x7E { 	// Final character of CSI sequence
				handle_csi_sequence(s, b)
				s.ansi_state = .Ground
			} else if s.ansi_idx < len(s.ansi_buf) - 1 {
				s.ansi_buf[s.ansi_idx] = b
				s.ansi_idx += 1
			}
		}
	}
}


handle_csi_sequence :: proc(s: ^Screen, final: u8) {
	params_str := string(s.ansi_buf[:s.ansi_idx])

	switch final {
	case 'J':
		mode := 0
		if s.ansi_idx > 0 {mode = int(s.ansi_buf[0] - '0')}

		switch mode {
		case 0:
			// clear from cursor to end of screen
			idx := (s.cursor_y * s.width) + s.cursor_x
			for i in idx ..< len(s.grid) {s.grid[i] = 0}
		case 1:
			// clear from beginning of screen to cursor
			idx := (s.cursor_y * s.width) + s.cursor_x
			for i in 0 ..< idx {s.grid[i] = 0}
		case 2, 3:
			for i in 0 ..< len(s.grid) {s.grid[i] = 0}
			s.cursor_x = 0
			s.cursor_y = 0
		}
	case 'K':
		// Erase in Line
		// 0 = cursor to end (default), 1 = start to cursor, 2 = whole line
		row_start := s.cursor_y * s.width
		term_view_w := max(1, s.width - GUTTER_W)
		for x in s.cursor_x ..< term_view_w {
			s.grid[row_start + x] = 0
		}
	case 'H', 'f':
		// Cursor Position
		// Example: \x1b[row;colH
		// If empty, defaults to 1;1
		// Note: ANSI is 1-based, our grid is 0-based
		// Simple implementation for demonstration:
		s.cursor_x = 0
		s.cursor_y = 0
	case 'm':
		// Character Attributes (Color)
		// We ignore colors for now to keep the grid as u8,
		// but capturing 'm' prevents it from printing to screen.
		return
	}
}

MAX_SCROLLBACK :: 1000
handle_scrolling :: proc(s: ^Screen) {
	if s.cursor_y >= s.height {
		s.cursor_y = s.height - 1

		// 1. Capture the top row before shifting
		line := make([]u8, s.width)
		copy(line, s.grid[0:s.width])
		append(&s.scrollback, line)

		s.total_lines_scrolled += 1
		// 2. Limit history (e.g., 1000 lines)
		if len(s.scrollback) > MAX_SCROLLBACK {
			delete(s.scrollback[0])
			ordered_remove(&s.scrollback, 0)
		}

		start_read := s.width
		copy(s.grid[0:], s.grid[start_read:])

		bottom_row_start := (s.height - 1) * s.width
		for i in 0 ..< s.width {s.grid[bottom_row_start + i] = 0}
		for i in 0 ..< s.height {s.dirty[i] = true}
	}
}


draw_screen :: proc() {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	fmt.sbprint(&b, "\x1b[H\x1b[?25l")
	term_view_w := max(1, screen.width - GUTTER_W)

	history_len := len(screen.scrollback)
	for y in 0 ..< screen.height {
		// Calculate the absolute row index including history
		// Normal view (offset 0) ends at history_len + grid_y
		row_idx := history_len - screen.scroll_offset + y
		abs_line := (screen.total_lines_scrolled + y + 1) - screen.scroll_offset

		row_data: []u8
		is_history := false

		// if row_idx < history_len {
		// 	row_data = screen.scrollback[row_idx]
		// 	is_history = true
		// } else {
		// 	grid_y := row_idx - history_len
		// 	row_data = screen.grid[grid_y * screen.width:(grid_y + 1) * screen.width]
		// }

		if abs_line <= screen.total_lines_scrolled {
			if abs_line > 0 && abs_line <= len(screen.scrollback) {
				row_data = screen.scrollback[abs_line - 1]
				is_history = true
			}
		} else {
			grid_y := abs_line - screen.total_lines_scrolled - 1
			if grid_y < screen.height {
				row_data = screen.grid[grid_y * screen.width:]
			}
		}

		// Selection range calculation (relative to screen y)
		is_in_selection := false
		if screen.is_selecting {
			low := min(screen.selection_start_y, screen.cursor_y)
			high := max(screen.selection_start_y, screen.cursor_y)
			if y >= low && y <= high do is_in_selection = true
		}

		// 1. Draw Gutter
		// Always show gutter for history; show for grid only if below pty boundary
		grid_y_live := abs_line - screen.total_lines_scrolled - 1
		if is_history || (grid_y_live >= 0 && grid_y_live <= screen.pty_cursor_y) {
			if y == screen.cursor_y {
				fmt.sbprintf(&b, "\x1b[33m%3d \x1b[0m", abs_line)
			} else {
				rel_num := abs(y - screen.cursor_y)
				fmt.sbprintf(&b, "\x1b[90m%3d \x1b[0m", rel_num)
			}
		} else {
			fmt.sbprintf(&b, "%*s", GUTTER_W, "")
		}
		// grid_y := row_idx - history_len
		// if is_history || grid_y <= screen.pty_cursor_y {
		// 	rel_num := abs(y - screen.cursor_y)
		// 	if y == screen.cursor_y {
		// 	} else {
		// 		fmt.sbprintf("\x1b[90m%3d \x1b[0m", rel_num)
		// 	}
		// } else {
		// 	fmt.sbprintf("%*s", GUTTER_W, "")
		// }

		// 2. Draw Grid with selection and cursor
		for x in 0 ..< term_view_w {
			char := row_data[x]
			// Only draw cursor if we are in the active grid view (not history)
			is_cursor := (x == screen.cursor_x && y == screen.cursor_y)

			if is_cursor {
				fmt.sbprint(&b, "\x1b[7m")
			} else if is_in_selection {
				fmt.sbprint(&b, "\x1b[48;5;239m")
			}

			fmt.sbprint(&b, char == 0 ? ' ' : rune(char))

			if is_cursor || is_in_selection {
				fmt.sbprint(&b, "\x1b[0m")
			}
		}
		fmt.sbprint(&b, "\x1b[K\r\n")
		screen.dirty[y] = false
	}

	// 3. Status Bar
	// (Add scroll info if offset > 0)
	mode_color := screen.mode == .Normal ? "\x1b[30;42m" : "\x1b[30;44m"
	mode_name := screen.mode == .Normal ? " NORMAL " : " INSERT "

	fmt.sbprint(&b, mode_color)
	if screen.scroll_offset > 0 {
		fmt.sbprintf(&b, "%s [HISTORY: -%d] ", mode_name, screen.scroll_offset)
	} else {
		fmt.sbprint(&b, mode_name)
	}
	fmt.print(strings.to_string(b))
}

