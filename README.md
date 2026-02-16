# smut
Simple Multiplexer for Unix Terminal

`smut` is a modal alternative to `tmux` inspired by `st` and modal editors

Mode Switch Key (Ctrl a) 
- Leader + i : Insert Mode (regular terminal, should not impede with anything)
- Leader + n : Motion Mode (vim navigation + xX to select lines up and down)
- Leader + s : Select Mode (currently same as motion)

`git switch tabs`
- Leader; h,l : Move Prev/Next Tabs
- Leader + c : Create Tab
- Leader + q : Close Tab (quits on last tab)
- Leader + Q : Quit
- Leader + R : Refresh

### TODO(OPTIMIZATION)
- move from grid of glyphs to ring of lines
- decouple view and data
- SIMD optimization for ansi parsing
- AoS to SoA of glyphs

### TODO(FEATURES)
- streamline x1b magic strings to readable code
- handle line wrapping
- basic client-session with mkfifo
- Investigate why throughput (compared to tmux) is faster on darwin and 4x slower on linux
- implement b, B, e, E, t, T, f, F (almost)
- optimize rendering to speed up display
- implement goto mode (maybe just make this current line specific?)
- implement vim style Select Mode in Select Mode (almost)

### FIX
- scroll messes with gutter display if not at current line
- decide if scroll should move cursor with it (probably not)
- lines wrap around if > 80 on active screen (history is fine)
- resize to smaller box will delete characters originally outside new box
- `time cat test.txt` on linux causes cursor to offset y+1 from current line

