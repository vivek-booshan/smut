package smut

// TODO(Vivek): Investigate cursor/gutter misalignment on ssh
// NOTE(Vivek): after 80 characters \r\n sent --> two line feeds from auto wrap and explicit \n

// NOTE(Vivek): internal cursor only incr at explicit \n
// TODO(Vivek): abs(position) via \x1b[<y>;1H or avoid \n if line len == screen.width

// NOTE(Vivek): ptnl pty discrepency --> cursor / gutter highlight drift
// TODO(Vivek): sync height constants

// NOTE(Vivek): Resizing when in history causes crash
// NOTE(Vivek): Resizing in motion moves pty to cursor loc

import "core:fmt"
import "core:strings"
import "core:sys/posix"

MAX_SCROLLBACK :: 8192

resize_screen :: proc(s: ^Screen, pty_fd: posix.FD) {
	ws: struct {
		r, c, x, y: u16,
	}
	old_w, old_h := s.width, s.height

	if ioctl(posix.STDOUT_FILENO, TIOCGWINSZ, &ws) != -1 && ws.r > 0 {
		s.width, s.height = int(ws.c), int(ws.r)
	} else {
		s.width, s.height = 80, 24
	}

	if old_w != s.width || old_h != s.height || len(s.grid) == 0 {
		total_cells := s.width * s.height
		blank := blank_glyph(s)
		new_grid := make([dynamic]Glyph, total_cells)
		new_alt := make([dynamic]Glyph, total_cells)
		new_dirty := make([dynamic]bool, s.height)

		for i in 0 ..< total_cells {
			new_grid[i] = blank
			new_alt[i] = blank
		}

		if len(s.grid) > 0 {
			min_h := min(old_h, s.height)
			min_w := min(old_w, s.width)
			for y in 0 ..< min_h {
				src := y * old_w
				dst := y * s.width
				copy(new_grid[dst:dst + min_w], s.grid[src:src + min_w])
				copy(new_alt[dst:dst + min_w], s.alt_grid[src:src + min_w])
			}
			delete(s.grid)
			delete(s.alt_grid)
			delete(s.dirty)
		}

		s.grid = new_grid
		s.alt_grid = new_alt
		s.dirty = new_dirty
		s.cursor_x = clamp(s.cursor_x, 0, max(0, s.width - 1))
		s.cursor_y = clamp(s.cursor_y, 0, max(0, s.height - 2))
	}

	for i in 0 ..< s.height do if i < len(s.dirty) do s.dirty[i] = true

	pty_w := s.in_alt_screen ? s.width : s.width - GUTTER_W
	set_window_size(pty_fd, pty_w, s.height - 1)
}

process_output :: proc(s: ^Screen, data: []u8, fd: posix.FD) {
	for b in data do handle_ansi_byte(s, b, fd)
}

