package smut

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/darwin"
import "core:sys/posix"

TIOCSWINSZ :: 0x80087467 when ODIN_OS == .Darwin else 0x5414
TIOCSCTTY :: 0x20007461 when ODIN_OS == .Darwin else 0x540E
SIGWINCH :: 28

foreign import libc "system:c"
foreign libc {
	signal :: proc(sig: i32, handler: rawptr) -> rawptr ---
}
manager: Manager
should_resize := true

main :: proc() {
	manager.tabs = make([dynamic]Tab)

	setup_terminal()
	defer restore_terminal()

	if !spawn_tab(&manager) {
		fmt.eprintln("Failed to spawn initial shell")
		return
	}

	buf: [65336]byte
	running := true

	for running && len(manager.tabs) > 0 {
		active := &manager.tabs[manager.active]

		if should_resize {
			should_resize = false
			resize_screen(active.screen, active.fd)
			fmt.print("\x1b[2J")
		}

		// 1. Build PollFDs (Snapshot of current state)
		fds := make([dynamic]posix.pollfd, context.temp_allocator)
		append(&fds, posix.pollfd{fd = posix.STDIN_FILENO, events = {.IN}})
		for t in manager.tabs {
			append(&fds, posix.pollfd{fd = t.fd, events = {.IN, .HUP, .ERR}})
		}

		// 2. Poll
		if posix.poll(raw_data(fds), cast(u32)len(fds), -1) < 0 do continue

		ui_dirty := false

		// 3. Handle STDIN (User Input) - May modify manager.tabs (add tabs)
		if .IN in fds[0].revents {
			n := posix.read(posix.STDIN_FILENO, &buf[0], len(buf))
			if n > 0 {
				act := handle_input(active.screen, buf[:n], active.fd)
				switch act {
				case .None:
				case .Redraw:
					ui_dirty = true
				case .CreateTab:
					spawn_tab(&manager);ui_dirty = true
				case .NextTab:
					manager.active = (manager.active + 1) % len(manager.tabs)
					should_resize = true
				case .PrevTab:
					manager.active = (manager.active - 1 + len(manager.tabs)) % len(manager.tabs)
					should_resize = true
				case .Quit:
					running = false
				}
			}
		}

		// 4. Handle PTYs (Background & Active)
		// CRITICAL FIX: Only iterate over tabs that existed when fds was built.
		// fds[0] is STDIN, so fds[1..] correspond to tabs[0..]
		tabs_polled := len(fds) - 1

		for i := tabs_polled - 1; i >= 0; i -= 1 {
			revents := fds[i + 1].revents
			t := &manager.tabs[i]

			if .HUP in revents || .ERR in revents {
				close_tab(&manager, i)
				should_resize = true
				continue
			}

			if .IN in revents {
				n := posix.read(t.fd, &buf[0], len(buf))
				if n > 0 {
					process_output(t.screen, buf[:n], t.fd)
					if i == manager.active {
						ui_dirty = true
						if len(t.screen.reply_buf) > 0 {
							posix.write(t.fd, &t.screen.reply_buf[0], len(t.screen.reply_buf))
							clear(&t.screen.reply_buf)
						}
					}
				} else {
					close_tab(&manager, i)
					should_resize = true
				}
			}
		}

		if (ui_dirty || should_resize) && len(manager.tabs) > 0 {
			draw_screen(manager.tabs[manager.active].screen, &manager)
		}
	}
}

spawn_tab :: proc(mgr: ^Manager) -> bool {
	master, slave: posix.FD
	if openpty(&master, &slave) != 0 do return false

	pid := posix.fork()
	if pid == 0 {
		posix.close(master)
		login_tty(slave)
		shell := os.get_env("SHELL")
		if shell == "" do shell = "/bin/sh"
		cpath := strings.clone_to_cstring(shell)
		cname := strings.clone_to_cstring(filepath.base(shell))
		posix.execl(cpath, cname, nil)
		posix.exit(1)
	}

	posix.close(slave)
	posix.fcntl(master, .SETFL, posix.O_NONBLOCK)

	s := new(Screen)
	s.width, s.height = 80, 24
	init_cursor(s)

	append(&mgr.tabs, Tab{fd = master, pid = pid, screen = s, title = "shell"})
	mgr.active = len(mgr.tabs) - 1
	resize_screen(s, master)
	return true
}

close_tab :: proc(mgr: ^Manager, idx: int) {
	if idx < 0 || idx >= len(mgr.tabs) do return
	t := mgr.tabs[idx]
	posix.close(t.fd)
	ordered_remove(&mgr.tabs, idx)
	if mgr.active >= len(mgr.tabs) do mgr.active = max(0, len(mgr.tabs) - 1)
}

setup_terminal :: proc() {
	t: posix.termios
	posix.tcgetattr(posix.STDIN_FILENO, &t)
	raw := t
	raw.c_iflag -= {.IGNBRK, .BRKINT, .PARMRK, .ISTRIP, .INLCR, .IGNCR, .ICRNL, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_lflag -= {.ECHO, .ECHONL, .ICANON, .ISIG, .IEXTEN}
	raw.c_cflag -= {.PARENB}
	raw.c_cflag += {.CS8}
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw)
	fmt.print("\x1b[?1049h\x1b[?25l")
	signal(SIGWINCH, rawptr(handle_winch))
}

restore_terminal :: proc() {
	fmt.print("\x1b[?1049l\x1b[?25h")
}

handle_winch :: proc "c" (sig: i32) {
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
	amaster^, aslave^ = cast(posix.FD)master, cast(posix.FD)slave
	return 0
}

login_tty :: proc(fd: posix.FD) {
	posix.setsid()
	darwin.syscall_ioctl(cast(i32)fd, TIOCSCTTY, nil)
	posix.dup2(fd, 0);posix.dup2(fd, 1);posix.dup2(fd, 2)
	if fd > 2 do posix.close(fd)
}

set_window_size :: proc(fd: posix.FD, cols, rows: int) {
	ws := struct {
		r, c, x, y: u16,
	}{u16(rows), u16(cols), 0, 0}
	darwin.syscall_ioctl(cast(i32)fd, TIOCSWINSZ, &ws)
}

init_cursor :: proc(s: ^Screen) {
	s.cursor_visible = true
	s.cursor_style = 2
}

