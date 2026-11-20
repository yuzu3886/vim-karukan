vim9script
# karukan-server lifecycle and API access.

import autoload './http.vim'

# 'unknown' | 'checking' | 'starting' | 'ready' | 'failed'
var state = 'unknown'
var job: any = null
var poll_timer = 0
var poll_deadline = 0.0
var stderr_tail: list<string> = []

export def Host(): string
  return get(g:, 'karukan_server_host', '127.0.0.1')
enddef

export def Port(): number
  return get(g:, 'karukan_server_port', 3000)
enddef

export def State(): string
  return state
enddef

def Notify(msg: string, hl = 'WarningMsg')
  execute 'echohl' hl
  echomsg $'karukan: {msg}'
  echohl None
enddef

# Make sure the server is reachable; start it when it is not.
export def Ensure()
  if state ==# 'ready' || state ==# 'checking' || state ==# 'starting'
    return
  endif
  state = 'checking'
  http.Request(Host(), Port(), 'GET', '/health', null, (status, _, err) => {
    if err == ''
      state = 'ready'
    else
      Start()
    endif
  })
enddef

def Start()
  const cmd = get(g:, 'karukan_server_cmd', ['karukan-server'])
  var argv = (type(cmd) == v:t_string ? [cmd] : copy(cmd))
    + ['--host', Host(), '--port', string(Port())]
  if !get(g:, 'karukan_server_autostart', true)
    state = 'failed'
    Notify($'server is not running on {Host()}:{Port()}')
    return
  endif
  if !executable(expand(argv[0]))
    state = 'failed'
    Notify($'server is not running and "{argv[0]}" is not executable (see g:karukan_server_cmd)')
    return
  endif
  argv[0] = expand(argv[0])
  stderr_tail = []
  job = job_start(argv, {
    in_io: 'null',
    out_io: 'null',
    err_cb: (_, msg) => {
      stderr_tail->add(msg)
      if len(stderr_tail) > 20
        remove(stderr_tail, 0)
      endif
    },
    exit_cb: OnExit,
    stoponexit: 'term',
  })
  if job_status(job) !=# 'run'
    state = 'failed'
    job = null
    Notify($'failed to start {argv[0]}')
    return
  endif
  state = 'starting'
  # Loading (and on first run downloading) the model can take a while.
  poll_deadline = reltimefloat(reltime()) + get(g:, 'karukan_server_start_timeout', 300)
  poll_timer = timer_start(500, (_) => Poll())
enddef

def Poll()
  poll_timer = 0
  if state !=# 'starting'
    return
  endif
  http.Request(Host(), Port(), 'GET', '/health', null, (status, _, err) => {
    if state !=# 'starting'
      return
    endif
    if err == ''
      state = 'ready'
    elseif reltimefloat(reltime()) > poll_deadline
      state = 'failed'
      Notify('timed out waiting for karukan-server to start')
    else
      poll_timer = timer_start(500, (_) => Poll())
    endif
  })
enddef

def OnExit(_: job, status: number)
  job = null
  if state ==# 'starting' || state ==# 'ready'
    state = 'failed'
    const detail = empty(stderr_tail) ? '' : ': ' .. stderr_tail[-1]
    Notify($'karukan-server exited with status {status}{detail}', 'ErrorMsg')
  endif
enddef

export def Stop()
  if poll_timer != 0
    timer_stop(poll_timer)
    poll_timer = 0
  endif
  if job != null && job_status(job) ==# 'run'
    job_stop(job)
  endif
  job = null
  state = 'unknown'
enddef

# Request kana-kanji conversion candidates.
# {Callback} is called as Callback(data, error).
export def Convert(hiragana: string, context: string,
    Callback: func(any, string))
  if state ==# 'starting' || state ==# 'checking'
    Callback(null, 'server is starting')
    return
  endif
  http.Request(Host(), Port(), 'POST', '/api/kanji/convert', {
    hiragana: hiragana,
    context: context,
    num_candidates: get(g:, 'karukan_num_candidates', 5),
  }, (status, data, err) => {
    if status == 0 && state ==# 'ready'
      # The server went away; try to bring it back next time.
      state = 'unknown'
      Ensure()
    endif
    Callback(data, err)
  })
enddef
