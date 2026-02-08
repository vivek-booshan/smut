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
- cursor details lost, find bug and resolve
- differential rendering to speed up display
- lines wrap around if > 80
- resize to smaller box will delete characters originally outside new box
- resizing when scrolling midway through history causes crash
- Implement scroll (maybe keep key focused?)
- implement goto mode (maybe just make this current line specific?)
- implement vim style Select Mode in Select Mode (almost)
- Kitty Graphics Protocol (is it even necessary?)
- Kitty Keyboard Protocol (is it even necessary?)
