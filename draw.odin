package smut

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/darwin"
import "core:sys/posix"

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
		new_grid := make([dynamic]u8, total_cells)
		new_alt_grid := make([dynamic]u8, total_cells)
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

process_output :: proc(s: ^Screen, data: []u8) {
	current_w := s.in_alt_screen ? s.width : (s.width - GUTTER_W)

	for b in data {
		// Handle global control characters first (C0 set)
		if b < 32 {
			switch b {
			case 0x1b:
				// ESC
				s.ansi_state = .Escape
				s.ansi_idx = 0
				continue
			case 0x07:
				// BEL (terminates some STR sequences)
				if s.ansi_state == .STR {
					handle_str_sequence(s)
					s.ansi_state = .Ground
				}
				continue
			case '\t', '\n', '\r', 8, 127:
				// These are handled in Ground, but if we get them during a sequence,
				// st typically executes them and remains in the sequence state.
				if s.ansi_state == .Ground {
					handle_control_char(s, b, current_w)
					continue
				}
			}
		}

		switch s.ansi_state {
		case .Ground:
			write_char_to_grid(s, b, current_w)

		case .Escape:
			switch b {
			case '[':
				s.ansi_state = .CSI
			case ']', 'P', '^', '_':
				s.ansi_state = .STR
				s.str_type = b
				s.str_idx = 0
			case '(', ')':
				s.ansi_state = .Charset
			case '#':
				s.ansi_state = .Esc_Test
			case:
				// Handle single-char ESC sequences (e.g., ESC D, ESC M)
				handle_esc_char(s, b)
				s.ansi_state = .Ground
			}

		case .CSI:
			// Collect params and intermediates
			if b >= 0x40 && b <= 0x7E {
				handle_csi_sequence(s, b)
				s.ansi_state = .Ground
			} else if s.ansi_idx < len(s.ansi_buf) - 1 {
				s.ansi_buf[s.ansi_idx] = b
				s.ansi_idx += 1
			}

		case .STR:
			// String sequences end with ST (ESC \) or BEL (0x07)
			if b == 0x1b {
				// Potential ST transition (ESC \)
				// For simplicity, handle_str_sequence can look for ST
			} else if s.str_idx < len(s.str_buf) - 1 {
				s.str_buf[s.str_idx] = b
				s.str_idx += 1
			}

		case .Charset, .Esc_Test:
			// Finalize these one-char state extensions
			s.ansi_state = .Ground
		}
	}
}


// handle_csi_sequence :: proc(s: ^Screen, final: u8) {
// 	params_str := string(s.ansi_buf[:s.ansi_idx])

// 	args := strings.split(params_str, ";")
// 	defer delete(args)

// 	switch final {
// 	case 'J':
// 		mode := 0
// 		if len(args) > 0 && len(args[0]) > 0 do mode = strconv.atoi(args[0])
// 		// if s.ansi_idx > 0 {mode = int(s.ansi_buf[0] - '0')}
// 		target_grid := s.in_alt_screen ? &s.alt_grid : &s.grid
// 		switch mode {
// 		case 0:
// 			// clear from cursor to end of screen
// 			idx := (s.cursor_y * s.width) + s.cursor_x
// 			for i in idx ..< len(target_grid) {target_grid[i] = 0}
// 		case 1:
// 			// clear from beginning of screen to cursor
// 			idx := (s.cursor_y * s.width) + s.cursor_x
// 			for i in 0 ..< idx {target_grid[i] = 0}
// 		case 2, 3:
// 			for i in 0 ..< len(target_grid) {target_grid[i] = 0}
// 			s.cursor_x = 0
// 			s.cursor_y = 0
// 		}
// 	case 'K':
// 		// Erase in Line
// 		// 0 = cursor to end (default), 1 = start to cursor, 2 = whole line
// 		row_start := s.cursor_y * s.width
// 		term_view_w := max(1, s.width - GUTTER_W)
// 		for x in s.cursor_x ..< term_view_w {
// 			s.grid[row_start + x] = 0
// 		}
// 	case 'H', 'f':
// 		row := 0
// 		col := 0

