package smut

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/darwin"
import "core:sys/posix"

foreign import libc "system:c"
foreign libc {
	// ioctl :: proc(fd: i32, request: u32, arg: rawptr) -> i32 ---
	signal :: proc(sig: i32, handler: rawptr) -> rawptr ---
}


SIGWINCH :: 28
TIOCSWINSZ :: 0x80087467
TIOCSCTTY :: 0x540E

screen: Screen
should_resize := true
main :: proc() {
	master_fd, butler_fd: posix.FD

	// Signal Handler for Resizing 
	signal(SIGWINCH, rawptr(handle_winch))

	if openpty(&master_fd, &butler_fd) != 0 {
		fmt.eprintln("Failed to create PTY")
		return
	}

	resize_screen(&screen, master_fd)

	pid := posix.fork()
	if pid == 0 {
		// --- CHILD ---
		posix.close(master_fd)
		login_tty(butler_fd)
		// Set initial size for the shell based on fetched dimensions
		set_window_size(butler_fd, screen.width - GUTTER_W, screen.height - 1)
		// shell_path := os.get_env("SHELL")
		// cpath := strings.clone_to_cstring(shell_path)
		// shell_name := filepath.base(shell_path)
		// cname := strings.clone_to_cstring(shell_name)
		args := [2]cstring{"fish", nil}
		posix.execvp("/run/current-system/sw/bin/fish", &args[0])
		posix.exit(1)
	}

	// --- PARENT ---
	posix.close(butler_fd)

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


// Global signal handler for SIGWINCH (Window Size Change)
handle_winch :: proc "c" (sig: i32) {
	// We cannot do complex logic in a signal handler.
	// We simply flag that a resize is needed for the main loop.
	context = runtime.default_context()
	should_resize = true
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
	darwin.syscall_ioctl(cast(i32)fd, TIOCSCTTY, nil) // TIOCSCTTY
	posix.dup2(fd, 0)
	posix.dup2(fd, 1)
	posix.dup2(fd, 2)
	if fd > 2 do posix.close(fd)
}

set_window_size :: proc(fd: posix.FD, cols, rows: int) {
	ws := struct {
		r, c, x, y: u16,
	}{u16(rows), u16(cols), 0, 0}
	// ioctl(cast(i32)fd, 0x5414, &ws) // TIOCSWINSZ
	darwin.syscall_ioctl(cast(i32)fd, TIOCSWINSZ, &ws) //TIOCSWINSZ
}

cfmakeraw :: proc(t: ^posix.termios) {
	t.c_iflag -= {.IGNBRK, .BRKINT, .PARMRK, .ISTRIP, .INLCR, .IGNCR, .ICRNL, .IXON}
	t.c_oflag -= {.OPOST}
	t.c_lflag -= {.ECHO, .ECHONL, .ICANON, .ISIG, .IEXTEN}
	t.c_cflag -= {.PARENB}
	t.c_cflag += {.CS8}
}

