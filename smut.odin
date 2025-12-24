package smut

import "core:fmt"
import "core:sys/posix"

screen: Screen
should_resize := true

main :: proc() {
	master_fd, slave_fd: posix.FD

	// 1. Setup Signal Handler for Resizing [cite: 2]
	signal(28, rawptr(handle_winch)) // 28 is SIGWINCH on Linux

	if openpty(&master_fd, &slave_fd) != 0 {
		fmt.eprintln("Failed to create PTY")
		return
	}

	// 2. Initial Size Setup before child starts
	resize_screen(&screen, master_fd)

	pid := posix.fork()

	if pid == 0 {
		// --- CHILD ---
		posix.close(master_fd)
		login_tty(slave_fd)
		// Set initial size for the shell based on fetched dimensions
		set_window_size(slave_fd, screen.width - GUTTER_W, screen.height - 1)
		posix.execl("/bin/bash", "bash", nil)
		posix.exit(1)
	}

	// --- PARENT ---
	posix.close(slave_fd)

	// Raw Mode and Alternate Buffer Setup
	original_termios: posix.termios
	posix.tcgetattr(posix.STDIN_FILENO, &original_termios)
	raw := original_termios
	cfmakeraw(&raw)
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw)
	defer posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &original_termios)

	// Switch to alternate buffer and hide cursor 
	fmt.print("\x1b[?1049h\x1b[?25l")
	defer fmt.print("\x1b[?1049l\x1b[?25h")

	buf: [4096]byte
	running := true

	for running {
		if should_resize {
			should_resize = false
			resize_screen(&screen, master_fd)
			fmt.print("\x1b[2J") // Clear screen on resize 
		}

		fds := []posix.pollfd {
			{fd = posix.STDIN_FILENO, events = {.IN}},
			{fd = master_fd, events = {.IN}},
		}

		// wait for data
		if posix.poll(&fds[0], 2, -1) < 0 {
			continue
		}

		if .IN in fds[0].revents {
			n := posix.read(posix.STDIN_FILENO, &buf[0], len(buf))
			if n > 0 {
				handle_input(buf[:n], master_fd)
			}
		}

		if .IN in fds[1].revents {
			n := posix.read(master_fd, &buf[0], len(buf))
			if n <= 0 {running = false;break}
			process_output(&screen, buf[:n])
		}

		draw_screen()
	}
}

