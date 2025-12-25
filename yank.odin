package smut

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

foreign import libc "system:c"
foreign libc {system :: proc(command: cstring) -> i32 ---}

yank_selection :: yank_selection_to_clipboard
yank_selection_to_clipboard :: proc(s: ^Screen) {
	low := min(s.selection_start_y, s.cursor_y)
	high := max(s.selection_start_y, s.cursor_y)
	term_view_w := max(1, s.width - GUTTER_W)

	// 1. Build the string from the grid rows
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	for y in low ..< high + 1 {
		row_start := y * s.width

		// Find the last non-zero character to avoid yanking trailing nulls
		last_char_idx := 0
		for x in 0 ..< term_view_w {
			if s.grid[row_start + x].char != 0 {
				last_char_idx = x + 1
			}
		}

		for x in 0 ..< last_char_idx {
			g := s.grid[row_start + x]
			strings.write_rune(&builder, g.char)
		}

		// row_str := utf8.runes_to_string(s.grid[row_start:row_start + last_char_idx])
		// strings.write_string(&builder, row_str)
		if y < high {
			strings.write_byte(&builder, '\n')
		}

	}
	full_text := strings.to_string(builder)

	// 2. Pipe the text to the system clipboard
	// On Linux: xclip -selection clipboard
	// On macOS: pbcopy
	// Using a simple shell command for portability
	when ODIN_OS == .Darwin {
		pipe_to_command("pbcopy", full_text)
	} else when ODIN_OS == .Linux {
		pipe_to_command("xclip -selection clipboard", full_text)

	}
}

pipe_to_command :: proc(cmd: string, input: string) {
	// We use os.open to a pipe or a simple temporary file redirection
	// For a robust implementation in Odin, use core:os/process
	// Simpler hack using system():
	temp_file := "/tmp/smut_yank.txt"
	os.write_entire_file(temp_file, transmute([]u8)input)

	final_cmd := fmt.tprintf("cat %s | %s", temp_file, cmd)

	// Convert to C string for system() call
	c_cmd := strings.clone_to_cstring(final_cmd, context.temp_allocator)


	system(c_cmd)
	os.remove(temp_file)
}

