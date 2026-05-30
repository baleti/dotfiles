;;; +magit.el --- Magit configuration loader  -*- lexical-binding: t; -*-

(load! "+magit/stage")       ; diff faces, hunk/line staging helpers and commands
(load! "+magit/commit")      ; stage-and-commit, commit-and-branch-off
(load! "+magit/log")         ; log faces, log/revision/status navigation
(load! "+magit/worktree")    ; create and delete worktrees
(load! "+magit/reword")      ; commit reword and remove
(load! "+magit/squash")      ; squash commits, mark system, transient extensions
(load! "+magit/blob")        ; blob navigation with branch-off awareness
(load! "+magit/search")      ; git history search (pickaxe, grep, filename)
(load! "+magit/keybindings") ; leader keybindings spanning multiple files
