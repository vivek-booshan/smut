package smut

import "core:fmt"
import "core:os"
import "core:sys/posix"

// TIOCSCTTY :: 0x540E
// TIOCSWINZ :: 0x5414

// fd_t :: os.Handle
// pid_t :: os.Pid

// winsize :: struct {
// 	row: uint,
// 	col: uint,
// }

// forkpty :: proc(amaster: ^fd_t, name: string, termp: ^posix.termios, winp: ^winsize) -> pid_t {
// 	master, slave, pid: int
// 	master_fd, err := os.open("/dev/ptmx", os.O_RDWR | os.O_NOCTTY, 0)
// 	if err != nil {
// 		fmt.eprintln("Could not open file")
// 		return -1
// 	}

// 	pid, err2 := os.fork()
// 	if err2 != nil {
// 		fmt.eprintln("Failed to fork")
// 		return -3
// 	}
// 	switch pid {
// 	case -1:
// 		fmt.eprintln("fork failed with", -1)
// 		return -1
// 	case 0:
// 		slave_fd := openpty(master_fd, termp, winp)
// 		login_tty(slave_fd)
// 	case:
// 		amaster^ = master_fd
// 		return pid
// 	}
// 	return -1
// }

forkpty :: proc(amaster: ^fd_t, name: string, termp: ^posix.termios, winp: ^winsize) -> pid_t {
	master, slave: os.Handle

	if openpty(&master, &slave, name, termp, winp) == -1 {
		return -1
	}
	pid, err := os.fork()
	switch pid {
	case -1:
		os.close(master)
		os.close(slave)
		fmt.eprintln("Fork failed with", -1)
		return -1

	case 0:
		os.close(master)
		if login_tty(slave) {
			os.exit(1)
		}
		return 0
	case:
		^amaster = master
		os.close(slave)
		return pid
	}
}
