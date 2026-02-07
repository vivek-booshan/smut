package smut

import "core:strconv"
import "core:sys/posix"
import "core:unicode/utf8"

Motion :: enum u8 {
	None        = 0,
	Down        = 'j',
	Up          = 'k',
	Left        = 'h',
	Right       = 'l',
	HalfPgUp    = 21,
	HalfPgDn    = 4,
	WordBack    = 'b',
	WORDBack    = 'B',
	WordEnd     = 'e',
	WORDEnd     = 'E',
	FindFwd     = 'f',
	FindBack    = 'F',
	TillFwd     = 't',
	TillBack    = 'T',
	ExtendBelow = 'x',
	ExtendAbove = 'X',
	Yank        = 'y',
	Goto        = 'g',
	Insert      = 'i',
	Visual      = 'n',
	Select      = 's',
	Esc         = 27,
	Leader      = 1,
}

Class :: enum {
	Space,
	Alnum,
	Symbol,
}

classify :: proc(r: rune, big: bool) -> Class {
	if r <= 32 do return .Space
	if big do return .Alnum

	is_alnum :=
		(r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_'

	if is_alnum do return .Alnum
	return .Symbol
}

handle_input :: proc(input: []u8, fd: posix.FD) -> bool {
	dirty := false

	for &b, i in input {
		key := Motion(b)

		if key == .Leader {
			screen.mode = .Switch
			screen.cmd_idx = 0
			dirty = true
			continue
		}

		if screen.mode == .Insert {
			posix.write(fd, &b, 1)
			continue
		}

		if key == .Esc {
			if screen.in_alt_screen do break
			if !screen.in_alt_screen {
				process_output(&screen, input[i:i + 1])
				continue
			}
		}

		if screen.ansi_state != .Ground {
			handle_ansi_byte(&screen, b)
			continue
		}

		dirty = true

		switch screen.mode {
		case .Switch:
			buffer_key(rune(b))
			handle_switch(key)
		case .Motion, .Select:
			buffer_key(rune(b))
			count := parse_count()
			handle_motion(key, count)
		case .Insert:
			posix.write(fd, &b, 1)
		}
	}
	return dirty
}

handle_switch :: proc(m: Motion) -> bool {
	#partial switch m {
	case .Insert:
		screen.mode = .Insert
		screen.scroll_offset = 0
		screen.cursor_x = screen.pty_cursor_x
		screen.cursor_y = screen.pty_cursor_y
		screen.is_selecting = false
		screen.cmd_idx = 0
	case .Visual:
		screen.mode = .Motion
	case .Select:
		screen.mode = .Select
	case:
		return false
	}
	return true
}

handle_motion :: proc(m: Motion, count: int) -> bool {
	ok := true
	h := max(1, (screen.height - 1) / 2)

	#partial switch m {
	case .Down:
		move_vert(count)
	case .Up:
		move_vert(-count)
	case .HalfPgDn:
		move_vert(h * count)
	case .HalfPgUp:
		move_vert(-(h * count))
	case .Left:
		screen.cursor_x = max(0, screen.cursor_x - count)
	case .Right:
		screen.cursor_x = min(screen.width - 1, screen.cursor_x + count)

	case .WordBack, .WORDBack:
		for _ in 0 ..< count do step_back(m == .WORDBack)
	case .WordEnd, .WORDEnd:
		for _ in 0 ..< count do step_end(m == .WORDEnd)

	case .FindFwd, .FindBack, .TillFwd, .TillBack:
		return true

	case .ExtendBelow:
		if !screen.is_selecting do screen.selection_start_y = screen.cursor_y
		move_vert(count)
		screen.is_selecting = true
	case .ExtendAbove:
		if !screen.is_selecting do screen.selection_start_y = screen.cursor_y
		move_vert(-count)
		screen.is_selecting = true

	case .Yank:
		if screen.is_selecting {
			yank_selection(&screen)
			screen.is_selecting = false
		}
	case .Goto:
		screen.scroll_offset = 0
		screen.cursor_x = screen.pty_cursor_x
		screen.cursor_y = screen.pty_cursor_y
	case .Esc:
		screen.is_selecting = false
	case:
		ok = try_complete_search(u8(m), count)
	}

	if ok do screen.cmd_idx = 0
	return ok
}

