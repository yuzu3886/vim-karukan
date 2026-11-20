vim9script
# Candidate popup that mimics the Insert mode completion menu.
# Honors 'pumopt' (and the individual 'pum*' options).

const PROP_SEL = 'karukan_pum_sel'

var winid = 0
var items: list<string> = []
var selected = -1
var firstline = 1
var rendered: list<string> = []

export def Visible(): bool
  return winid != 0 && !empty(popup_getpos(winid))
enddef

export def Close()
  if winid != 0
    popup_close(winid)
    winid = 0
  endif
  items = []
  rendered = []
  selected = -1
  firstline = 1
enddef

const BORDERS = {
  single: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
  double: ['═', '║', '═', '║', '╔', '╗', '╝', '╚'],
  round: ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
  ascii: ['-', '|', '-', '|', '+', '+', '+', '+'],
}

# Read the popup menu configuration from the options.
def PumConfig(): dict<any>
  var cfg = {
    border: [],
    margin: false,
    opacity: 100,
    height: &pumheight,
    width: &pumwidth,
    maxwidth: &pummaxwidth,
  }
  var spec = &pumopt
  if spec == '' && exists('&pumborder') && &pumborder != ''
    spec = join(mapnew(split(&pumborder, ','),
      (_, v) => v =~# '^\%(single\|double\|round\|ascii\|custom:\)' ? 'border:' .. v : v), ',')
  endif
  for item in split(spec, ',')
    if item =~# '^border:'
      const style = item[7 :]
      if style =~# '^custom:'
        const chars = split(style[7 :], ';', true)
        if len(chars) == 8
          cfg.border = chars
        endif
      elseif has_key(BORDERS, style)
        const boxdrawing = style !=# 'ascii'
        if !boxdrawing || (&encoding ==# 'utf-8' && &ambiwidth ==# 'single')
          cfg.border = BORDERS[style]
        endif
      endif
    elseif item ==# 'margin'
      cfg.margin = true
    elseif item =~# '^opacity:\d\+$'
      cfg.opacity = str2nr(item[8 :])
    endif
  endfor
  if empty(cfg.border)
    cfg.margin = false
  endif
  return cfg
enddef

def TruncChar(): string
  const m = matchstr(&fillchars, '\%(^\|,\)trunc:\zs[^,]*')
  return m == '' ? '>' : m
enddef

def Render(cfg: dict<any>): list<string>
  var textwidth = max(mapnew(items, (_, s) => strdisplaywidth(s)) + [0])
  # Each row is " text " like the builtin menu; 'pumwidth' is the minimum.
  var width = max([textwidth + 2, cfg.width])
  if cfg.maxwidth > 0
    width = min([width, cfg.maxwidth])
  endif
  const room = width - 2
  const trunc = TruncChar()
  var lines: list<string> = []
  for s in items
    var text = s
    if strdisplaywidth(text) > room
      while strdisplaywidth(text) > room - strdisplaywidth(trunc) && text != ''
        text = strcharpart(text, 0, strchars(text) - 1)
      endwhile
      text ..= trunc
    endif
    lines->add(' ' .. text .. repeat(' ', room - strdisplaywidth(text)) .. ' ')
  endfor
  return lines
enddef

# Show {candidates} below the screen position of (lnum, col).
export def Show(candidates: list<string>, sel: number, lnum: number, col: number)
  Close()
  if empty(candidates)
    return
  endif
  const pos = screenpos(win_getid(), lnum, col)
  if pos.row == 0
    return
  endif
  items = copy(candidates)
  selected = sel
  const cfg = PumConfig()
  var lines = Render(cfg)

  # Align the candidate text with the reading on screen.  When the popup
  # would start left of the screen edge, drop the leading space (and then
  # the left margin) instead of shifting the text to the right.
  const border_w = empty(cfg.border) ? 0 : 1
  var lead = 1
  var margin_left = cfg.margin ? 1 : 0
  var deficit = max([0, (lead + border_w + margin_left) - (pos.col - 1)])
  if deficit > 0 && lead > 0
    lead = 0
    deficit -= 1
    lines = mapnew(lines, (_, l) => l[1 :])
  endif
  if deficit > 0 && margin_left > 0
    margin_left = 0
    deficit -= 1
  endif
  const offset = lead + border_w + margin_left
  var opts: dict<any> = {
    line: 'cursor+1',
    col: max([1, pos.col - offset]),
    pos: 'topleft',
    posinvert: true,
    fixed: false,
    wrap: false,
    highlight: 'Pmenu',
    padding: [0, cfg.margin ? 1 : 0, 0, margin_left],
    border: empty(cfg.border) ? [0, 0, 0, 0] : [1, 1, 1, 1],
    scrollbar: 1,
    scrollbarhighlight: 'PmenuSbar',
    thumbhighlight: 'PmenuThumb',
    zindex: 100,
    mapping: true,
  }
  if !empty(cfg.border)
    opts.borderchars = cfg.border
    opts.borderhighlight = ['PmenuBorder']
  endif
  if cfg.height > 0
    opts.maxheight = cfg.height
  endif
  if cfg.opacity < 100
    opts.opacity = cfg.opacity
  endif
  if empty(prop_type_get(PROP_SEL))
    prop_type_add(PROP_SEL, {highlight: 'PmenuSel', combine: false})
  endif
  rendered = lines
  winid = popup_create(lines, opts)
  firstline = 1
  Select(sel)
enddef

# Highlight item {sel} (-1 for none) and keep it in view.
export def Select(sel: number)
  if winid == 0
    return
  endif
  selected = sel
  # popup_settext() is used instead of prop_add() on the popup buffer
  # because changing text properties alone does not redraw the popup.
  var text: list<dict<any>> = []
  for i in range(len(rendered))
    var entry: dict<any> = {text: rendered[i]}
    if i == sel
      entry.props = [{col: 1, length: strlen(rendered[i]), type: PROP_SEL}]
    endif
    text->add(entry)
  endfor
  popup_settext(winid, text)
  if sel >= 0 && sel < len(items)
    const height = popup_getpos(winid).core_height
    if height > 0
      if sel + 1 < firstline
        firstline = sel + 1
      elseif sel + 1 >= firstline + height
        firstline = sel + 2 - height
      endif
    endif
  endif
  popup_setoptions(winid, {firstline: firstline})
enddef
