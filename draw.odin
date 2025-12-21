package smut

import "core:fmt"
import "core:strconv"
import "core:sys/posix"

handle_input :: proc(input: []u8, master_fd: posix.FD) {
	for &b in input {
		// Mode: NORMAL
		if screen.mode == .Normal {
			// 1. Enter Insert Mode

			// 2. Buffer the keystroke for the status bar
			if screen.cmd_idx < len(screen.cmd_buf) {
				screen.cmd_buf[screen.cmd_idx] = b
				screen.cmd_idx += 1
			}

			// 3. Extract the numeric multiplier (if any)
			// We look at the buffer and find the digits at the start
			count := 1
			digit_count := 0
			for i in 0 ..< screen.cmd_idx {
				if screen.cmd_buf[i] >= '0' && screen.cmd_buf[i] <= '9' {
					digit_count += 1
				} else {
					break
				}
			}

			if digit_count > 0 {
				if val, ok := strconv.parse_int(string(screen.cmd_buf[:digit_count])); ok {
					count = val
				}
			}

			// 4. Command Execution (Triggered by the last byte 'b')
			cmd_executed := true
			switch b {
			case '0' ..= '9':
				cmd_executed = false // Don't clear buffer yet, we are still typing a number
			case 'j':
				screen.cursor_y = min(screen.height - 1, screen.cursor_y + count)
			case 'k':
				screen.cursor_y = max(0, screen.cursor_y - count)
			case 'h':
				screen.cursor_x = max(0, screen.cursor_x - count)
			case 'l':
				screen.cursor_x = min(screen.width - 1, screen.cursor_x + count)
			case 'x':
				if !screen.is_selecting {screen.selection_start_y = screen.cursor_y;screen.is_selecting = true}
				screen.cursor_y = min(screen.height - 1, screen.cursor_y + count)
			case 'X':
				if !screen.is_selecting {screen.selection_start_y = screen.cursor_y;screen.is_selecting = true}
				screen.cursor_y = max(0, screen.cursor_y - count)
			case 'y':
				if screen.is_selecting {
					yank_selection(&screen)
				}
			case 'i':
				screen.mode = .Insert
				screen.is_selecting = false
				screen.cmd_idx = 0 // Clear keys on mode switch
				continue
			case 27:
				// ESC
				screen.is_selecting = false
				screen.is_selecting = false
			case:
				// If it's an unrecognized key, we don't treat it as a command
				cmd_executed = false
			}

			// If a command was finished (like 'j'), clear the keystroke buffer
			if cmd_executed {
				screen.cmd_idx = 0
			}
			continue
		}

		// Mode: INSERT
		if b == 27 { 	// ESC returns to Normal Mode
			screen.mode = .Normal
			continue
		}
		posix.write(master_fd, &b, 1)
	}
}

resize_screen :: proc(s: ^Screen, pty_fd: posix.FD) {
	ws: struct {
		r, c, x, y: u16,
	}

	// Get Host Terminal Size using STDOUT 
	if ioctl(posix.STDOUT_FILENO, 0x5413, &ws) != -1 {
		s.width = int(ws.c)
		s.height = int(ws.r)
	} else {
		s.width, s.height = 80, 24
	}

	total_cells := s.width * s.height
	if len(s.grid) != total_cells {
		delete(s.grid)
		s.grid = make([dynamic]u8, total_cells)
		if s.cursor_x >= s.width - GUTTER_W {s.cursor_x = max(0, (s.width - GUTTER_W) - 1)}
		if s.cursor_y >= s.height {s.cursor_y = max(0, s.height - 1)}
	}

	// Update child process of new size minus gutter [cite: 9]
	term_w := max(1, s.width - GUTTER_W)
	set_window_size(pty_fd, term_w, s.height)
}

process_output :: proc(s: ^Screen, data: []u8) {
	term_view_w := max(1, s.width - GUTTER_W)

	for b in data {
		switch s.ansi_state {
		case .Ground:
			switch b {
			case 0x1b:
				// ESC
				s.ansi_state = .Escape
				s.ansi_idx = 0
			case '\n':
				s.cursor_y += 1
				handle_scrolling(s)
			case '\r':
				s.cursor_x = 0
			case '\t':
				// Handle Tabs for alignment
				s.cursor_x = (s.cursor_x + 8) & ~int(7)
				if s.cursor_x >= term_view_w {s.cursor_x = term_view_w - 1}
			case 8, 127:
				// Backspace / Delete
				if s.cursor_x > 0 {s.cursor_x -= 1}
			case:
				if b >= 32 {
					if s.cursor_x < term_view_w {
						idx := (s.cursor_y * s.width) + s.cursor_x
						s.grid[idx] = b
						s.cursor_x += 1
					}
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

handle_scrolling :: proc(s: ^Screen) {
	if s.cursor_y >= s.height {
		s.cursor_y = s.height - 1
		start_read := s.width
		copy(s.grid[0:], s.grid[start_read:])

		bottom_row_start := (s.height - 1) * s.width
		for i in 0 ..< s.width {s.grid[bottom_row_start + i] = 0}
	}
}

draw_screen :: proc() {
	fmt.print("\x1b[H\x1b[?25l")
	term_view_w := max(1, screen.width - GUTTER_W)

	for y in 0 ..< screen.height {
		// Selection range calculation
		is_in_selection := false
		if screen.is_selecting {
			low := min(screen.selection_start_y, screen.cursor_y)
			high := max(screen.selection_start_y, screen.cursor_y)
			if y >= low && y <= high do is_in_selection = true
		}

		// 1. Draw Gutter (Relative numbers like Vim)
		rel_num := abs(y - screen.cursor_y)
		if y == screen.cursor_y {
			fmt.printf("\x1b[33m%3d \x1b[0m", y + 1)
		} else {
			fmt.printf("\x1b[90m%3d \x1b[0m", rel_num)
		}

		// 2. Draw Grid with selection and cursor
		row_start := y * screen.width
		for x in 0 ..< term_view_w {
			char := screen.grid[row_start + x]
			is_cursor := (x == screen.cursor_x && y == screen.cursor_y)

			if is_cursor {
				fmt.print("\x1b[7m") // Inverse
			} else if is_in_selection {
				fmt.print("\x1b[48;5;239m") // Selection BG
			}

			fmt.print(char == 0 ? ' ' : rune(char))

			if is_cursor || is_in_selection {
				fmt.print("\x1b[0m")
			}
		}
		fmt.print("\x1b[K\r\n")
	}
	// 3. Status Bar
	// Select the color sequence based on the mode
	mode_color := screen.mode == .Normal ? "\x1b[30;42m" : "\x1b[30;44m"
	mode_name := screen.mode == .Normal ? " NORMAL " : " INSERT "
	keystrokes := string(screen.cmd_buf[:screen.cmd_idx])

	// Move to the last line of the screen (optional, if your loop doesn't end there)
	// fmt.printf("\x1b[%d;1H", screen.height + 1)

	// 1. Start the color
	fmt.print(mode_color)

	// 2. Print the mode name and any keystrokes
	if len(keystrokes) > 0 {
		fmt.printf("%s | %s ", mode_name, keystrokes)
	} else {
		fmt.printf("%s ", mode_name)
	}

	// 3. IMPORTANT: Erase to end of line WHILE the background color is active
	// This fills the entire width with the background color
	fmt.print("\x1b[K")

	// 4. Finally, reset the attributes
	fmt.print("\x1b[0m")
}

