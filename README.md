# tmux-tpad

A floating scratchpad for tmux.

- One key shows or hides a popup terminal over the current tab. The key is set
  in `tmux.conf`, e.g. `` set -g @tpad-scratchpad-bind "M-`" ``.
- Each tmux tab has its own scratchpad. Closing the tab closes its scratchpad.
- A scratchpad can have several tabs. While it has more than one, a small bar
  lists them and marks the active one, e.g. `[1][2*]`.
- Inside the popup, `prefix` + `Ctrl-f` switches to fullscreen and back.

Forked from [Subbeh/tmux-tpad](https://github.com/Subbeh/tmux-tpad).
