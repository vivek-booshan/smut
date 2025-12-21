package smut

import "core:fmt"
import "core:os"
import "core:sys/linux"
import "core:sys/posix"

// --- Configuration ---
TERM_W :: 80
TERM_H :: 24
GUTTER_W :: 4

// --- Virtual Screen Structure ---
Screen :: struct {
	grid:     [TERM_H][TERM_W]u8,
	cursor_x: int,
	cursor_y: int,
	mode:     enum {
		Normal,
		Visual,
	},
}

screen: Screen

// --- Manual Foreign Import for ioctl ---
// core:sys/linux sometimes hides ioctl behind sys_ioctl or it's variadic.
// Defining it manually ensures it works.
foreign import libc "system:c"
foreign libc {
	ioctl :: proc(fd: i32, request: u32, arg: rawptr) -> i32 ---
}

main :: proc() {
	master_fd, slave_fd: posix.FD

	if openpty(&master_fd, &slave_fd) != 0 {
		fmt.eprintln("Failed to create PTY")
		return
	}

	// FIX 1: Use posix.fork (returns 1 value)
	pid := posix.fork()

	if pid == 0 {
		// --- CHILD ---
		posix.close(master_fd)
		login_tty(slave_fd)
		set_window_size(slave_fd, TERM_W - GUTTER_W, TERM_H)
		posix.execl("/bin/bash", "bash", nil)
		posix.exit(1)
	}

	// --- PARENT ---
	posix.close(slave_fd)

	// Raw Mode Setup
	original_termios: posix.termios
	posix.tcgetattr(posix.STDIN_FILENO, &original_termios)
	raw := original_termios
	cfmakeraw(&raw)
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw)
	defer posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &original_termios)

	fmt.print("\x1b[2J\x1b[H")

	buf: [1024]byte
	running := true

	for running {
		draw_screen()

		// FIX 2: Use .IN instead of .POLLIN
		fds := []posix.pollfd {
			{fd = posix.STDIN_FILENO, events = {.IN}},
			{fd = master_fd, events = {.IN}},
		}

		posix.poll(&fds[0], 2, -1)

		// FIX 3: Check .IN
		if .IN in fds[0].revents {
			// FIX 4: posix.read returns 1 value (ssize_t)
			n := posix.read(posix.STDIN_FILENO, &buf[0], 1024)
			if n > 0 {
				if buf[0] == 2 { 	// Ctrl-B
					if screen.mode == .Normal {screen.mode = .Visual} else {screen.mode = .Normal}
					continue
				}

				if screen.mode == .Visual {
					if buf[0] == 'j' && screen.cursor_y < TERM_H - 1 {screen.cursor_y += 1}
					if buf[0] == 'k' && screen.cursor_y > 0 {screen.cursor_y -= 1}
					if buf[0] == 'q' {screen.mode = .Normal}
					continue
				}

				// FIX 5: cast n to uint (size_t)
				posix.write(master_fd, &buf[0], cast(uint)n)
			}
		}

		if .IN in fds[1].revents {
			n := posix.read(master_fd, &buf[0], 1024)
			if n <= 0 {running = false;break}
			process_output(&screen, buf[:n])
		}
	}
}

process_output :: proc(s: ^Screen, data: []u8) {
	for b in data {
		switch b {
		case '\n':
			s.cursor_y += 1
			if s.cursor_y >= TERM_H {
				s.cursor_y = TERM_H - 1
				for y in 0 ..< TERM_H - 1 {
					s.grid[y] = s.grid[y + 1]
				}
				for x in 0 ..< TERM_W {s.grid[TERM_H - 1][x] = 0}
			}
		case '\r':
			s.cursor_x = 0
		case 8:
			// Backspace
			if s.cursor_x > 0 {s.cursor_x -= 1}
		case:
			if b >= 32 && b <= 126 {
				if s.cursor_x < (TERM_W - GUTTER_W) {
					s.grid[s.cursor_y][s.cursor_x] = b
					s.cursor_x += 1
				}
			}
		}
	}
}

draw_screen :: proc() {
	fmt.print("\x1b[?25l\x1b[H")

	for y in 0 ..< TERM_H {
		rel_num := abs(y - screen.cursor_y)

		if y == screen.cursor_y {
			fmt.printf("\x1b[33m%3d \x1b[0m", y + 1)
		} else {
			fmt.printf("\x1b[90m%3d \x1b[0m", rel_num)
		}

		for x in 0 ..< (TERM_W - GUTTER_W) {
			char := screen.grid[y][x]
			if char == 0 {fmt.print(" ")} else {fmt.printf("%c", char)}
		}
		fmt.print("\r\n")
	}

	if screen.mode == .Visual {
		fmt.print("\x1b[30;41m -- VISUAL -- [j/k] to move, [q] to quit \x1b[0m")
	} else {
		fmt.print("\x1b[30;42m -- NORMAL -- [Ctrl-B] for Visual        \x1b[0m")
	}

	fmt.print("\x1b[?25h")
}

openpty :: proc(amaster, aslave: ^posix.FD) -> int {
	master, err := os.open("/dev/ptmx", os.O_RDWR | os.O_NOCTTY)
	if err != nil do return -1

	if posix.grantpt(cast(posix.FD)master) != .OK do return -1
	if posix.unlockpt(cast(posix.FD)master) != .OK do return -1

	slave_name := posix.ptsname(cast(posix.FD)master)
	slave, err_s := os.open(cast(string)slave_name, os.O_RDWR | os.O_NOCTTY)
	if err_s != nil do return -1

	amaster^ = cast(posix.FD)master
	aslave^ = cast(posix.FD)slave
	return 0
}

login_tty :: proc(fd: posix.FD) {
	posix.setsid()
	// FIX 6: Use our manual ioctl wrapper
	ioctl(cast(i32)fd, 0x540E, nil) // TIOCSCTTY
	posix.dup2(fd, 0);posix.dup2(fd, 1);posix.dup2(fd, 2)
	if fd > 2 do posix.close(fd)
}

set_window_size :: proc(fd: posix.FD, cols, rows: int) {
	ws := struct {
		r, c, x, y: u16,
	}{u16(rows), u16(cols), 0, 0}
	// FIX 6: Use manual ioctl wrapper
	ioctl(cast(i32)fd, 0x5414, &ws) // TIOCSWINSZ
}

cfmakeraw :: proc(t: ^posix.termios) {
	t.c_iflag -= {.IGNBRK, .BRKINT, .PARMRK, .ISTRIP, .INLCR, .IGNCR, .ICRNL, .IXON}
	t.c_oflag -= {.OPOST}
	t.c_lflag -= {.ECHO, .ECHONL, .ICANON, .ISIG, .IEXTEN}
	// FIX 7: Remove .CSIZE (it's often a mask, not a flag)
	t.c_cflag -= {.PARENB}
	t.c_cflag += {.CS8}
}

