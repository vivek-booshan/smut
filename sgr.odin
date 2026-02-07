package smut

SGR_Code :: enum int {
	RESET          = 0,
	BOLD           = 1,
	FAINT          = 2,
	ITALIC         = 3,
	UNDERLINE      = 4,
	BLINK          = 5,
	REVERSE        = 7,
	INVISIBLE      = 8,
	STRIKE         = 9,
	NORMAL_WEIGHT  = 22,
	NOT_ITALIC     = 23,
	NOT_UNDERLINED = 24,
	NOT_BLINKING   = 25,
	NOT_REVERSED   = 27,
	NOT_INVISIBLE  = 28,
	NOT_STRUCK     = 29,
	FG_EXTENDED    = 38,
	FG_DEFAULT     = 39,
	BG_EXTENDED    = 48,
	BG_DEFAULT     = 49,
}

handle_sgr_sequence :: proc(s: ^Screen, params: []int) {
	if len(params) == 0 {
		reset_attr(s)
		return
	}

	i := 0
	for i < len(params) {
		val := params[i]

		switch val {
		case 30 ..= 37:
			s.current_attr.fg = u32(val - 30)
			s.current_attr.mode -= {.TrueColorFG}
			i += 1;continue
		case 90 ..= 97:
			s.current_attr.fg = u32(val - 90 + 8)
			s.current_attr.mode -= {.TrueColorFG}
			i += 1;continue
		case 40 ..= 47:
			s.current_attr.bg = u32(val - 40)
			s.current_attr.mode -= {.TrueColorBG}
			i += 1;continue
		case 100 ..= 107:
			s.current_attr.bg = u32(val - 100 + 8)
			s.current_attr.mode -= {.TrueColorBG}
			i += 1;continue
		}

		code := SGR_Code(val)
		switch code {
		case .RESET:
			reset_attr(s)
		case .BOLD:
			s.current_attr.mode += {.Bold}
		case .FAINT:
			s.current_attr.mode += {.Faint}
		case .ITALIC:
			s.current_attr.mode += {.Italic}
		case .UNDERLINE:
			s.current_attr.mode += {.Underline}
		case .BLINK:
			s.current_attr.mode += {.Blink}
		case .REVERSE:
			s.current_attr.mode += {.Reverse}
		case .INVISIBLE:
			s.current_attr.mode += {.Invisible}
		case .STRIKE:
			s.current_attr.mode += {.StrikeThrough}
		case .NORMAL_WEIGHT:
			s.current_attr.mode -= {.Bold, .Faint}
		case .NOT_ITALIC:
			s.current_attr.mode -= {.Italic}
		case .NOT_UNDERLINED:
			s.current_attr.mode -= {.Underline}
		case .NOT_BLINKING:
			s.current_attr.mode -= {.Blink}
		case .NOT_REVERSED:
			s.current_attr.mode -= {.Reverse}
		case .NOT_INVISIBLE:
			s.current_attr.mode -= {.Invisible}
		case .NOT_STRUCK:
			s.current_attr.mode -= {.StrikeThrough}

		case .FG_DEFAULT:
			s.current_attr.fg = DEFAULT_FG
			s.current_attr.mode -= {.TrueColorFG}
		case .BG_DEFAULT:
			s.current_attr.bg = DEFAULT_BG
			s.current_attr.mode -= {.TrueColorBG}

		case .FG_EXTENDED:
			i += 1
			if i < len(params) {
				if params[i] == 5 && i + 1 < len(params) {
					s.current_attr.fg = u32(params[i + 1])
					s.current_attr.mode -= {.TrueColorFG}
					i += 1
				} else if params[i] == 2 && i + 3 < len(params) {
					r, g, b := u32(params[i + 1]), u32(params[i + 2]), u32(params[i + 3])
					s.current_attr.fg = (r << 16) | (g << 8) | b
					s.current_attr.mode += {.TrueColorFG}
					i += 3
				}
			}
		case .BG_EXTENDED:
			i += 1
			if i < len(params) {
				if params[i] == 5 && i + 1 < len(params) {
					s.current_attr.bg = u32(params[i + 1])
					s.current_attr.mode -= {.TrueColorBG}
					i += 1
				} else if params[i] == 2 && i + 3 < len(params) {
					r, g, b := u32(params[i + 1]), u32(params[i + 2]), u32(params[i + 3])
					s.current_attr.bg = (r << 16) | (g << 8) | b
					s.current_attr.mode += {.TrueColorBG}
					i += 3
				}
			}
		}
		i += 1
	}
}

reset_attr :: proc(s: ^Screen) {
	s.current_attr.fg = DEFAULT_FG
	s.current_attr.bg = DEFAULT_BG
	s.current_attr.mode = {}
	s.current_attr.char = 0
}

