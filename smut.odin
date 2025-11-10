package smut

import "core:c"
import "core:fmt"
import "core:os"
import "core:sys/linux"
import "core:sys/posix"

TIOCSCTTY :: 0x540E
TIOCSWINZ :: 0x5414

fd_t :: os.Handle
pid_t :: os.Pid

winsize :: struct {
	row: uint,
	col: uint,
}

openpty :: proc(
	amaster, aslave: ^os.Handle,
	name: string,
	termp: ^posix.termios,
	winp: ^winsize,
) -> int {
	master, slave: int
	slave_name: string

	if posix.grantpt(cast(posix.FD)master) != posix.result.OK {
		os.close(cast(os.Handle)master)
		return -1
	}
	if posix.unlockpt(cast(posix.FD)master) != posix.result.OK {
		os.close(cast(os.Handle)master)
		return -1
	}
	slave_name = cast(string)posix.ptsname(cast(posix.FD)master)

	return 0
}
// openpty :: proc(master_fd: os.Handle, termp: ^posix.termios, winp: ^winsize) -> os.Handle {
// 	posix.grantpt(cast(posix.FD)master_fd)
// 	posix.unlockpt(cast(posix.FD)master_fd)
// 	slave_name := posix.ptsname(cast(posix.FD)master_fd)
// 	if slave_name == nil {
// 		fmt.eprintln("posix.ptsname failed to get name")
// 		return -1
// 	}

// 	slave_fd, err := os.open(string(slave_name), os.O_RDWR | os.O_NOCTTY, 0)
// 	if err != nil {
// 		fmt.eprintln("could not open slave")
// 		return -2
// 	}

// 	if termp != nil {
// 		posix.tcsetattr(cast(posix.FD)slave_fd, posix.TC_Optional_Action.TCSAFLUSH, termp)
// 	}
// 	if winp != nil {
// 		linux.ioctl(cast(linux.Fd)slave_fd, TIOCSWINZ, cast(uintptr)winp)
// 	}

// 	return slave_fd
// }

forkpty :: proc(amaster: ^fd_t, name: string, termp: ^posix.termios, winp: ^winsize) -> pid_t {
	master_fd, err := os.open("/dev/ptmx", os.O_RDWR | os.O_NOCTTY, 0)
	if err != nil {
		fmt.eprintln("Could not open file")
		return -1
	}

	pid, err2 := os.fork()
	if err2 != nil {
		fmt.eprintln("Failed to fork")
		return -3
	}
	switch pid {
	case -1:
		fmt.eprintln("fork failed with", -1)
		return -1
	case 0:
		slave_fd := openpty(master_fd, termp, winp)
		login_tty(slave_fd)
	case:
		amaster^ = master_fd
		return pid
	}
	return -1
}

login_tty :: proc(slave_fd: fd_t) -> int {
	posix.setsid()
	linux.ioctl(cast(linux.Fd)slave_fd, TIOCSCTTY, 0)
	linux.dup2(cast(linux.Fd)slave_fd, cast(linux.Fd)os.stderr)
	linux.dup2(cast(linux.Fd)slave_fd, cast(linux.Fd)os.stdin)
	linux.dup2(cast(linux.Fd)slave_fd, cast(linux.Fd)os.stdout)
	return 0
}
