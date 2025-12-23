package smut

import "core:strconv"
import "core:sys/posix"


Action :: enum u8 {
	MOVE_DOWN         = 'j',
	MOVE_UP           = 'k',
	MOVE_LEFT         = 'h',
	MOVE_RIGHT        = 'l',
	EXTEND_LINE_BELOW = 'x',
	EXTEND_LINE       = 'x',
	EXTEND_LINE_ABOVE = 'X',
	GOTO              = 'g',
}

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

handle_normal_command :: proc(b: u8, count: int) -> bool {
	cmd_executed := true
	switch b {
	case '0' ..= '9':
		cmd_executed = false // Don't clear buffer yet, we are still typing a number
	case 'j':
		if screen.cursor_y < screen.pty_cursor_y {
			screen.cursor_y = min(screen.pty_cursor_y, screen.cursor_y + count)
		} else {
			// scroll down towards live view
			screen.scroll_offset = max(0, screen.scroll_offset - count)
		}
	case 'k':
		if screen.cursor_y > 0 {
			screen.cursor_y -= count
		} else {
			// scroll up into dead view
			screen.scroll_offset = min(len(screen.scrollback), screen.scroll_offset + count)
		}
	case 'h':
		screen.cursor_x = max(0, screen.cursor_x - count)
	case 'l':
		screen.cursor_x = min(screen.width - 1, screen.cursor_x + count)
	case 'x':
		if !screen.is_selecting {
			screen.selection_start_y = screen.cursor_y
		}
		if count > 1 || screen.is_selecting {
			screen.cursor_y = min(screen.pty_cursor_y, screen.cursor_y + count)
		}
		screen.is_selecting = true

	case 'X':
		if !screen.is_selecting {
			screen.selection_start_y = screen.cursor_y
		}
		if count > 1 || screen.is_selecting {
			screen.cursor_y = max(0, screen.cursor_y - count)
		}
		screen.is_selecting = true
	case 'y':
		if screen.is_selecting {
			yank_selection(&screen)
		}
	case 'G':
		screen.scroll_offset = 0
		screen.cursor_y = screen.pty_cursor_y
	case 'i':
		screen.mode = .Insert
		screen.scroll_offset = 0
		screen.cursor_y = screen.pty_cursor_y
		screen.is_selecting = false
		screen.cmd_idx = 0 // Clear keys on mode switch
		cmd_executed = false
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

	return cmd_executed

}

handle_input :: proc(input: []u8, master_fd: posix.FD) {
	for &b in input {
		// Mode: NORMAL
		if screen.mode == .Normal {
			// 1. Enter Insert Mode

			// 2. Buffer the keystroke for the status bar
			status_bar_keystroke_buffer(b)

			// 3. Extract the numeric multiplier (if any)
			// We look at the buffer and find the digits at the start
			count := command_multiplier()

			// 4. Command Execution (Triggered by the last byte 'b')
			handle_normal_command(b, count)
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

