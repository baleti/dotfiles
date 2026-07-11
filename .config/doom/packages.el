;; -*- no-byte-compile: t; -*-

(package! git-branch-off
  :recipe (:local-repo "/home/user/git-branch-off"))

(package! gitq
  :recipe (:local-repo "/home/user/gitq"
            :files ("integrations/emacs/*.el")))
