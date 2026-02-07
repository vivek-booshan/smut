package smut

import "core:strconv"
import "core:sys/posix"
import "core:unicode/utf8"

Motion :: enum u8 {
	None       = 0,
	Down       = 'j',
	Up         = 'k',
	Left       = 'h',
	Right      = 'l',
	HalfPgUp   = 21,
	HalfPgDn   = 4,
	WordBack   = 'b',
	WORDBack   = 'B',
	WordEnd    = 'e',
	WORDEnd    = 'E',
	FindFwd    = 'f',
	FindBack   = 'F',
	TillFwd    = 't',
	TillBack   = 'T',
	Visual     = 'v',
	VisualLine = 'V',
	Yank       = 'y',
	Goto       = 'g',
	Insert     = 'i',
	Esc        = 27,
	Leader     = 1,
}

handle_input :: proc(s: ^Screen, input: []u8, fd: posix.FD) -> Action {
	act := Action.None

	for &b, i in input {
		key := Motion(b)

		if key == .Leader {
			s.mode = .Switch
			s.cmd_idx = 0
			act = .Redraw
			continue
		}

		if s.mode == .Insert {
			posix.write(fd, &b, 1)
			continue
		}

		if key == .Esc {
			if s.in_alt_screen do break
			if !s.in_alt_screen {
				process_output(s, input[i:i + 1], fd)
				continue
			}
		}

		if s.ansi_state != .Ground {
			handle_ansi_byte(s, b, fd)
			continue
		}

		act = .Redraw

		switch s.mode {
		case .Switch:
			#partial switch cast(Action)b {
			case .Motion:
				s.mode = .Motion
			case .Visual:
				s.mode = .Visual
			case .Insert:
				s.mode = .Insert
			case .CreateTab, .CloseTab, .Redraw, .Quit:
				fallthrough
			case .NextTab, .PrevTab:
				return cast(Action)b

			}
		case .Motion, .Visual:
			buffer_key(s, rune(b))
			count := parse_count(s)
			handle_motion(s, key, count)

		case .Insert:
			posix.write(fd, &b, 1)
		}
	}
	return act
}

handle_motion :: proc(s: ^Screen, m: Motion, count: int) {
	ok := true
	h := max(1, (s.height - 1) / 2)

	#partial switch m {
	case .Down:
		move_vert(s, count)
	case .Up:
		move_vert(s, -count)
	case .HalfPgDn:
		move_vert(s, h * count)
	case .HalfPgUp:
		move_vert(s, -(h * count))
	case .Left:
		s.cursor_x = max(0, s.cursor_x - count)
	case .Right:
		s.cursor_x = min(s.width - 1, s.cursor_x + count)

	case .Visual:
		if s.mode != .Visual {
			s.mode = .Visual
			s.is_selecting = true
			s.selection_start_x = s.cursor_x
			s.selection_start_y = s.cursor_y
		} else {
			s.mode = .Motion
			s.is_selecting = false
		}

	case .Yank:
		if s.is_selecting {
			yank_selection(s)
			s.is_selecting = false
			s.mode = .Motion
		}

	case .Goto:
		s.scroll_offset = 0
		s.cursor_x = s.pty_cursor_x
		s.cursor_y = s.pty_cursor_y
	case .Esc:
		s.is_selecting = false
		s.mode = .Motion
	case:
		ok = false
	}

	if ok do s.cmd_idx = 0
}

move_vert :: proc(s: ^Screen, n: int) {
	dest := s.cursor_y + n
	if n > 0 {
		if dest <= s.pty_cursor_y {
			s.cursor_y = dest
		} else {
			s.cursor_y = s.pty_cursor_y
			s.scroll_offset = max(0, s.scroll_offset - n)
		}
	} else {
		if dest >= 0 {
			s.cursor_y = dest
		} else {
			s.cursor_y = 0
			limit := len(s.scrollback)
			s.scroll_offset = min(limit, s.scroll_offset - n)
		}
	}
}

buffer_key :: proc(s: ^Screen, r: rune) {
	if s.cmd_idx < len(s.cmd_buf) {
		s.cmd_buf[s.cmd_idx] = r
		s.cmd_idx += 1
	}
}

parse_count :: proc(s: ^Screen) -> int {
	len := 0
	for i in 0 ..< s.cmd_idx {
		if s.cmd_buf[i] >= '0' && s.cmd_buf[i] <= '9' {
			len += 1
		} else {
			break
		}
	}

	if len > 0 {
		if v, ok := strconv.parse_int(utf8.runes_to_string(s.cmd_buf[:len])); ok {
			return v
		}
	}
	return 1
}