write_rune_to_grid :: proc(s: ^Screen, b: rune, current_w: int) {
	limit := s.height - 2
	if s.pty_cursor_x >= current_w {
		s.pty_cursor_x = 0
		s.pty_cursor_y += 1
		handle_scrolling(s)
	}
	if s.pty_cursor_y > limit {
		s.pty_cursor_y = limit
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

handle_scrolling :: proc(s: ^Screen) {
	limit :=
		(s.scroll_bottom > 0 && s.scroll_bottom < s.height - 1) ? s.scroll_bottom : s.height - 2
	if s.cursor_y <= limit do return

	s.cursor_y = limit
	if !s.in_alt_screen && s.scroll_top == 0 {
		line := make([]Glyph, s.width)
		copy(line, s.grid[0:s.width])
		append(&s.scrollback, line)
		s.total_lines_scrolled += 1
		if len(s.scrollback) > MAX_SCROLLBACK {
			delete(s.scrollback[0])
			ordered_remove(&s.scrollback, 0)
			if s.scroll_offset > 0 do s.scroll_offset = min(s.scroll_offset, len(s.scrollback))
		}
	}

	grid := s.in_alt_screen ? s.alt_grid : s.grid
	dst_start := s.scroll_top * s.width
	src_start := (s.scroll_top + 1) * s.width
	bytes := (limit - s.scroll_top) * s.width
	copy(grid[dst_start:], grid[src_start:src_start + bytes])

	clear_start := limit * s.width
	blank := blank_glyph(s)
	for i in 0 ..< s.width do grid[clear_start + i] = blank
	for i in s.scroll_top ..= limit do s.dirty[i] = true
}

draw_screen :: proc(s: ^Screen, mgr: ^Manager) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprint(&b, "\x1b[H\x1b[?25l")

	term_view_w := max(1, s.width - GUTTER_W)

	sy_min, sy_max, sx_start, sx_end := 0, 0, 0, 0
	if s.is_selecting {
		if s.selection_start_y < s.cursor_y {
			sy_min, sy_max = s.selection_start_y, s.cursor_y
			sx_start, sx_end = s.selection_start_x, s.cursor_x
		} else if s.selection_start_y > s.cursor_y {
			sy_min, sy_max = s.cursor_y, s.selection_start_y
			sx_start, sx_end = s.cursor_x, s.selection_start_x
		} else {
			sy_min, sy_max = s.cursor_y, s.cursor_y
			sx_start = min(s.selection_start_x, s.cursor_x)
			sx_end = max(s.selection_start_x, s.cursor_x)
		}
	}

	for y in 0 ..< s.height - 1 {
		abs_line := (s.total_lines_scrolled + y + 1) - s.scroll_offset
		row: []Glyph
		hist := false

		if s.in_alt_screen {
			start := y * s.width
			if start < len(s.alt_grid) do row = s.alt_grid[start:start + s.width]
		} else {
			row, hist = get_row_data(s, abs_line)
		}

		if !s.in_alt_screen {
			draw_gutter(&b, s, y, abs_line, hist)
		}

		view_w := s.in_alt_screen ? s.width : term_view_w
		cfg, cbg: u32 = 0xFFFFFFFF, 0xFFFFFFFF
		cmode: GlyphMode = {}

		for x in 0 ..< view_w {
			g := blank_glyph(s)
			if x < len(row) do g = row[x]

			sel := false
			if s.is_selecting && y >= sy_min && y <= sy_max {
				if y > sy_min && y < sy_max {
					sel = true
				} else if sy_min == sy_max {
					sel = x >= sx_start && x <= sx_end
				} else if y == sy_min {
					sel = x >= sx_start
				} else if y == sy_max {
					sel = x <= sx_end
				}
			}

			if sel {
				fmt.sbprint(&b, "\x1b[48;5;239m")
				cfg, cbg = 0xFFFFFFFF, 0xFFFFFFFF
			} else if g.mode != cmode || g.fg != cfg || g.bg != cbg {
				fmt.sbprint(&b, "\x1b[0m")
				if g.fg != DEFAULT_FG do render_color(&b, g.fg, true)
				if g.bg != DEFAULT_BG do render_color(&b, g.bg, false)
				if .Bold in g.mode do fmt.sbprint(&b, "\x1b[1m")
				if .Italic in g.mode do fmt.sbprint(&b, "\x1b[3m")
				cfg, cbg, cmode = g.fg, g.bg, g.mode
			}
			fmt.sbprint(&b, g.char == 0 ? ' ' : g.char)
			if sel do fmt.sbprint(&b, "\x1b[0m")
		}
		fmt.sbprint(&b, "\x1b[K\r\n")
		s.dirty[y] = false
	}

	draw_status_bar(&b, s, mgr)
	fmt.sbprint(&b, "\x1b[0m")

	if s.cursor_visible {
		off := s.in_alt_screen ? 1 : (1 + GUTTER_W)
		fmt.sbprintf(&b, "\x1b[%d;%dH\x1b[?25h", s.cursor_y + 1, s.cursor_x + off)

		style := s.cursor_style == 0 ? 2 : s.cursor_style
		fmt.sbprintf(&b, "\x1b[%d q", style)
	} else {
		fmt.sbprint(&b, "\x1b[?25l")
	}
	fmt.print(strings.to_string(b))
}

draw_status_bar :: proc(b: ^strings.Builder, s: ^Screen, mgr: ^Manager) {
	col, name: string

	switch s.mode {
	case .Motion:
		col, name = "\x1b[30;42m", " MOT "
	case .Switch:
		col, name = "\x1b[30;47m", " CMD "
	case .Insert:
		col, name = "\x1b[30;46m", " INS "
	case .Visual:
		col, name = "\x1b[30;45m", " VIS "
	}

	fmt.sbprint(b, col)
	fmt.sbprint(b, name)
	fmt.sbprint(b, "\x1b[0m ")

	for t, i in mgr.tabs {
		if i == mgr.active {
			fmt.sbprintf(b, "\x1b[7;1m %d \x1b[0m ", i + 1)
		} else {
			fmt.sbprintf(b, "\x1b[90m %d \x1b[0m ", i + 1)
		}
	}

	fmt.sbprint(b, "\x1b[K")
}

draw_gutter :: proc(b: ^strings.Builder, s: ^Screen, y, abs_line: int, hist: bool) {
	live := abs_line - s.total_lines_scrolled - 1
	if hist || (live >= 0 && live <= s.pty_cursor_y) {
		w := GUTTER_W - 1
		if y == s.cursor_y {
			fmt.sbprintf(b, "\x1b[33;49m%*d \x1b[0m", w, abs_line)
		} else {
			fmt.sbprintf(b, "\x1b[90;49m%*d \x1b[0m", w, abs(y - s.cursor_y))
		}
	} else {
		fmt.sbprintf(b, "\x1b[49m%*s", GUTTER_W, "")
	}
}

get_row_data :: proc(s: ^Screen, abs_line: int) -> ([]Glyph, bool) {
	start := max(1, s.total_lines_scrolled - len(s.scrollback) + 1)
	if abs_line < start do return nil, false

	if abs_line <= s.total_lines_scrolled {
		idx := abs_line - start
		if idx >= 0 && idx < len(s.scrollback) do return s.scrollback[idx], true
	} else {
		y := abs_line - s.total_lines_scrolled - 1
		if y >= 0 && y < s.height do return s.grid[y * s.width:], false
	}
	return nil, false
}

render_color :: proc(b: ^strings.Builder, col: u32, is_fg: bool) {
	pre := is_fg ? "38" : "48"
	if col > 255 {
		r, g, bl := (col >> 16) & 0xFF, (col >> 8) & 0xFF, col & 0xFF
		fmt.sbprintf(b, "\x1b[%s;2;%d;%d;%dm", pre, r, g, bl)
	} else {
		fmt.sbprintf(b, "\x1b[%s;5;%dm", pre, col)
	}
}

handle_control_char :: proc(s: ^Screen, b: rune, w: int) {
	switch b {
	case 8, 127:
		if s.cursor_x > 0 {
			s.cursor_x -= 1
			s.dirty[s.cursor_y] = true
		}
		s.pty_cursor_x = s.cursor_x
	case '\t':
		s.cursor_x = (s.cursor_x + 8) & ~int(7)
		if s.cursor_x >= w do s.cursor_x = w - 1
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

blank_glyph :: proc(s: ^Screen) -> Glyph {
	return Glyph {
		char = 0,
		fg = s.current_attr.fg,
		bg = s.current_attr.bg,
		mode = s.current_attr.mode,
	}
}

