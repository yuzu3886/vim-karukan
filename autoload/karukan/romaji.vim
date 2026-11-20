vim9script
# Romaji to hiragana conversion.

const VOWELS = ['a', 'i', 'u', 'e', 'o']

def BuildTable(): dict<string>
  var t: dict<string> = {}
  def Row(prefix: string, kanas: list<string>)
    for i in range(5)
      if kanas[i] != ''
        t[prefix .. VOWELS[i]] = kanas[i]
      endif
    endfor
  enddef

  Row('', ['あ', 'い', 'う', 'え', 'お'])
  Row('k', ['か', 'き', 'く', 'け', 'こ'])
  Row('s', ['さ', 'し', 'す', 'せ', 'そ'])
  Row('t', ['た', 'ち', 'つ', 'て', 'と'])
  Row('n', ['な', 'に', 'ぬ', 'ね', 'の'])
  Row('h', ['は', 'ひ', 'ふ', 'へ', 'ほ'])
  Row('m', ['ま', 'み', 'む', 'め', 'も'])
  Row('y', ['や', 'い', 'ゆ', 'いぇ', 'よ'])
  Row('r', ['ら', 'り', 'る', 'れ', 'ろ'])
  Row('w', ['わ', 'うぃ', 'う', 'うぇ', 'を'])
  Row('g', ['が', 'ぎ', 'ぐ', 'げ', 'ご'])
  Row('z', ['ざ', 'じ', 'ず', 'ぜ', 'ぞ'])
  Row('d', ['だ', 'ぢ', 'づ', 'で', 'ど'])
  Row('b', ['ば', 'び', 'ぶ', 'べ', 'ぼ'])
  Row('p', ['ぱ', 'ぴ', 'ぷ', 'ぺ', 'ぽ'])
  Row('c', ['か', 'し', 'く', 'せ', 'こ'])
  Row('q', ['くぁ', 'くぃ', 'く', 'くぇ', 'くぉ'])
  Row('f', ['ふぁ', 'ふぃ', 'ふ', 'ふぇ', 'ふぉ'])
  Row('j', ['じゃ', 'じ', 'じゅ', 'じぇ', 'じょ'])
  Row('v', ['ゔぁ', 'ゔぃ', 'ゔ', 'ゔぇ', 'ゔぉ'])
  Row('l', ['ぁ', 'ぃ', 'ぅ', 'ぇ', 'ぉ'])
  Row('x', ['ぁ', 'ぃ', 'ぅ', 'ぇ', 'ぉ'])

  # Contracted sounds (youon).
  const small = ['ゃ', 'ぃ', 'ゅ', 'ぇ', 'ょ']
  for [prefix, base] in [
      ['ky', 'き'], ['gy', 'ぎ'], ['sy', 'し'], ['zy', 'じ'], ['jy', 'じ'],
      ['ty', 'ち'], ['cy', 'ち'], ['dy', 'ぢ'], ['ny', 'に'], ['hy', 'ひ'],
      ['by', 'び'], ['py', 'ぴ'], ['my', 'み'], ['ry', 'り'], ['fy', 'ふ'],
      ['vy', 'ゔ'], ['th', 'て'], ['dh', 'で']]
    Row(prefix, mapnew(small, (_, s) => base .. s))
  endfor
  Row('sh', ['しゃ', 'し', 'しゅ', 'しぇ', 'しょ'])
  Row('ch', ['ちゃ', 'ち', 'ちゅ', 'ちぇ', 'ちょ'])
  Row('ts', ['つぁ', 'つぃ', 'つ', 'つぇ', 'つぉ'])
  Row('tw', ['とぁ', 'とぃ', 'とぅ', 'とぇ', 'とぉ'])
  Row('dw', ['どぁ', 'どぃ', 'どぅ', 'どぇ', 'どぉ'])
  Row('wh', ['うぁ', 'うぃ', 'う', 'うぇ', 'うぉ'])
  Row('xy', ['ゃ', '', 'ゅ', '', 'ょ'])
  Row('ly', ['ゃ', '', 'ゅ', '', 'ょ'])

  extend(t, {
    nn: 'ん', "n'": 'ん', xn: 'ん',
    xtu: 'っ', ltu: 'っ', xtsu: 'っ', ltsu: 'っ',
    xwa: 'ゎ', lwa: 'ゎ', xka: 'ゕ', lka: 'ゕ', xke: 'ゖ', lke: 'ゖ',
    wyi: 'ゐ', wye: 'ゑ',
    '-': 'ー', ',': '、', '.': '。', '[': '「', ']': '」',
    '~': '〜', '/': '・', '!': '！', '?': '？',
    zh: '←', zj: '↓', zk: '↑', zl: '→',
    'z.': '…', 'z,': '‥', 'z/': '・', 'z-': '〜', 'z[': '『', 'z]': '』',
  })
  return t
enddef

const TABLE = BuildTable()

def BuildPrefixes(): dict<bool>
  var p: dict<bool> = {}
  for key in keys(TABLE)
    for i in range(1, strchars(key) - 1)
      p[strcharpart(key, 0, i)] = true
    endfor
  endfor
  return p
enddef

const PREFIXES = BuildPrefixes()

# Consonants that produce a sokuon (っ) when doubled.
const SOKUON = 'bcdfghjklmpqrstvwxyz'

# Feed one character to the converter.
# Returns {output: <confirmed kana>, pending: <unconverted romaji>}.
export def Feed(pending: string, ch: string): dict<string>
  var buf = pending .. ch
  var out = ''
  while buf != ''
    if has_key(TABLE, buf) && !has_key(PREFIXES, buf)
      out ..= TABLE[buf]
      buf = ''
    elseif has_key(PREFIXES, buf) || has_key(TABLE, buf)
      break
    elseif strchars(buf) >= 2 && buf[0] ==# buf[1] && stridx(SOKUON, buf[0]) >= 0
      out ..= 'っ'
      buf = buf[1 :]
    elseif buf[0] ==# 'n' && strchars(buf) >= 2
      out ..= 'ん'
      buf = buf[1 :]
    elseif strchars(buf) >= 2
      # The head can no longer form a valid sequence; emit it as is.
      out ..= buf[0]
      buf = buf[1 :]
    else
      out ..= buf
      buf = ''
    endif
  endwhile
  return {output: out, pending: buf}
enddef

# Convert pending romaji as far as possible, e.g. "n" -> "ん".
export def Flush(pending: string): string
  if pending == ''
    return ''
  elseif has_key(TABLE, pending)
    return TABLE[pending]
  elseif pending ==# 'n'
    return 'ん'
  endif
  return pending
enddef
