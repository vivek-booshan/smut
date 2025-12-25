# smut
A Simple Multiplexing Unix Terminal

SMUT is a modal alternative to tmux inspired by st and modal editors

Mode Switch Key (Ctrl B) maybe i should do a?
Ctrl B + i : Insert Mode (regular terminal, should not impede with anything)
Ctrl B + n : Motion Mode (vim navigation + xX to select lines up and down)
Ctrl B + s : Select Mode (currently same as motion)

### TODO
- resizing when scrolling midway through history can cause crash
- certain things like hx do not load instantly
- colors not all the way working (see hx themes for ex)
- first input in motion/select mode doesn't include multiplier
- scroll messes with gutter display if not at current line
- decide if scroll should move cursor with it (probably not)
- implement b, B, e, E, t, T, f, F
- implement goto mode (maybe just make this current line specific?)
- implement vim style Select Mode in Select Mode 
