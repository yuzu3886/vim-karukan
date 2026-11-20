vim9script
# Minimal asynchronous HTTP/1.1 client built on Vim channels (raw mode).
# One connection per request with "Connection: close".

# Pending requests keyed by channel id.
var requests: dict<dict<any>> = {}

# Send a request.  {Callback} is called as Callback(status, data, error):
#   status: HTTP status code, or 0 when the connection failed
#   data:   decoded JSON body (null when the body is not JSON)
#   error:  error message, empty on success
export def Request(host: string, port: number, method: string, path: string,
    body: any, Callback: func(number, any, string))
  const payload = body == null ? '' : json_encode(body)
  var ch: channel
  try
    ch = ch_open($'{host}:{port}', {
      mode: 'raw',
      waittime: 0,
      noblock: true,
      callback: OnData,
      close_cb: OnClose,
    })
  catch
    Callback(0, null, v:exception)
    return
  endtry
  if ch_status(ch) !=# 'open'
    Callback(0, null, $'cannot connect to {host}:{port}')
    return
  endif

  const id = ch_info(ch).id
  requests[id] = {buf: '', callback: Callback}

  var req = $"{method} {path} HTTP/1.1\r\n"
    .. $"Host: {host}:{port}\r\n"
    .. "Accept: application/json\r\n"
    .. "Connection: close\r\n"
  if payload != ''
    req ..= "Content-Type: application/json\r\n"
      .. $"Content-Length: {strlen(payload)}\r\n"
  endif
  req ..= "\r\n" .. payload

  try
    ch_sendraw(ch, req)
  catch
    remove(requests, id)
    silent! ch_close(ch)
    Callback(0, null, v:exception)
  endtry
enddef

def OnData(ch: channel, msg: string)
  const id = ch_info(ch).id
  if !has_key(requests, id)
    return
  endif
  requests[id].buf ..= msg
  const res = Parse(requests[id].buf, false)
  if res != null
    Finish(id, res)
    silent! ch_close(ch)
  endif
enddef

def OnClose(ch: channel)
  const id = ch_info(ch).id
  if !has_key(requests, id)
    return
  endif
  # Data callbacks have already been invoked before close_cb.
  const res = Parse(requests[id].buf, true)
  Finish(id, res ?? {status: 0, body: '', error: 'connection closed unexpectedly'})
enddef

def Finish(id: number, res: dict<any>)
  const Callback = requests[id].callback
  remove(requests, id)
  var data: any = null
  var err = get(res, 'error', '')
  if err == ''
    try
      data = json_decode(res.body)
    catch
      data = null
    endtry
    if res.status != 200
      err = $'HTTP {res.status}: {res.body}'
    elseif data == null
      err = 'invalid JSON response'
    endif
  endif
  try
    Callback(res.status, data, err)
  catch
    echohl ErrorMsg
    echomsg $'karukan: {v:exception}'
    echohl None
  endtry
enddef

# Parse a raw HTTP response.  Returns null when it is not complete yet.
def Parse(buf: string, closed: bool): any
  const sep = stridx(buf, "\r\n\r\n")
  if sep < 0
    return closed ? {status: 0, body: '', error: 'malformed response'} : null
  endif
  const header = strpart(buf, 0, sep)
  var body = strpart(buf, sep + 4)
  const m = matchlist(header, '^HTTP/[0-9.]\+ \(\d\+\)')
  if empty(m)
    return {status: 0, body: '', error: 'malformed status line'}
  endif
  const status = str2nr(m[1])
  if header =~? '\ntransfer-encoding:\s*chunked'
    if !closed
      return null
    endif
    body = Dechunk(body)
  else
    const cl = matchstr(header, '\c\ncontent-length:\s*\zs\d\+')
    if cl != ''
      const len = str2nr(cl)
      if strlen(body) < len
        return closed ? {status: 0, body: '', error: 'truncated response'} : null
      endif
      body = strpart(body, 0, len)
    elseif !closed
      return null
    endif
  endif
  return {status: status, body: body, error: ''}
enddef

def Dechunk(raw: string): string
  var out = ''
  var pos = 0
  while true
    const eol = stridx(raw, "\r\n", pos)
    if eol < 0
      break
    endif
    const size = str2nr(strpart(raw, pos, eol - pos), 16)
    if size <= 0
      break
    endif
    out ..= strpart(raw, eol + 2, size)
    pos = eol + 2 + size + 2
  endwhile
  return out
enddef
