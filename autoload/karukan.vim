vim9script
# vim-karukan: Japanese input for Vim using karukan-server.

import autoload './karukan/romaji.vim'
import autoload './karukan/popup.vim'
import autoload './karukan/server.vim'

# --- Mode state ------------------------------------------------------------

var enabled = false
var enabled_buf = -1
var saved_maps: list<dict<any>> = []

# --- Reading (preedit) state -----------------------------------------------
# The reading occupies bytes [start_col, start_col + strlen(shown)) of line
# start_lnum.  `shown` is either kana .. pending or the selected candidate.

var active = false
var start_lnum = 0
var start_col = 0
var kana = ''
var pending = ''
var shown = ''
var expected_pos: list<number> = []

# --- Candidate state -------------------------------------------------------

var candidates: list<string> = []
var candidates_key = ''   # kana .. pending at request time
var selected = -1
var request_id = 0
var auto_timer = 0

# Special keys handled while the mode is on.
const SPECIAL_KEYS = {
  space: ['<Space>', ' '],
  cr: ['<CR>', "\<CR>"],
  bs: ['<BS>', "\<BS>"],
  ctrl_h: ['<C-h>', "\<C-h>"],
  ctrl_n: ['<C-n>', "\<C-n>"],
  ctrl_p: ['<C-p>', "\<C-p>"],
  tab: ['<Tab>', "\<Tab>"],
  s_tab: ['<S-Tab>', "\<S-Tab>"],
  down: ['<Down>', "\<Down>"],
  up: ['<Up>', "\<Up>"],
  ctrl_y: ['<C-y>', "\<C-y>"],
  ctrl_e: ['<C-e>', "\<C-e>"],
}

# ===========================================================================
# Public API
# ===========================================================================

export def IsEnabled(): bool
  return enabled && enabled_buf == bufnr()
enddef

export def Toggle()
  if IsEnabled()
    Disable()
  else
    Enable()
  endif
enddef

export def Enable()
  if IsEnabled()
    return
  endif
  if enabled
    Disable()
  endif
  enabled = true
  enabled_buf = bufnr()
  InstallMappings()
  augroup karukan_active
    autocmd!
    autocmd InsertLeave * OnInsertLeave()
    autocmd CursorMovedI * OnCursorMovedI()
    autocmd BufLeave,WinLeave * Disable()
  augroup END
  server.Ensure()
  redrawstatus
enddef

