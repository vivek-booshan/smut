package smut

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

foreign import libc "system:c"
foreign libc {
	system :: proc(command: cstring) -> i32 ---
}

yank_selection :: proc(s: ^Screen) {
	text := capture_selection_text(s)
	defer delete(text)

	emit_osc52_sequence(text)
	dispatch_to_system_clipboard(text)
}

capture_selection_text :: proc(s: ^Screen) -> string {
	b := strings.builder_make()

	sy, ey := s.selection_start_y, s.cursor_y
	sx, ex := s.selection_start_x, s.cursor_x

	// Normalize coords
	if sy > ey || (sy == ey && sx > ex) {
		sy, ey = ey, sy
		sx, ex = ex, sx
	}

	width := max(1, s.width - GUTTER_W)

	for y in sy ..= ey {
		row_off := y * s.width
		start_col := (y == sy) ? sx : 0
		end_col := (y == ey) ? ex : width - 1

		// Clamp to actual line content
		content_len := 0
		for x in 0 ..< width {
			if s.grid[row_off + x].char != 0 do content_len = x + 1
		}

		iter_end := min(end_col, content_len - 1)

		for x in start_col ..= iter_end {
			strings.write_rune(&b, s.grid[row_off + x].char)
		}

		if y < ey {
			strings.write_byte(&b, '\n')
		}
	}

	return strings.to_string(b)
}

emit_osc52_sequence :: proc(text: string) {
	encoded := base64.encode(transmute([]u8)text)
	defer delete(encoded)

	fmt.printf("\x1b]52;c;%s\a", encoded)
}

dispatch_to_system_clipboard :: proc(text: string) {

	if os.get_env("SSH_TTY") != "" do return

	when ODIN_OS == .Darwin {
		spawn_clipboard_pipe("pbcopy", []string{}, text)
	} else when ODIN_OS == .Linux {
		if os.get_env("WAYLAND_DISPLAY") != "" {
			spawn_clipboard_pipe("wl-copy", []string{}, text)
		} else {
			spawn_clipboard_pipe("xclip", []string{"-selection", "clipboard"}, text)
		}
	}
}

spawn_clipboard_pipe :: proc {
	spawn_clipboard_pipe_external,
	spawn_clipboard_pipe_internal,
}

// NOTE(Vivek): Not safe and needs to be reimplemented in future with safer method. 
// Also technically slow as it needs to spawn a shell for cat
spawn_clipboard_pipe_external :: proc(method: string, input: string) {
	pid := posix.getpid()
	path := fmt.tprintf("/tmp/smut_yank_%d.txt", pid)

	if !os.write_entire_file(path, transmute([]u8)input) do return

	shell_cmd := fmt.tprintf("cat %s | %s", path, method)
	c_str := strings.clone_to_cstring(shell_cmd, context.temp_allocator)

	system(c_str)
	os.remove(path)
}

spawn_clipboard_pipe_internal :: proc(bin: string, args: []string, input: string) {
	pipes: [2]posix.FD
	if posix.pipe(&pipes) != .OK {
		return
	}

	pid := posix.fork()
	if pid < 0 {
		posix.close(pipes[0])
		posix.close(pipes[1])
		return
	}

	if pid == 0 {
		posix.close(pipes[1])
		posix.dup2(pipes[0], posix.STDIN_FILENO)
		posix.close(pipes[0])

		// Prepare args for execvp
		// execvp expects [bin, arg1, arg2, ..., nil]
		c_args := make([dynamic]cstring, context.temp_allocator)
		append(&c_args, strings.clone_to_cstring(bin, context.temp_allocator))
		for arg in args {
			append(&c_args, strings.clone_to_cstring(arg, context.temp_allocator))
		}
		append(&c_args, nil)

		posix.execvp(c_args[0], raw_data(c_args))
		posix.exit(1)
	}

	posix.close(pipes[0])

	data := transmute([]u8)input
	total_written: uint = 0
	for total_written < len(data) {
		n := posix.write(pipes[1], &data[total_written], len(data) - total_written)
		if n < 0 {
			break
		}
		total_written += cast(uint)n
	}

	posix.close(pipes[1])

	status: i32
	posix.waitpid(pid, &status, {})
}

