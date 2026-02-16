package smut

import "core:fmt"
import "core:strconv"
import "core:sys/posix"
import "core:unicode/utf8"

ALT_SCREEN :: 1049

CAN :: 0x18
SUB :: 0x1a
ESC :: 27
BACKSPACE :: 8
BEL :: '\a'
DEL :: 127
CONTROLC0 :: 32

Esc :: enum u8 {
	RIS = 'c',
	IND = 'D',
	RI  = 'M',
}

Csi :: enum u8 {
	DA      = 'c',
	DSR     = 'n',
	ICH     = '@',
	CUU     = 'A',
	CUD     = 'B',
	CUF     = 'C',
	CUB     = 'D',
	VPA     = 'd',
	CHA     = 'G',
	CUP     = 'H',
	HVP     = 'f',
	ED      = 'J',
	EL      = 'K',
	IL      = 'L',
	DL      = 'M',
	DCH     = 'P',
	SU      = 'S',
	SD      = 'T',
	ECH     = 'X',
	SGR     = 'm',
	SM      = 'h',
	RM      = 'l',
	DECSUSR = 'q',
	DECSTBM = 'r',
}

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
		s.utf8_len = 0
	}
}

handle_ansi_byte :: proc(s: ^Screen, b: u8, fd: posix.FD) {
	if b == CAN || b == SUB {
		s.ansi_state = .Ground
		return
	}

	#partial switch s.ansi_state {
	case .Ground:
		if b == ESC {
			s.ansi_state = .Escape
		} else if b < CONTROLC0 {
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
		if b >= '0' && b <= '~' {
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
			handle_csi_dispatch(s, b, fd)
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
			handle_csi_dispatch(s, b, fd)
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
			handle_csi_dispatch(s, b, fd)
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
		} else if b == ESC {
			handle_osc_dispatch(s)
			s.ansi_state = .Escape
		} else {
			append(&s.osc_buf, b)
		}

	case:
		if b == BEL || b == ESC {
			s.ansi_state = .Ground
		}
	}
}

handle_esc_dispatch :: proc(s: ^Screen, b: u8) {
	switch cast(Esc)b {
	case .RIS:
	case .IND:
		handle_control_char(s, '\n', s.width)
	case .RI:
		s.cursor.y = max(0, s.cursor.y - 1)
	}
}

handle_osc_dispatch :: proc(s: ^Screen) {
}