export def Disable()
  if !enabled
    return
  endif
  if active
    Commit(mode() =~# '^i')
  endif
  EndReading()
  UninstallMappings()
  enabled = false
  enabled_buf = -1
  augroup karukan_active
    autocmd!
  augroup END
  redrawstatus
enddef

# Stop the server if this plugin started it.
export def Shutdown()
  Disable()
  server.Stop()
enddef

# ===========================================================================
# Mappings
# ===========================================================================

def EscapeLhs(c: string): string
  return {' ': '<Space>', '|': '<Bar>', '\': '<Bslash>', '<': '<lt>'}->get(c, c)
enddef

def SaveMap(lhs: string)
  const m = maparg(lhs, 'i', false, true)
  if !empty(m) && m.buffer && m.rhs !~# 'karukan#'
    saved_maps->add(m)
  endif
enddef

def InstallMappings()
  saved_maps = []
  for nr in range(0x21, 0x7e)
    const lhs = EscapeLhs(nr2char(nr))
    SaveMap(lhs)
    execute $'inoremap <buffer><nowait><silent> {lhs} <Cmd>call karukan#Input({nr})<CR>'
  endfor
  for [name, spec] in items(SPECIAL_KEYS)
    SaveMap(spec[0])
    execute $'inoremap <buffer><nowait><silent><expr> {spec[0]} karukan#Key("{name}")'
  endfor
enddef

def UninstallMappings()
  # Mappings are buffer-local.  Disable() is normally called while the
  # enabled buffer is current; otherwise the leftover mappings are inert
  # because Input() and Key() check IsEnabled().
  if bufnr() == enabled_buf
    for nr in range(0x21, 0x7e)
      silent! execute $'iunmap <buffer> {EscapeLhs(nr2char(nr))}'
    endfor
    for spec in values(SPECIAL_KEYS)
      silent! execute $'iunmap <buffer> {spec[0]}'
    endfor
    for m in saved_maps
      mapset('i', false, m)
    endfor
  endif
  saved_maps = []
enddef

# Called from <expr> mappings: decide whether to handle a special key.
export def Key(name: string): string
  if !IsEnabled()
    return SPECIAL_KEYS[name][1]
  endif
  var handle = false
  if name ==# 'space' || name ==# 'cr' || name ==# 'bs' || name ==# 'ctrl_h'
    handle = active && shown != ''
  else
    handle = popup.Visible()
  endif
  if handle
    return $"\<Cmd>call karukan#Do('{name}')\<CR>"
  endif
  return SPECIAL_KEYS[name][1]
enddef

export def Do(name: string)
  if name ==# 'space'
    Convert()
  elseif name ==# 'cr' || name ==# 'ctrl_y'
    Commit(true)
    EndReading()
  elseif name ==# 'bs' || name ==# 'ctrl_h'
    Backspace()
  elseif name ==# 'ctrl_n' || name ==# 'tab' || name ==# 'down'
    Move(1, false)
  elseif name ==# 'ctrl_p' || name ==# 's_tab' || name ==# 'up'
    Move(-1, false)
  elseif name ==# 'ctrl_e'
    Cancel()
  endif
enddef

# ===========================================================================
# Reading manipulation
# ===========================================================================

# Replace the reading region in the buffer with {text}.
def SetShown(text: string, move_cursor = true)
  const line = getline(start_lnum)
  const before = strpart(line, 0, start_col - 1)
  const after = strpart(line, start_col - 1 + strlen(shown))
  if before .. text .. after !=# line
    setline(start_lnum, before .. text .. after)
  endif
  shown = text
  if move_cursor
    cursor(start_lnum, start_col + strlen(text))
    expected_pos = [start_lnum, start_col + strlen(text)]
  endif
enddef

def StartReading()
  active = true
  start_lnum = line('.')
  start_col = col('.')
  kana = ''
  pending = ''
  shown = ''
  expected_pos = [start_lnum, start_col]
  ClearCandidates()
enddef

def EndReading()
  active = false
  kana = ''
  pending = ''
  shown = ''
  ClearCandidates()
enddef

def ClearCandidates()
  popup.Close()
  candidates = []
  candidates_key = ''
  selected = -1
  request_id += 1
  if auto_timer != 0
    timer_stop(auto_timer)
    auto_timer = 0
  endif
enddef

def CursorAtReadingEnd(): bool
  return active && [line('.'), col('.')] == expected_pos
enddef

# Finalize the reading as it is shown (selected candidate or kana).
def Commit(move_cursor: bool)
  if !active
    return
  endif
  if selected < 0 && pending != ''
    kana ..= romaji.Flush(pending)
    pending = ''
    SetShown(kana, move_cursor)
  endif
enddef

export def Input(nr: number)
  const ch = nr2char(nr)
  if !IsEnabled()
    feedkeys(ch, 'in')
    return
  endif
  if active && !CursorAtReadingEnd()
    EndReading()
  endif
  if active && selected >= 0
    # Typing after choosing a candidate accepts it.
    Commit(true)
    EndReading()
  endif
  if !active
    StartReading()
  endif
  const r = romaji.Feed(pending, ch)
  kana ..= r.output
  pending = r.pending
  SetShown(kana .. pending)
  ReadingChanged()
enddef

def Backspace()
  if selected >= 0
    # Back to the reading, like an IME.
    selected = -1
    SetShown(kana .. pending)
    popup.Select(-1)
    if !Autocomplete()
      popup.Close()
    endif
    return
  endif
  if pending != ''
    pending = strcharpart(pending, 0, strchars(pending) - 1)
  else
    kana = strcharpart(kana, 0, strchars(kana) - 1)
  endif
  SetShown(kana .. pending)
  ReadingChanged()
enddef

def ReadingChanged()
  if kana .. pending == ''
    EndReading()
    return
  endif
  if !Autocomplete()
    if popup.Visible()
      popup.Close()
    endif
    return
  endif
  if auto_timer != 0
    timer_stop(auto_timer)
  endif
  auto_timer = timer_start(get(g:, 'karukan_autocomplete_delay', 100), (_) => {
    auto_timer = 0
    if active && mode() =~# '^i' && CursorAtReadingEnd()
      Request(false)
    endif
  })
enddef

def Autocomplete(): bool
  return get(g:, 'karukan_autocomplete', false)
enddef

# ===========================================================================
# Conversion
# ===========================================================================

def CandidatesFresh(): bool
  return !empty(candidates) && candidates_key ==# kana .. pending
enddef

# Space: start conversion, or select the next candidate.
def Convert()
  if popup.Visible() && CandidatesFresh()
    Move(1, true)
    return
  endif
  # Make the reading final before converting ("かn" -> "かん").
  if pending != ''
    kana ..= romaji.Flush(pending)
    pending = ''
    SetShown(kana)
  endif
  Request(true)
enddef

def Move(delta: number, cycle: bool)
  if !CandidatesFresh()
    Request(true)
    return
  endif
  const n = len(candidates)
  var next = selected + delta
  if cycle
    next = (next % n + n) % n
  elseif next >= n
    next = -1
  elseif next < -1
    next = n - 1
  endif
  selected = next
  SetShown(selected >= 0 ? candidates[selected] : kana .. pending)
  popup.Select(selected)
enddef

def Cancel()
  selected = -1
  SetShown(kana .. pending)
  popup.Close()
enddef

def Context(): string
  const before = strpart(getline(start_lnum), 0, start_col - 1)
  const limit = get(g:, 'karukan_context_length', 100)
  const n = strchars(before)
  return n > limit ? strcharpart(before, n - limit) : before
enddef

def Request(select_first: bool)
  if !active || kana .. pending == ''
    return
  endif
  request_id += 1
  const id = request_id
  const key = kana .. pending
  const reading = kana .. romaji.Flush(pending)
  server.Convert(reading, Context(), (data, err) => {
    OnResult(id, key, reading, select_first, data, err)
  })
enddef

def OnResult(id: number, key: string, reading: string, select_first: bool,
    data: any, err: string)
  if id != request_id || !active || key !=# kana .. pending || selected >= 0
    return
  endif
  if !(mode() =~# '^i') || !CursorAtReadingEnd()
    return
  endif
  if err != ''
    if select_first
      echohl WarningMsg
      echomsg $'karukan: {err}'
      echohl None
    endif
    return
  endif
  var list: list<string> = []
  for c in get(data, 'candidates', []) + [reading, get(data, 'katakana', '')]
    if type(c) == v:t_string && c != '' && index(list, c) < 0
      list->add(c)
    endif
  endfor
  candidates = list
  candidates_key = key
  selected = -1
  popup.Show(candidates, -1, start_lnum, start_col)
  if select_first
    Move(1, true)
  endif
enddef

# ===========================================================================
# Autocommands
# ===========================================================================

def OnInsertLeave()
  if active
    Commit(false)
  endif
  Disable()
enddef

def OnCursorMovedI()
  if active && !CursorAtReadingEnd()
    EndReading()
  endif
enddef
