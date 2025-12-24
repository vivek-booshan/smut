package smut

import "base:runtime"
import "core:c"
import "core:os"
import "core:sys/darwin"
import "core:sys/posix"
import "core:sys/unix"

TIOCSWINSZ :: 0x80087467

foreign import libc "system:c"
foreign libc {
	ioctl :: proc(fd: i32, request: u32, arg: rawptr) -> i32 ---
	signal :: proc(sig: i32, handler: rawptr) -> rawptr ---
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
	ioctl(cast(i32)fd, 0x540E, nil) // TIOCSCTTY
	posix.dup2(fd, 0);posix.dup2(fd, 1);posix.dup2(fd, 2)
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

