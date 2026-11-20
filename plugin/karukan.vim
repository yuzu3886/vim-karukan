vim9script
# vim-karukan: Japanese input for Vim using karukan-server.

if exists('g:loaded_karukan')
  finish
endif
g:loaded_karukan = 1

inoremap <silent> <Plug>(karukan-toggle) <Cmd>call karukan#Toggle()<CR>
inoremap <silent> <Plug>(karukan-enable) <Cmd>call karukan#Enable()<CR>
inoremap <silent> <Plug>(karukan-disable) <Cmd>call karukan#Disable()<CR>

if !get(g:, 'karukan_no_default_mappings', false)
    && !hasmapto('<Plug>(karukan-toggle)', 'i')
    && maparg('<C-j>', 'i') == ''
  imap <C-j> <Plug>(karukan-toggle)
endif

command! KarukanServerStop call karukan#Shutdown()

augroup karukan
  autocmd!
  autocmd VimLeavePre * if exists('*karukan#Shutdown') | call karukan#Shutdown() | endif
augroup END
