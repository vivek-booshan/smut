package smut

import "core:fmt"
import "core:strings"
import "core:sys/darwin"
import "core:sys/posix"

MAX_SCROLLBACK :: 8192

LINE_FEED :: 'D'
MOVE_CUP :: 'M'
RESET :: 'c'
INDEX :: 'D' // Line Feed
REVERSE_INDEX :: 'M' // Move Cursor Up? It just works ig
RIS :: 'c' // Reset to Initial State

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

	if old_w != s.width || old_h != s.height || len(s.grid) == 0 {
		total_cells := s.width * s.height
		blank := blank_glyph(s)

		new_grid := make([dynamic]Glyph, total_cells)
		new_alt_grid := make([dynamic]Glyph, total_cells)
		new_dirty := make([dynamic]bool, s.height)

		for i in 0 ..< total_cells {
			new_grid[i] = blank
			new_alt_grid[i] = blank
		}

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

		// Reserve 1 line for Status Bar
		s.cursor_x = clamp(s.cursor_x, 0, max(0, s.width - 1))
		s.cursor_y = clamp(s.cursor_y, 0, max(0, s.height - 2))
	}

	for i in 0 ..< s.height {
		if i < len(s.dirty) do s.dirty[i] = true
	}

	pty_w := s.in_alt_screen ? s.width : s.width - GUTTER_W
	set_window_size(pty_fd, pty_w, s.height - 1)
}

process_output :: proc(s: ^Screen, data: []u8) {
	for b in data {
		handle_ansi_byte(s, b)
	}
}

write_rune_to_grid :: proc(s: ^Screen, b: rune, current_w: int) {
	VIEW_LIMIT := s.height - 2

	if s.pty_cursor_x >= current_w {
		s.pty_cursor_x = 0
		s.pty_cursor_y += 1
		handle_scrolling(s)
	}

	if s.pty_cursor_y > VIEW_LIMIT {
		s.pty_cursor_y = VIEW_LIMIT
		handle_scrolling(s)
	}

	idx := (s.pty_cursor_y * s.width) + s.pty_cursor_x
	grid := s.in_alt_screen ? s.alt_grid : s.grid

	if idx < len(grid) {
		grid[idx] = s.current_attr
		grid[idx].char = b
		s.dirty[s.pty_cursor_y] = true
	}

	s.pty_cursor_x += 1
	s.cursor_x = s.pty_cursor_x
	s.cursor_y = s.pty_cursor_y
}

handle_scrollback :: proc(s: ^Screen) {
	if !s.in_alt_screen && s.scroll_top == 0 {
		line := make([]Glyph, s.width)
		copy(line, s.grid[0:s.width])
		append(&s.scrollback, line)
		s.total_lines_scrolled += 1

		if len(s.scrollback) > MAX_SCROLLBACK {
			delete(s.scrollback[0])
			ordered_remove(&s.scrollback, 0)
			if s.scroll_offset > 0 {
				s.scroll_offset = min(s.scroll_offset, len(s.scrollback))
			}
		}
	}
}

handle_scrolling :: proc(s: ^Screen) {
	limit: int
	if s.scroll_bottom > 0 && s.scroll_bottom < s.height - 1 {
		limit = s.scroll_bottom
	} else {
		limit = s.height - 2
	}

	if s.cursor_y <= limit {
		return
	}

	s.cursor_y = limit
	handle_scrollback(s)
	grid := s.in_alt_screen ? s.alt_grid : s.grid

	dst_start := s.scroll_top * s.width
	src_start := (s.scroll_top + 1) * s.width
	len_bytes := (limit - s.scroll_top) * s.width

	copy(grid[dst_start:], grid[src_start:src_start + len_bytes])

	clear_start := limit * s.width
	for i in 0 ..< s.width {grid[clear_start + i] = blank_glyph(s)}

	for i in s.scroll_top ..= limit {s.dirty[i] = true}
}