move_vert :: proc(n: int) {
	dest := screen.cursor_y + n

	if n > 0 {
		if dest <= screen.pty_cursor_y {
			screen.cursor_y = dest
		} else {
			screen.cursor_y = screen.pty_cursor_y
			screen.scroll_offset = max(0, screen.scroll_offset - n)
		}
	} else {
		if dest >= 0 {
			screen.cursor_y = dest
		} else {
			screen.cursor_y = 0
			limit := len(screen.scrollback)
			screen.scroll_offset = min(limit, screen.scroll_offset - n)
		}
	}
}

step_back :: proc(big: bool) {
	w := max(1, screen.width - GUTTER_W)
	x, y := screen.cursor_x, screen.cursor_y

	dec := proc(px, py, w: int) -> (int, int) {
		nx := px - 1
		if nx < 0 {
			return w - 1, py - 1
		}
		return nx, py
	}

	x, y = dec(x, y, w)
	if y < 0 {
		screen.cursor_x, screen.cursor_y = 0, 0
		return
	}

	for y >= 0 && classify(glyph_at(x, y), big) == .Space {
		x, y = dec(x, y, w)
	}
	if y < 0 {
		screen.cursor_x, screen.cursor_y = 0, 0
		return
	}

	kind := classify(glyph_at(x, y), big)
	for {
		nx, ny := dec(x, y, w)
		if ny < 0 || classify(glyph_at(nx, ny), big) != kind {
			break
		}
		x, y = nx, ny
	}

	screen.cursor_x = x
	screen.cursor_y = max(0, y)
}

step_end :: proc(big: bool) {
	w := max(1, screen.width - GUTTER_W)
	x, y := screen.cursor_x, screen.cursor_y
	lim := screen.pty_cursor_y

	inc :: proc(px, py, w: int) -> (int, int) {
		nx := px + 1
		if nx >= w {
			return 0, py + 1
		}
		return nx, py
	}

	x, y = inc(x, y, w)
	if y > lim {
		return
	}

	for y <= lim && classify(glyph_at(x, y), big) == .Space {
		x, y = inc(x, y, w)
	}
	if y > lim {
		screen.cursor_x, screen.cursor_y = w - 1, lim
		return
	}

	kind := classify(glyph_at(x, y), big)
	for {
		nx, ny := inc(x, y, w)
		if ny > lim || classify(glyph_at(nx, ny), big) != kind {
			break
		}
		x, y = nx, ny
	}

	screen.cursor_x = x
	screen.cursor_y = y
}

try_complete_search :: proc(char: u8, count: int) -> bool {
	if screen.cmd_idx < 2 do return false

	prev := Motion(screen.cmd_buf[screen.cmd_idx - 2])
	target := rune(char)
	w := max(1, screen.width - GUTTER_W)
	y := screen.cursor_y
	x := screen.cursor_x
	hits := 0

	#partial switch prev {
	case .FindFwd:
		for i in x + 1 ..< w {
			if screen.grid[y * screen.width + i].char == target {
				hits += 1
				if hits == count {
					screen.cursor_x = i
					return true
				}
			}
		}
	case .TillFwd:
		for i in x + 1 ..< w {
			if screen.grid[y * screen.width + i].char == target {
				hits += 1
				if hits == count {
					screen.cursor_x = i - 1
					return true
				}
			}
		}
	case .FindBack:
		for i := x - 1; i >= 0; i -= 1 {
			if screen.grid[y * screen.width + i].char == target {
				hits += 1
				if hits == count {
					screen.cursor_x = i
					return true
				}
			}
		}
	case .TillBack:
		for i := x - 1; i >= 0; i -= 1 {
			if screen.grid[y * screen.width + i].char == target {
				hits += 1
				if hits == count {
					screen.cursor_x = i + 1
					return true
				}
			}
		}
	case:
		return false
	}

	return true
}

glyph_at :: proc(x, y: int) -> rune {
	return screen.grid[y * screen.width + x].char
}

buffer_key :: proc(r: rune) {
	if screen.cmd_idx < len(screen.cmd_buf) {
		screen.cmd_buf[screen.cmd_idx] = r
		screen.cmd_idx += 1
	}
}

parse_count :: proc() -> int {
	len := 0
	for i in 0 ..< screen.cmd_idx {
		if screen.cmd_buf[i] >= '0' && screen.cmd_buf[i] <= '9' {
			len += 1
		} else {
			break
		}
	}

	if len > 0 {
		if v, ok := strconv.parse_int(utf8.runes_to_string(screen.cmd_buf[:len])); ok {
			return v
		}
	}
	return 1
}

