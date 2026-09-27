#!/bin/bash

cat << 'EOF' > ~/.vimrc
set ic
set number
syntax on
set tabstop=2
set softtabstop=2
set shiftwidth=2
set expandtab

if has('termguicolors') && $COLORTERM == 'truecolor'
  set termguicolors
endif

set background=dark
try
  colorscheme torte
catch /^Vim\%((\a\+)\)\=:E185/
  colorscheme desert
endtry

syntax enable
filetype plugin indent on
EOF