get_row_data :: proc(abs_line: int) -> (row_data: []Glyph, is_history: bool) {
	is_history = false
	history_start := max(1, screen.total_lines_scrolled - len(screen.scrollback) + 1)

	if abs_line < history_start {
		return nil, false
	}

	if abs_line <= screen.total_lines_scrolled {
		idx := abs_line - history_start
		if idx >= 0 && idx < len(screen.scrollback) {
			row_data = screen.scrollback[idx]
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
		width := GUTTER_W - 1
		if y == screen.cursor_y {
			fmt.sbprintf(b, "\x1b[33;49m%*d \x1b[0m", width, abs_line)
		} else {
			rel_num := abs(y - screen.cursor_y)
			fmt.sbprintf(b, "\x1b[90;49m%*d \x1b[0m", width, rel_num)
		}
	} else {
		fmt.sbprintf(b, "\x1b[49m%*s", GUTTER_W, "")
	}
}

handle_control_char :: proc(s: ^Screen, b: rune, current_w: int) {
	switch b {
	case BACKSPACE, DEL:
		if s.cursor_x > 0 {
			s.cursor_x -= 1
			s.dirty[s.cursor_y] = true
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
		row_idx := history_len - screen.scroll_offset + y
		abs_line := (screen.total_lines_scrolled + y + 1) - screen.scroll_offset

		row_data: []Glyph
		is_history := false
		if screen.in_alt_screen {
			start := y * screen.width
			if start < len(screen.alt_grid) {
				row_data = screen.alt_grid[start:start + screen.width]
			}
		} else {
			row_data, is_history = get_row_data(abs_line)
		}

		is_in_selection := within_selection(y)

		if !screen.in_alt_screen {
			draw_gutter(&b, y, abs_line, screen.pty_cursor_y, is_history)
		}

		view_w := screen.in_alt_screen ? screen.width : term_view_w
		draw_grid(&b, y, row_data, view_w, is_in_selection)

		fmt.sbprint(&b, "\x1b[K\r\n")
		screen.dirty[y] = false
	}

	draw_status_bar(&b)
	fmt.sbprint(&b, "\x1b[0m")

	if screen.cursor_visible {
		// Terminals 1-indexed
		offset_x := screen.in_alt_screen ? 1 : (1 + GUTTER_W)
		phys_x := screen.cursor_x + offset_x
		phys_y := screen.cursor_y + 1
		fmt.sbprintf(&b, "\x1b[%d;%dH", phys_y, phys_x)

		style := screen.cursor_style == 0 ? 2 : screen.cursor_style
		fmt.sbprintf(&b, "\x1b[%d q", style)

		fmt.sbprint(&b, "\x1b[?25h")
	} else {
		fmt.sbprint(&b, "\x1b[?25l")
	}

	fmt.print(strings.to_string(b))
}

draw_status_bar :: proc(b: ^strings.Builder) {
	mode_color: string
	mode_name: string

	switch screen.mode {
	case .Insert:
		mode_color, mode_name = "\x1b[30;44m", " INSERT "
	case .Motion:
		mode_color, mode_name = "\x1b[30;42m", " MOTION "
	case .Switch:
		mode_color, mode_name = "\x1b[30;43m", " SWITCH "
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
	row_data: []Glyph,
	view_w: int,
	is_in_selection: bool,
) {
	curr_fg, curr_bg: u32 = 0xFFFFFFFF, 0xFFFFFFFF
	curr_mode: GlyphMode = {}

	for x in 0 ..< view_w {
		glyph := row_data[x]
		// is_cursor := (x == screen.cursor_x && y == screen.cursor_y)

		// if is_cursor || is_in_selection {
		if is_in_selection {
			fmt.sbprint(b, "\x1b[0m")
			// if is_cursor {
			// 	fmt.sbprint(b, "\x1b[7m")
			// } else if is_in_selection {
			fmt.sbprint(b, "\x1b[48;5;239m")
			// }
			curr_fg, curr_bg = 0xFFFFFFFF, 0xFFFFFFFF
			curr_mode = {}
		} else {
			if glyph.mode != curr_mode || glyph.fg != curr_fg || glyph.bg != curr_bg {
				fmt.sbprint(b, "\x1b[0m")

				if glyph.fg == DEFAULT_FG {
					fmt.sbprint(b, "\x1b[39m")
				} else if .TrueColorFG in glyph.mode {
					r := (glyph.fg >> 16) & 0xFF
					g := (glyph.fg >> 8) & 0xFF
					bl := glyph.fg & 0xFF
					fmt.sbprintf(b, "\x1b[38;2;%d;%d;%dm", r, g, bl)
				} else {
					fmt.sbprintf(b, "\x1b[38;5;%dm", glyph.fg)
				}

				if glyph.bg == DEFAULT_BG {
					fmt.sbprint(b, "\x1b[49m")
				} else if .TrueColorBG in glyph.mode {
					r := (glyph.bg >> 16) & 0xFF
					g := (glyph.bg >> 8) & 0xFF
					bl := glyph.bg & 0xFF
					fmt.sbprintf(b, "\x1b[48;2;%d;%d;%dm", r, g, bl)
				} else {
					fmt.sbprintf(b, "\x1b[48;5;%dm", glyph.bg)
				}

				if .Bold in glyph.mode do fmt.sbprint(b, "\x1b[1m")
				if .Italic in glyph.mode do fmt.sbprint(b, "\x1b[3m")
				if .Underline in glyph.mode do fmt.sbprint(b, "\x1b[4m")

				curr_fg, curr_bg, curr_mode = glyph.fg, glyph.bg, glyph.mode
			}
		}
		fmt.sbprint(b, glyph.char == 0 ? ' ' : glyph.char)
	}
	fmt.sbprint(b, "\x1b[0m")
}

