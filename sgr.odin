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

handle_sgr_sequence :: proc(attr: ^Glyph, params: []int) {
	if len(params) == 0 {
		reset_attr(attr)
		return
	}

	i := 0
	for i < len(params) {
		val := params[i]

		switch val {
		case 30 ..= 37:
			attr.fg = u32(val - 30)
			i += 1;continue
		case 90 ..= 97:
			attr.fg = u32(val - 90 + 8)
			i += 1;continue
		case 40 ..= 47:
			attr.bg = u32(val - 40)
			i += 1;continue
		case 100 ..= 107:
			attr.bg = u32(val - 100 + 8)
			i += 1;continue
		}

		code := SGR_Code(val)
		switch code {
		case .RESET:
			reset_attr(attr)
		case .BOLD:
			attr.mode += {.Bold}
		case .FAINT:
			attr.mode += {.Faint}
		case .ITALIC:
			attr.mode += {.Italic}
		case .UNDERLINE:
			attr.mode += {.Underline}
		case .BLINK:
			attr.mode += {.Blink}
		case .REVERSE:
			attr.mode += {.Reverse}
		case .INVISIBLE:
			attr.mode += {.Invisible}
		case .STRIKE:
			attr.mode += {.StrikeThrough}
		case .NORMAL_WEIGHT:
			attr.mode -= {.Bold, .Faint}
		case .NOT_ITALIC:
			attr.mode -= {.Italic}
		case .NOT_UNDERLINED:
			attr.mode -= {.Underline}
		case .NOT_BLINKING:
			attr.mode -= {.Blink}
		case .NOT_REVERSED:
			attr.mode -= {.Reverse}
		case .NOT_INVISIBLE:
			attr.mode -= {.Invisible}
		case .NOT_STRUCK:
			attr.mode -= {.StrikeThrough}

		case .FG_DEFAULT:
			attr.fg = DEFAULT_FG
		case .BG_DEFAULT:
			attr.bg = DEFAULT_BG

		case .FG_EXTENDED:
			i += 1
			if i < len(params) {
				if params[i] == 5 && i + 1 < len(params) {
					attr.fg = u32(params[i + 1])
					i += 1
				} else if params[i] == 2 && i + 3 < len(params) {
					r, g, b := u32(params[i + 1]), u32(params[i + 2]), u32(params[i + 3])
					attr.fg = (r << 16) | (g << 8) | b
					i += 3
				}
			}
		case .BG_EXTENDED:
			i += 1
			if i < len(params) {
				if params[i] == 5 && i + 1 < len(params) {
					attr.bg = u32(params[i + 1])
					i += 1
				} else if params[i] == 2 && i + 3 < len(params) {
					r, g, b := u32(params[i + 1]), u32(params[i + 2]), u32(params[i + 3])
					attr.bg = (r << 16) | (g << 8) | b
					i += 3
				}
			}
		}
		i += 1
	}
}

reset_attr :: proc(attr: ^Glyph) {
	attr.fg = DEFAULT_FG
	attr.bg = DEFAULT_BG
	attr.mode = {}
	attr.char = 0
}

