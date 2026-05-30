;;; +magit/keybindings.el --- Leader keybindings  -*- lexical-binding: t; -*-

(map! :after magit
      :leader
      "g c c" #'branch-off/magit-stage-and-commit
      "g c o" #'branch-off/magit-stage-and-commit-and-branch-off
      "g l l" #'branch-off/magit-log
      "g w"   nil                           ; clear any existing terminal binding first
      (:prefix ("g w" . "worktree")
       "c" #'branch-off/create-worktree
       "w" #'branch-off/create-worktree
       "d" #'branch-off/delete-worktree)
      (:prefix ("g a" . "amend hunk")
       "a" #'branch-off/magit-amend-hunk
       "n" #'branch-off/magit-amend-hunk-no-edit))
