package smut

import "core:fmt"
// import "core:strconv"
import "core:strings"
import "core:sys/darwin"
import "core:sys/posix"
import "core:unicode/utf8"

resize_screen :: proc(s: ^Screen, pty_fd: posix.FD) {
	ws: struct {
		r, c, x, y: u16,
	}

	old_w, old_h := s.width, s.height

	if darwin.syscall_ioctl(posix.STDOUT_FILENO, darwin.TIOCGWINSZ, &ws) != -1 && ws.r > 0 {
		s.width = int(ws.c)
		s.height = int(ws.r)
	} else {
		s.width, s.height = 80, 24
	}

	// 3. Only reallocate if the dimensions actually changed
	if old_w != s.width || old_h != s.height || len(s.grid) == 0 {
		total_cells := s.width * s.height

		// Prepare new buffers
		new_grid := make([dynamic]rune, total_cells)
		new_alt_grid := make([dynamic]rune, total_cells)
		new_dirty := make([dynamic]bool, s.height)

		// 4. PRESERVATION LOGIC: Copy old data into the new grid
		// We copy row-by-row to handle width changes correctly
		if len(s.grid) > 0 {
			min_h := min(old_h, s.height)
			min_w := min(old_w, s.width)

			for y in 0 ..< min_h {
				old_start := y * old_w
				new_start := y * s.width

				copy(new_grid[new_start:new_start + min_w], s.grid[old_start:old_start + min_w])
				copy(
					new_alt_grid[new_start:new_start + min_w],
					s.alt_grid[old_start:old_start + min_w],
				)
			}
		}

		delete(s.grid)
		delete(s.alt_grid)
		delete(s.dirty)

		s.grid = new_grid
		s.alt_grid = new_alt_grid
		s.dirty = new_dirty

		// 6. Clamp cursor positions to ensure they stay within the new bounds
		// Note: cursor_y is clamped to height-2 to reserve height-1 for the status bar
		s.cursor_x = clamp(s.cursor_x, 0, max(0, s.width - GUTTER_W - 1))
		s.cursor_y = clamp(s.cursor_y, 0, max(0, s.height - 2))
	}

	// This is critical to prevent the screen from "disappearing" on resize
	for i in 0 ..< s.height {
		if i < len(s.dirty) do s.dirty[i] = true
	}

	term_w := max(1, s.width - GUTTER_W)
	set_window_size(pty_fd, term_w, s.height - 1)
}

// process_output :: proc(s: ^Screen, data: []u8) {
// 	current_w := s.in_alt_screen ? s.width : (s.width - GUTTER_W)

// 	for b in data {
// 		switch s.ansi_state {
// 		case .Ground:
// 			if b < 32 || b == 127 {
// 				handle_control_char(s, rune(b), current_w)
// 			} else {
// 				write_rune_to_grid(s, rune(b), current_w)
// 			}
// 		case .Escape:
// 			handle_esc_char(s, b)
// 		case .CSI:
// 			handle_csi_sequence(s, b)
// 		case .STR:
// 			handle_str_sequence(s)
// 		case .Charset, .Esc_Test:
// 			s.ansi_state = .Ground
// 		}
// 	}
// }

process_output :: proc(s: ^Screen, data: []u8) {
	current_w := s.in_alt_screen ? s.width : (s.width - GUTTER_W)

	i := 0
	for i < len(data) {
		// 1. If we are in the middle of an ANSI sequence, process byte-by-byte
		if s.ansi_state != .Ground {
			handle_ansi_byte(s, data[i])
			i += 1
			continue
		}

		r, width := utf8.decode_rune(data[i:])

		if r == utf8.RUNE_ERROR && width <= 1 && i + width == len(data) {
			break
		}

		if r < 32 || r == 127 {
			handle_control_char(s, r, current_w)
		} else {
			write_rune_to_grid(s, r, current_w)
		}

		i += width
	}
}

handle_ansi_byte :: proc(s: ^Screen, b: byte) {
	switch s.ansi_state {
	case .Escape:
		switch b {
		case '[':
			s.ansi_state = .CSI
			s.ansi_idx = 0
		case ']', 'P', '^', '_':
			s.ansi_state = .STR
			s.str_type = rune(b)
			s.str_idx = 0
		case '(', ')':
			s.ansi_state = .Charset
		case '#':
			s.ansi_state = .Esc_Test
		case:
			handle_esc_char(s, b)
			s.ansi_state = .Ground
		}

	case .CSI:
		// Final characters for CSI are in the range 0x40-0x7E
		if b >= 0x40 && b <= 0x7E {
			handle_csi_sequence(s, b)
			s.ansi_state = .Ground
		} else if s.ansi_idx < len(s.ansi_buf) - 1 {
			s.ansi_buf[s.ansi_idx] = b
			s.ansi_idx += 1
		}

	case .STR:
		// Terminated by BEL (0x07) or ST (ESC \)
		if b == 0x07 {
			handle_str_sequence(s)
			s.ansi_state = .Ground
		} else if s.str_idx < len(s.str_buf) - 1 {
			s.str_buf[s.str_idx] = rune(b)
			s.str_idx += 1
		}
	// Note: Full ST (ESC \) detection requires more state

	case .Charset, .Esc_Test, .Ground:
		s.ansi_state = .Ground
	}
}

