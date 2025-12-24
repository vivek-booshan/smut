package smut

import "core:strconv"
import "core:sys/posix"

INSERT :: 'i'
MOTION :: 'm'
SELECT :: 's'

MOVE_DOWN :: 'j'
MOVE_UP :: 'k'
MOVE_LEFT :: 'h'
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

status_bar_keystroke_buffer :: proc(b: u8) {
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
		if val, ok := strconv.parse_int(string(screen.cmd_buf[:digit_count])); ok {
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
		}
	case 'G':
		screen.scroll_offset = 0
		screen.cursor_y = screen.pty_cursor_y
	case 27:
		// ESC
		screen.is_selecting = false
	case:
		ok = false
	}

	if ok {
		screen.cmd_idx = 0
	}
	return ok
}

handle_select_inputs :: handle_motion_inputs

handle_input :: proc(input: []u8, master_fd: posix.FD) {
	for &b in input {
		// Mode: NORMAL
		k := Key(b)
		if k == .CTRLB {
			screen.mode = .Switch
			screen.cmd_idx = 0
			continue
		}

		if screen.mode == .Switch {
			// 2. Buffer the keystroke for the status bar
			status_bar_keystroke_buffer(b)
			handle_switch_inputs(b)
			continue
		}
		if screen.mode == .Motion || screen.mode == .Select {
			status_bar_keystroke_buffer(b)
			count := command_multiplier()
			if handle_motion_inputs(b, count) {
				continue
			}
		}

		if b == 27 {
			screen.mode = .Motion
			screen.cmd_idx = 0
			continue
		}

		posix.write(master_fd, &b, 1)
	}
}

