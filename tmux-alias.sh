function tmux-help() {
echo "
  Inside tmux
  tmux split-window -v -b
  tmux split-window -v 
  tmux split-window -h -b 
  tmux split-window -h 
  
  Move focus using CLI:
  tmux select-pane -U
  tmux select-pane -D
  tmux select-pane -L
  tmux select-pane -R 
"
}

function tmux-split() {
    case "$1" in
      up)    tmux split-window -v -b ;;
      down)  tmux split-window -v ;;
      left)  tmux split-window -h -b ;;
      right) tmux split-window -h ;;
      *) echo "Usage: tmux-split up|down|left|right" >&2; return 1 ;;
    esac
}

function tmux-pane() {
    case "$1" in
      up)    tmux select-pane -U ;;
      down)  tmux select-pane -D ;;
      left)  tmux select-pane -L ;;
      right) tmux select-pane -R ;;
      *) echo "Usage: tmux-pane up|down|left|right" >&2; return 1 ;;
    esac
}