write_rune_to_grid :: proc(s: ^Screen, b: rune, current_w: int) {
	if b < 32 do return

	if s.cursor_x >= current_w {
		s.cursor_x = 0
		s.cursor_y = min(s.cursor_y + 1, s.height - 2)
	}

	idx := (s.cursor_y * s.width) + s.cursor_x
	grid := s.in_alt_screen ? s.alt_grid : s.grid

	if idx < len(grid) {
		grid[idx] = b
		s.dirty[s.cursor_y] = true
	}

	s.cursor_x += 1

	s.pty_cursor_x = s.cursor_x
	s.pty_cursor_y = s.cursor_y
}

handle_str_sequence :: proc(s: ^Screen) {
	// OSC (type ']') is common for titles. 
	// Format: \e]0;TITLE\x07
	if s.str_type == ']' {
		// Log or handle window title changes here
	}
}

handle_esc_char :: proc(s: ^Screen, b: u8) {
	switch b {
	case 'D':
		// Index (Line Feed)
		handle_control_char(s, '\n', s.width)
	case 'M':
		// Reverse Index (Move cursor up)
		s.cursor_y = max(0, s.cursor_y - 1)
	case 'c': // RIS (Reset to Initial State)
	// Clear screen, reset modes
	}
}

MAX_SCROLLBACK :: 1000
// handle_scrolling :: proc(s: ^Screen) {
// 	limit := s.scroll_bottom > 0 ? s.scroll_bottom : s.height - 2
// 	if s.cursor_y >= limit {
// 		s.cursor_y = limit

// 		if s.in_alt_screen {
// 			start_read := s.width
// 			copy(s.alt_grid[0:], s.alt_grid[start_read:])
// 		} else {
// 			line := make([]rune, s.width)
// 			copy(line, s.grid[0:s.width])

// 			append(&s.scrollback, line)
// 			s.total_lines_scrolled += 1

// 			if len(s.scrollback) > MAX_SCROLLBACK {
// 				delete(s.scrollback[0])
// 				ordered_remove(&s.scrollback, 0)
// 			}

// 			start_read := s.width
// 			copy(s.grid[0:], s.grid[start_read:])
// 		}

// 		grid := s.in_alt_screen ? s.alt_grid : s.grid
// 		bottom_row_start := (s.height - 1) * s.width
// 		for i in 0 ..< s.width {grid[bottom_row_start + i] = 0}
// 		for i in 0 ..< s.height {s.dirty[i] = true}
// 	}
// }
handle_scrolling :: proc(s: ^Screen) {
	limit := s.scroll_bottom > 0 ? s.scroll_bottom : s.height - 2
	if s.cursor_y > limit {
		s.cursor_y = limit

		grid := s.in_alt_screen ? s.alt_grid : s.grid

		// Shift within the region
		dst_start := s.scroll_top * s.width
		src_start := (s.scroll_top + 1) * s.width
		len_bytes := (s.scroll_bottom - s.scroll_top) * s.width

		copy(grid[dst_start:], grid[src_start:src_start + len_bytes])

		// Clear only the bottom row of the scrolling region
		clear_start := s.scroll_bottom * s.width
		for i in 0 ..< s.width {grid[clear_start + i] = 0}

		for i in s.scroll_top ..= s.scroll_bottom {s.dirty[i] = true}
	}
}

get_row_data :: proc(abs_line: int) -> (row_data: []rune, is_history: bool) {

	is_history = false
	if abs_line <= screen.total_lines_scrolled {
		if abs_line > 0 && abs_line <= len(screen.scrollback) {
			row_data = screen.scrollback[abs_line - 1]
			is_history = true
		}
	} else {
		grid_y := abs_line - screen.total_lines_scrolled - 1
		if grid_y >= 0 && grid_y < screen.height {
			row_data = screen.grid[grid_y * screen.width:]
		}
	}
	return row_data, is_history

}
within_selection :: proc(y: int) -> bool {
	if !screen.is_selecting do return false
	low := min(screen.selection_start_y, screen.cursor_y)
	high := max(screen.selection_start_y, screen.cursor_y)
	return y >= low && y <= high
}

