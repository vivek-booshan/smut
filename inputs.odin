package smut

import "core:strconv"
import "core:sys/posix"
import "core:unicode/utf8"

SCROLLUP :: 64
SCROLLDOWN :: 65

Motion :: enum u8 {
	None     = 0,
	Down     = 'j',
	Up       = 'k',
	Left     = 'h',
	Right    = 'l',
	HalfPgUp = 21,
	HalfPgDn = 4,
	WordBack = 'b',
	WORDBack = 'B',
	WordEnd  = 'e',
	WORDEnd  = 'E',
	FindFwd  = 'f',
	FindBack = 'F',
	TillFwd  = 't',
	TillBack = 'T',
	Visual   = 'v',
	Line     = 'x',
	LineBack = 'X',
	Yank     = 'y',
	GotoEnd  = 'G',
	Insert   = 'i',
	Esc      = 27,
}

handle_input :: proc(s: ^Screen, input: []u8, fd: posix.FD) -> Action {
	act := Action.None

	if len(s.input_buf) > 0 {
		append(&s.input_buf, ..input)
	}

	data := (len(s.input_buf) > 0) ? s.input_buf[:] : input

	i := 0
	for i < len(data) {
		defer i += 1
		b := data[i]

		if b == KEY_ESC && i + 2 < len(data) && data[i + 1] == '[' && data[i + 2] == '<' {
			end_idx := -1
			for j := i + 3; j < len(data); j += 1 {
				if data[j] == 'M' || data[j] == 'm' {
					end_idx = j
					break
				}
			}
			if end_idx != -1 {
				seq := data[i:end_idx + 1]
				handle_mouse_sequence(s, seq, fd)
				i = end_idx
				continue
			} else {
				if len(s.input_buf) == 0 do append(&s.input_buf, ..data[i:])
				return act
			}
		}

		if b == KEY_LEADER {
			s.mode = .Switch
			s.cmd_idx = 0
			act = .Redraw
			continue
		}

		if s.mode == .Insert {
			posix.write(fd, &b, 1)
			continue
		}

		if b == KEY_ESC {
			// NOTE(Vivek): steal lone esc back in non-insert
			// Not sure if this is ideal or if we should enforce esc as 'q'
			// in other modes and remove this
			if (s.mode != .Insert) {
				if i + 1 == len(data) {
					handle_motion(s, .Esc, 1)
					continue
				}
			}

			if !s.in_alt_screen {
				process_output(s, input[i:i + 1], fd)
				continue
			} else {
				break
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
				s.scroll_offset = 0
				s.cursor.x = s.pty_cursor.x
				s.cursor.y = s.pty_cursor.y
				s.is_selecting = false
				s.cmd_idx = 0
			case .CreateTab, .CloseTab, .Redraw, .Quit:
				fallthrough
			case .NextTab, .PrevTab:
				return cast(Action)b

			}
		case .Motion, .Visual:
			buffer_key(s, rune(b))
			count := parse_count(s)
			handle_motion(s, cast(Motion)b, count)

		case .Insert:
			posix.write(fd, &b, 1)
		}
	}

	if len(s.input_buf) > 0 do clear(&s.input_buf)
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
		s.cursor.x = max(0, s.cursor.x - count)
	case .Right:
		s.cursor.x = min(s.width - 1, s.cursor.x + count)
	case .Line:
		if !s.is_selecting {
			s.selection_start_y = s.cursor.y
		}
		if count > 1 || s.is_selecting {
			s.cursor.y = min(s.pty_cursor.y, s.cursor.y + count)
		}
		s.is_selecting = true

	case .LineBack:
		if !s.is_selecting {
			s.selection_start_y = s.cursor.y
		}
		if count > 1 || s.is_selecting {
			s.cursor.y = max(0, s.cursor.y - count)
		}
		s.is_selecting = true
	case .Yank:
		if s.is_selecting {
			yank_selection(s)
			s.is_selecting = false
			s.mode = .Motion
		}
	case .GotoEnd:
		s.scroll_offset = 0
		s.cursor.x = s.pty_cursor.x
		s.cursor.y = s.pty_cursor.y
	case .Esc:
		if s.is_selecting {
			s.is_selecting = false
			s.cmd_idx = 0
		} else {
			s.mode = .Insert
		}
	case:
		ok = false
	}

	if ok do s.cmd_idx = 0
}

move_vert :: proc(s: ^Screen, n: int) {
	dest := s.cursor.y + n
	if n > 0 {
		if dest <= s.pty_cursor.y {
			s.cursor.y = dest
		} else {
			s.cursor.y = s.pty_cursor.y
			s.scroll_offset = max(0, s.scroll_offset - n)
		}
	} else {
		if dest >= 0 {
			s.cursor.y = dest
		} else {
			s.cursor.y = 0
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

