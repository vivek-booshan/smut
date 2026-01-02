package smut

import "core:strconv"
import "core:sys/posix"
import "core:unicode/utf8"

INSERT :: 'i'
MOTION :: 'n'
SELECT :: 's'

MOVE_DOWN :: 'j'
MOVE_UP :: 'k'
MOVE_LEFT :: 'h'
HALF_PAGE_UP :: 21 // ctrl u
HALF_PAGE_DOWN :: 4 // ctrl d
MOVE_RIGHT :: 'l'
EXTEND_LINE_BELOW :: 'x'
EXTEND_LINE :: 'x'
EXTEND_LINE_ABOVE :: 'X'
YANK :: 'y'
GOTO :: 'g'

GotoAction :: enum u8 {
	LINE_START = 's',
	LINE_END   = 'l',
}

status_bar_keystroke_buffer :: proc(b: rune) {
	if screen.cmd_idx < len(screen.cmd_buf) {
		screen.cmd_buf[screen.cmd_idx] = b
		screen.cmd_idx += 1
	}
}

command_multiplier :: proc() -> int {
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
		if val, ok := strconv.parse_int(utf8.runes_to_string(screen.cmd_buf[:digit_count])); ok {
			count = val
		}
	}
	return count

}

handle_switch_inputs :: proc(b: u8) -> bool {
	ok := true

	switch b {
	case INSERT:
		screen.mode = .Insert
		screen.scroll_offset = 0
		screen.cursor_x = screen.pty_cursor_x
		screen.cursor_y = screen.pty_cursor_y
		screen.is_selecting = false
		screen.cmd_idx = 0 // Clear keys on mode switch
	case MOTION:
		screen.mode = .Motion
	case SELECT:
		screen.mode = .Select
	case:
		ok = false
	}
	return ok
}

handle_motion_inputs :: proc(b: u8, count: int) -> bool {
	ok := true
	half_page := max(1, (screen.height - 1) / 2)

	switch b {
	case '0' ..= '9':
		return true
	case MOVE_DOWN:
		if screen.cursor_y < screen.pty_cursor_y {
			screen.cursor_y = min(screen.pty_cursor_y, screen.cursor_y + count)
		} else {
			// scroll down towards live view
			screen.scroll_offset = max(0, screen.scroll_offset - count)
		}
	case MOVE_UP:
		if screen.cursor_y > 0 {
			screen.cursor_y -= count
		} else {
			// scroll up into dead view
			screen.scroll_offset = min(len(screen.scrollback), screen.scroll_offset + count)
		}
	case HALF_PAGE_DOWN:
		total_move := half_page * count
		if screen.cursor_y < screen.pty_cursor_y {
			screen.cursor_y = min(screen.pty_cursor_y, screen.cursor_y + total_move)
		} else {
			screen.scroll_offset = max(0, screen.scroll_offset - total_move)
		}
	case HALF_PAGE_UP:
		total_move := half_page * count
		if screen.cursor_y > 0 {
			screen.cursor_y = max(0, screen.cursor_y - total_move)
		} else {
			screen.scroll_offset = min(len(screen.scrollback), screen.scroll_offset + total_move)
		}
	case MOVE_LEFT:
		screen.cursor_x = max(0, screen.cursor_x - count)
	case MOVE_RIGHT:
		screen.cursor_x = min(screen.width - 1, screen.cursor_x + count)
	case EXTEND_LINE_BELOW:
		if !screen.is_selecting {
			screen.selection_start_y = screen.cursor_y
		}
		if count > 1 || screen.is_selecting {
			screen.cursor_y = min(screen.pty_cursor_y, screen.cursor_y + count)
		}
		screen.is_selecting = true

	case EXTEND_LINE_ABOVE:
		if !screen.is_selecting {
			screen.selection_start_y = screen.cursor_y
		}
		if count > 1 || screen.is_selecting {
			screen.cursor_y = max(0, screen.cursor_y - count)
		}
		screen.is_selecting = true
	case YANK:
		if screen.is_selecting {
			yank_selection(&screen)
			// screen.cursor_x = screen.pty_cursor_x
			// screen.cursor_y = screen.pty_cursor_y
			// screen.mode = .Insert
			screen.is_selecting = false
		}
	case 'G':
		screen.scroll_offset = 0
		screen.cursor_x = screen.pty_cursor_x
		screen.cursor_y = screen.pty_cursor_y
	case ESC:
		// ESC
		screen.is_selecting = false
	case:
		ok = false
	}

	if ok do screen.cmd_idx = 0
	return ok
}

handle_select_inputs :: handle_motion_inputs

handle_burst :: proc(input: []u8) {
	burst := len(input) > 5
	key_not_escape := Key(input[0]) != .ESCAPE
	if (burst && (screen.mode != .Insert) && key_not_escape) {
		screen.mode = .Insert
		screen.scroll_offset = 0
		screen.cursor_x = screen.pty_cursor_x
		screen.cursor_y = screen.pty_cursor_y
	}
}

handle_input :: proc(input: []u8, master_fd: posix.FD) {

	// NOTE (VIVEK): such a niche situation, do i even want to handle this?
	// handle_burst(input) // basically handle a paste event

	for &b, i in input {
		k := Key(b)

		if k == .LEADER {
			screen.mode = .Switch
			screen.cmd_idx = 0
			continue
		}

		if screen.mode == .Insert {
			posix.write(master_fd, &b, 1)
			continue
		}

		if k == .ESCAPE {
			if !screen.in_alt_screen {
				process_output(&screen, input[i:i + 1])
				continue
			}
		}

		if screen.ansi_state != .Ground {
			handle_ansi_byte(&screen, b)
			continue
		}

		switch screen.mode {
		case .Switch:
			status_bar_keystroke_buffer(rune(b))
			handle_switch_inputs(b)
		case .Motion, .Select:
			status_bar_keystroke_buffer(rune(b))
			count := command_multiplier()
			handle_motion_inputs(b, count)
		case .Insert:
			// technically unreachable
			posix.write(master_fd, &b, 1)
		}

	}
}

