;; -*- no-byte-compile: t; -*-

(package! git-branch-off
  :recipe (:host github :repo "baleti/git-branch-off"
           :branch "main"))

(package! gitq
  :recipe (:host github :repo "baleti/gitq"
           :files ("integrations/emacs/*.el")
           :branch "main"))