handle_csi_dispatch :: proc(s: ^Screen, final: u8, fd: posix.FD) {
	params := s.parser_params[:]

	get_p :: proc(p: []int, idx: int, def: int) -> int {
		if idx < len(p) {
			val := p[idx]
			if val == 0 do return def
			return val
		}
		return def
	}

	switch cast(Csi)final {
	case .DA:
		if s.parser_private == '>' {
			resp := "\x1b[>41;350;0c"
			append(&s.reply_buf, ..transmute([]u8)resp)
		} else {
			resp := "\x1b[?62;c"
			append(&s.reply_buf, ..transmute([]u8)resp)
		}
	case .DSR:
		status := get_p(params, 0, 0)
		switch status {
		case 5:
			resp := "\x1b[0n"
			append(&s.reply_buf, ..transmute([]u8)resp)
		case 6:
			r := s.cursor.y + 1
			c := s.cursor.x + 1
			resp := fmt.tprintf("\x1b[%d;%dR", r, c)
			append(&s.reply_buf, ..transmute([]u8)resp)
		}
	case .ICH:
		handle_insert_char(s, get_p(params, 0, 1))
	case .CUU:
		dist := get_p(params, 0, 1)
		s.cursor.y = max(0, s.cursor.y - dist)
	case .CUD:
		dist := get_p(params, 0, 1)
		limit := s.scroll_bottom > 0 ? s.scroll_bottom : s.height - 2
		s.cursor.y = min(limit, s.cursor.y + dist)
	case .CUF:
		dist := get_p(params, 0, 1)
		s.cursor.x = min(s.width - 1, s.cursor.x + dist)
	case .CUB:
		dist := get_p(params, 0, 1)
		s.cursor.x = max(0, s.cursor.x - dist)
	case .VPA:
		r := get_p(params, 0, 1)
		s.cursor.y = clamp(r - 1, 0, s.height - 1)
	case .CHA:
		c := get_p(params, 0, 1)
		s.cursor.x = clamp(c - 1, 0, s.width - 1)
	case .CUP, .HVP:
		r := get_p(params, 0, 1)
		c := get_p(params, 1, 1)
		s.cursor.y = clamp(r - 1, 0, s.height - 2)
		s.cursor.x = clamp(c - 1, 0, s.width - 1)
	case .ED:
		handle_erase_in_display(s, get_p(params, 0, 0))
	case .EL:
		handle_erase_in_line(s, get_p(params, 0, 0))
	case .IL:
		handle_insert_lines(s, get_p(params, 0, 1))
	case .DL:
		if s.parser_private != '<' {
			handle_delete_lines(s, get_p(params, 0, 1))
		}
	case .DCH:
		handle_delete_char(s, get_p(params, 0, 1))
	case .SU:
		handle_scroll_up(s, get_p(params, 0, 1))
	case .SD:
		handle_scroll_down(s, get_p(params, 0, 1))
	case .ECH:
		handle_erase_char(s, get_p(params, 0, 1))
	case .SGR:
		handle_sgr_sequence(s, params)
	case .SM:
		if s.parser_private == '?' {
			mode := get_p(params, 0, 0)
			if mode == ALT_SCREEN && !s.in_alt_screen {
				s.in_alt_screen = true
				s.main_cursor.x = s.cursor.x
				s.main_cursor.y = s.cursor.y
				s.scroll_top = 0
				s.scroll_bottom = s.height - 1
				s.cursor.x, s.cursor.y = 0, 0
				s.pty_cursor.x, s.pty_cursor.y = 0, 0
				blank := blank_glyph(s)
				for i in 0 ..< len(s.alt_grid) {s.alt_grid[i] = blank}
				for i in 0 ..< len(s.dirty) {s.dirty[i] = true}
				resize_screen(s, fd)
			} else if mode == 25 {
				s.cursor_visible = true
			} else if mode == 1000 {
				s.mouse_mode = .X10
			} else if mode == 1002 {
				s.mouse_mode = .ButtonEvent
			} else if mode == 1003 {
				s.mouse_mode = .AnyEvent
			}
		}
	case .RM:
		if s.parser_private == '?' {
			mode := get_p(params, 0, 0)
			if mode == ALT_SCREEN && s.in_alt_screen {
				s.in_alt_screen = false
				s.cursor.x = s.main_cursor.x
				s.cursor.y = s.main_cursor.y
				for i in 0 ..< s.height {s.dirty[i] = true}
				resize_screen(s, fd)
			} else if mode == 25 {
				s.cursor_visible = false
			} else if mode == 1000 || mode == 1002 || mode == 1003 {
				s.mouse_mode = .None
			}
		}
	case .DECSUSR:
		if s.parser_intermediate == ' ' {
			style := get_p(params, 0, 0)
			s.cursor.style = cast(CursorStyle)style
		}
	case .DECSTBM:
		top := get_p(params, 0, 1)
		bot := get_p(params, 1, s.height)
		s.scroll_top = clamp(top - 1, 0, s.height - 1)
		s.scroll_bottom = clamp(bot - 1, 0, s.height - 1)
		s.cursor.x, s.cursor.y = 0, 0
	}

	s.pty_cursor.x = s.cursor.x
	s.pty_cursor.y = s.cursor.y
}

handle_insert_char :: proc(s: ^Screen, n: int) {
	if n <= 0 do return
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	row_start := s.cursor.y * s.width

	limit := min(n, s.width - s.cursor.x)
	if limit <= 0 do return

	src := row_start + s.cursor.x
	dst := row_start + s.cursor.x + limit
	count := s.width - (s.cursor.x + limit)

	if count > 0 {
		copy(grid[dst:dst + count], grid[src:src + count])
	}

	blank := blank_glyph(s)
	for i in 0 ..< limit {
		grid[src + i] = blank
	}
	s.dirty[s.cursor.y] = true
}

handle_delete_char :: proc(s: ^Screen, n: int) {
	if n <= 0 do return
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	row_start := s.cursor.y * s.width

	limit := min(n, s.width - s.cursor.x)
	if limit <= 0 do return

	src := row_start + s.cursor.x + limit
	dst := row_start + s.cursor.x
	count := s.width - (s.cursor.x + limit)

	if count > 0 {
		copy(grid[dst:dst + count], grid[src:src + count])
	}

	blank := blank_glyph(s)
	clear_start := row_start + s.width - limit
	for i in 0 ..< limit {
		grid[clear_start + i] = blank
	}
	s.dirty[s.cursor.y] = true
}

handle_erase_char :: proc(s: ^Screen, n: int) {
	if n <= 0 do return
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	row_start := s.cursor.y * s.width
	limit := min(n, s.width - s.cursor.x)

	blank := blank_glyph(s)
	for i in 0 ..< limit {
		grid[row_start + s.cursor.x + i] = blank
	}
	s.dirty[s.cursor.y] = true
}

