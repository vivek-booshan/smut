# smut
A Simple Multiplexing Unix Terminal

`smut` is a modal alternative to `tmux` inspired by `st` and modal editors

Mode Switch Key (Ctrl a) 
- Leader + i : Insert Mode (regular terminal, should not impede with anything)
- Leader + n : Motion Mode (vim navigation + xX to select lines up and down)
- Leader + s : Select Mode (currently same as motion)

`git switch tabs`
- Leader + h,l : Move Prev/Next Tabs
- Leader + c : Create Tab
- Leader + q : Close Tab (quits on last tab)
- Leader + Q : Quit
- Leader + R : Refresh

### TODO
- resizing when scrolling midway through history can cause crash
- first input in motion/select mode doesn't include multiplier
- scroll messes with gutter display if not at current line
- decide if scroll should move cursor with it (probably not)
- implement b, B, e, E, t, T, f, F (almost)
- implement goto mode (maybe just make this current line specific?)
- implement vim style Select Mode in Select Mode (almost)
- Kitty Graphics Protocol (is it even necessary?)
- Kitty Keyboard Protocol (is it even necessary?)
