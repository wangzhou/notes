" execute pathogen#infect()
" call pathogen#helptags()
set autoindent
set smartindent
set smarttab
set tabstop=8
set showmatch
set cc=80

" call pathogen#infect()

set nocompatible    
set number              
set ruler               
set shiftwidth=8
set ai 
" set cursorline              
set fileencodings=uft-8	 		
set fencs=utf-8,GB18030,ucs-bom,default,latin1
set hls                     
set incsearch 

set mouse=a
set ttymouse=xterm2
set t_Co=256
"set tw=78

syntax enable
syntax on

color murphy

" about Taglist plugin
let Tlist_Show_One_File = 1            
let Tlist_Exit_OnlyWindow = 1       
" show taglist in right part of window
let Tlist_Use_Right_Window = 1      
let Tlist_Ctags_Cmd = '/usr/bin/ctags'
let Tlist_GainFocus_On_ToggleOpen = 1

" note: ":" mean changing to command line mode, <CR> means "enter"
" <F4> opens taglist plugin window，<F2> opens nerdtree plugin window
noremap <F4> :TlistToggle<CR>       
nnoremap <silent> <F2> :NERDTree<CR>
nnoremap <silent> <F3> :Grep<CR>

" map for example <C-W>h to HH, that makes jumping between two windows easier
nmap HH  <C-W>h
nmap LL  <C-W>l
nmap JJ  <C-W>j
nmap KK  <C-W>k

" :bn skip Nth file in file buffer, so here after enter 1, it skips to file 1
" in file buffer
nmap 1 :b1<CR>
nmap 2 :b2<CR>
nmap 3 :b3<CR>

" set cscope keyboard map
noremap <C-@>s :cs find s <C-R>=expand("<cword>")<CR><CR>
noremap <C-@>g :cs find g <C-R>=expand("<cword>")<CR><CR>
noremap <C-@>c :cs find c <C-R>=expand("<cword>")<CR><CR>
noremap <C-@>t :cs find t <C-R>=expand("<cword>")<CR><CR>
noremap <C-@>e :cs find e <C-R>=expand("<cword>")<CR><CR>
noremap <C-@>f :cs find f <C-R>=expand("<cword>")<CR><CR>
noremap <C-@>d :cs find d <C-R>=expand("<cword>")<CR><CR>
noremap <C-@>i :cs find i ^<C-R>=expand("<cword>")<CR>$<CR>

" set autochdir
set tags=tags;
" cs add /home/wangzhou/linux/cscope.out

noremap <F8> :TlistToggle<CR>