handle_insert_lines :: proc(s: ^Screen, n: int) {
	if s.cursor.y < s.scroll_top || s.cursor.y > s.scroll_bottom do return
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	num := min(n, s.scroll_bottom - s.cursor.y + 1)

	for y := s.scroll_bottom; y >= s.cursor.y + num; y -= 1 {
		dst := y * s.width
		src := (y - num) * s.width
		copy(grid[dst:dst + s.width], grid[src:src + s.width])
		s.dirty[y] = true
	}

	blank := blank_glyph(s)
	for y := s.cursor.y; y < s.cursor.y + num; y += 1 {
		start := y * s.width
		for x in 0 ..< s.width {grid[start + x] = blank}
		s.dirty[y] = true
	}
}

handle_delete_lines :: proc(s: ^Screen, n: int) {
	if s.cursor.y < s.scroll_top || s.cursor.y > s.scroll_bottom do return
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	num := min(n, s.scroll_bottom - s.cursor.y + 1)

	for y := s.cursor.y; y <= s.scroll_bottom - num; y += 1 {
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
	old_y := s.cursor.y
	s.cursor.y = s.scroll_top
	handle_delete_lines(s, n)
	s.cursor.y = old_y
}

handle_scroll_down :: proc(s: ^Screen, n: int) {
	old_y := s.cursor.y
	s.cursor.y = s.scroll_top
	handle_insert_lines(s, n)
	s.cursor.y = old_y
}

handle_erase_in_line :: proc(s: ^Screen, mode: int) {
	row_start := s.cursor.y * s.width
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	blank := blank_glyph(s)

	CURSORTOEND :: 0
	STARTTOCURSOR :: 1
	WHOLELINE :: 2
	switch mode {
	case CURSORTOEND:
		for x in s.cursor.x ..< s.width {grid[row_start + x] = blank}
	case STARTTOCURSOR:
		for x in 0 ..< s.cursor.x + 1 {grid[row_start + x] = blank}
	case WHOLELINE:
		for x in 0 ..< s.width {grid[row_start + x] = blank}
	}
	s.dirty[s.cursor.y] = true
}
handle_erase_in_display :: proc(s: ^Screen, mode: int) {
	grid := s.in_alt_screen ? s.alt_grid : s.grid
	blank := blank_glyph(s)
	CURSORTOENDOFSCREEN :: 0
	WHOLESCREEN :: 2
	switch mode {
	case CURSORTOENDOFSCREEN:
		handle_erase_in_line(s, 0)
		for y in s.cursor.y + 1 ..< s.height - 1 {
			for x in 0 ..< s.width {grid[y * s.width + x] = blank}
			s.dirty[y] = true
		}
	case WHOLESCREEN:
		for i in 0 ..< len(grid) {grid[i] = blank}
		for i in 0 ..< s.height {s.dirty[i] = true}
	}
}

forward_mouse_request :: proc(m: MouseMode, seq: []u8, fd: posix.FD) -> bool {
	if m != .None {
		posix.write(fd, &seq[0], len(seq))
		return true
	}
	return false
}

// SGR: \x1b[<button;x;yM
handle_mouse_sequence :: proc(s: ^Screen, seq: []u8, fd: posix.FD) {
	if forward_mouse_request(s.mouse_mode, seq, fd) do return

	if s.mode != .Motion do return

	curr := 3

	// b
	start := curr
	for curr < len(seq) && seq[curr] >= '0' && seq[curr] <= '9' do curr += 1
	b_str := string(seq[start:curr])

	if curr >= len(seq) || seq[curr] != ';' do return
	curr += 1

	// x
	start = curr
	for curr < len(seq) && seq[curr] >= '0' && seq[curr] <= '9' do curr += 1

	if curr >= len(seq) || seq[curr] != ';' do return
	curr += 1

	// y
	start = curr
	for curr < len(seq) && seq[curr] >= '0' && seq[curr] <= '9' do curr += 1

	// M
	if curr < len(seq) && seq[curr] == 'M' {
		b, ok := strconv.parse_int(b_str)
		if !ok do return

		if b == SCROLLUP {
			limit := len(s.scrollback)
			s.scroll_offset = min(limit, s.scroll_offset + 3)
			s.needs_redraw = true
		} else if b == SCROLLDOWN {
			s.scroll_offset = max(0, s.scroll_offset - 3)
			s.needs_redraw = true
		}
	}
}