draw_gutter :: proc(b: ^strings.Builder, y, abs_line, pty_cursor_y: int, is_history: bool) {
	grid_y_live := abs_line - screen.total_lines_scrolled - 1

	if is_history || (grid_y_live >= 0 && grid_y_live <= pty_cursor_y) {
		if y == screen.cursor_y {
			fmt.sbprintf(b, "\x1b[33;49m%3d \x1b[0m", abs_line)
		} else {
			rel_num := abs(y - screen.cursor_y)
			fmt.sbprintf(b, "\x1b[90;49m%3d \x1b[0m", rel_num)
		}
	} else {
		fmt.sbprintf(b, "\x1b[49m%*s", GUTTER_W, "")
	}
}

handle_control_char :: proc(s: ^Screen, b: rune, current_w: int) {
	switch b {
	case 27:
		s.ansi_state = .Escape
		s.ansi_idx = 0
	case 8, 127:
		// Backspace
		if s.cursor_x > 0 {
			s.cursor_x -= 1
			idx := (s.cursor_y * s.width) + s.cursor_x
			target := s.in_alt_screen ? s.alt_grid : s.grid
			if idx < len(target) do target[idx] = 0
			if s.cursor_y < len(s.dirty) do s.dirty[s.cursor_y] = true
		}
		s.pty_cursor_x = s.cursor_x
	case '\t':
		s.cursor_x = (s.cursor_x + 8) & ~int(7)
		if s.cursor_x >= current_w do s.cursor_x = current_w - 1
		if s.cursor_y < len(s.dirty) do s.dirty[s.cursor_y] = true
		s.pty_cursor_x = s.cursor_x
	case '\n':
		s.cursor_y += 1
		handle_scrolling(s)
		s.pty_cursor_y = s.cursor_y
		if s.cursor_y < len(s.dirty) do s.dirty[s.cursor_y] = true
	case '\r':
		s.cursor_x = 0
		s.pty_cursor_x = 0
	}
}


draw_screen :: proc() {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	fmt.sbprint(&b, "\x1b[H\x1b[?25l")
	term_view_w := max(1, screen.width - GUTTER_W)

	history_len := len(screen.scrollback)
	for y in 0 ..< screen.height - 1 {
		// Calculate the absolute row index including history
		// Normal view (offset 0) ends at history_len + grid_y
		row_idx := history_len - screen.scroll_offset + y
		abs_line := (screen.total_lines_scrolled + y + 1) - screen.scroll_offset

		row_data: []rune
		is_history := false
		if screen.in_alt_screen {
			start := y * screen.width
			if start < len(screen.alt_grid) {
				row_data = screen.alt_grid[start:start + screen.width]
			}
		} else {
			row_data, is_history = get_row_data(abs_line)
		}

		// Selection range calculation (relative to screen y)
		is_in_selection := within_selection(y)

		// 1. Draw Gutter
		if !screen.in_alt_screen {
			draw_gutter(&b, y, abs_line, screen.pty_cursor_y, is_history)
		}

		// 2. Draw Grid with selection and cursor
		view_w := screen.in_alt_screen ? screen.width : term_view_w
		draw_grid(&b, y, row_data, view_w, is_in_selection)

		fmt.sbprint(&b, "\x1b[K\r\n")
		screen.dirty[y] = false
	}

	draw_status_bar(&b)
	fmt.sbprint(&b, "\x1b[0m") // reset
	fmt.print(strings.to_string(b))
}

draw_status_bar :: proc(b: ^strings.Builder) {
	mode_color: string
	mode_name: string

	switch screen.mode {
	case .Insert:
		mode_color, mode_name = "\x1b[30;44m", " INSERT " // Blue
	case .Motion:
		mode_color, mode_name = "\x1b[30;42m", " MOTION " // Green
	case .Switch:
		mode_color, mode_name = "\x1b[30;43m", " SWITCH " // Yellow (Leader Active)
	case .Select:
		mode_color, mode_name = "\x1b[30;45m", " SELECT "
	}


	fmt.sbprint(b, mode_color)
	if screen.scroll_offset > 0 {
		fmt.sbprintf(b, "%s [HISTORY: -%d] ", mode_name, screen.scroll_offset)
	} else {
		fmt.sbprint(b, mode_name)
	}

	fmt.sbprint(b, "\x1b[K")
}


draw_grid :: proc(
	b: ^strings.Builder,
	y: int,
	row_data: []rune,
	view_w: int,
	is_in_selection: bool,
) {
	for x in 0 ..< view_w {
		char := row_data[x]
		// Only draw cursor if we are in the active grid view (not history)
		is_cursor := (x == screen.cursor_x && y == screen.cursor_y)

		if is_cursor {
			fmt.sbprint(b, "\x1b[7m") // inverse color
		} else if is_in_selection {
			fmt.sbprint(b, "\x1b[48;5;239m")
		}

		fmt.sbprint(b, char == 0 ? ' ' : rune(char))

		if is_cursor || is_in_selection {
			fmt.sbprint(b, "\x1b[0m")
		}
	}

}