// 		if len(args) >= 1 && len(args[0]) > 0 {
// 			row = max(0, strconv.atoi(args[0]) - 1)
// 		}
// 		if len(args) >= 2 && len(args[1]) > 0 {
// 			col = max(0, strconv.atoi(args[1]) - 1)
// 		}

// 		s.cursor_y = clamp(row, 0, s.height - 1)
// 		max_w := s.in_alt_screen ? s.width : (s.width - GUTTER_W)

// 		s.cursor_x = clamp(col, 0, max_w - 1)
// 	case 'h':
// 		// Set Mode
// 		if params_str == "?1049" {
// 			if !s.in_alt_screen {
// 				// save main cursor
// 				s.alt_cursor_x = s.cursor_x
// 				s.alt_cursor_y = s.cursor_y

// 				s.in_alt_screen = true

// 				// clear alt grid and reset cursor
// 				for i in 0 ..< len(s.alt_grid) {
// 					s.alt_grid[i] = 0
// 				}
// 				s.cursor_x = 0
// 				s.cursor_y = 0

// 				for i in 0 ..< s.height do s.dirty[i] = true
// 			}
// 		}
// 	case 'l':
// 		if params_str == "?1049" {
// 			if s.in_alt_screen {
// 				// exit alt mode
// 				s.in_alt_screen = false

// 				// restore main cursor
// 				s.cursor_x = s.alt_cursor_x
// 				s.cursor_y = s.alt_cursor_y


// 				for i in 0 ..< s.height do s.dirty[i] = true
// 			}
// 		}
// 	case 'm':
// 		// Character Attributes (Color)
// 		// We ignore colors for now to keep the grid as u8,
// 		// but capturing 'm' prevents it from printing to screen.
// 		return
// 	}
// }


write_char_to_grid :: proc(s: ^Screen, b: u8, current_w: int) {
	if b < 32 do return

	if s.cursor_x >= current_w {
		s.cursor_x = 0
		s.cursor_y = min(s.cursor_y + 1, s.height - 2)
	}

	idx := (s.cursor_y * s.width) + s.cursor_x
	if s.in_alt_screen {
		if idx < len(s.alt_grid) do s.alt_grid[idx] = b
	} else {
		if idx < len(s.grid) do s.grid[idx] = b
	}

	if s.cursor_y < len(s.dirty) do s.dirty[s.cursor_y] = true
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
handle_scrolling :: proc(s: ^Screen) {
	// Status bar is at height-1, so height-2 is our last usable row
	if s.cursor_y >= s.height - 1 {
		s.cursor_y = s.height - 2

		if s.in_alt_screen {
			// Vim/TUI mode: Just shift the alt_grid, no history capture
			start_read := s.width
			copy(s.alt_grid[0:], s.alt_grid[start_read:])

			// Clear the new bottom line
			bottom_row_start := (s.height - 2) * s.width
			for i in 0 ..< s.width {s.alt_grid[bottom_row_start + i] = 0}
		} else {
			// Shell mode: Save the top line to history and shift main grid
			line := make([]u8, s.width)
			copy(line, s.grid[0:s.width])
			append(&s.scrollback, line)
			s.total_lines_scrolled += 1

			if len(s.scrollback) > MAX_SCROLLBACK {
				delete(s.scrollback[0])
				ordered_remove(&s.scrollback, 0)
			}

			start_read := s.width
			copy(s.grid[0:], s.grid[start_read:])

			bottom_row_start := (s.height - 2) * s.width
			for i in 0 ..< s.width {s.grid[bottom_row_start + i] = 0}
		}

		// Mark all lines dirty for a full redraw after a scroll
		for i in 0 ..< s.height {s.dirty[i] = true}
	}
}

get_row_data :: proc(abs_line: int) -> (row_data: []u8, is_history: bool) {

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

handle_control_char :: proc(s: ^Screen, b: u8, current_w: int) {
	switch b {
	case 27:
		s.ansi_state = .Escape
	case 8, 127:
		// Backspace
		if s.cursor_x > 0 {
			s.cursor_x -= 1
			idx := (s.cursor_y * s.width) + s.cursor_x
			target := s.in_alt_screen ? &s.alt_grid : &s.grid
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

		row_data: []u8
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
	row_data: []u8,
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

