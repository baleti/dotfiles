;;; +magit/log.el --- Log, revision, and status navigation  -*- lexical-binding: t; -*-

(defface branch-off/log-worktree-marker
  '((((class color) (background dark))  :foreground "cyan"      :weight bold)
    (((class color) (background light)) :foreground "dark cyan"  :weight bold))
  "Face for the @ symbol that marks a worktree HEAD commit in the log.")

(defface branch-off/log-worktree-hash
  '((((class color) (background dark))  :foreground "cyan3")
    (((class color) (background light)) :foreground "cyan4"))
  "Face for the hash text of a worktree HEAD commit in the log.")

;;; Log / revision navigation

(after! magit
  (defvar branch-off/magit-log-nav-overlay nil)

  (defun branch-off/magit-revision-navigate (move-fn)
    (when-let* ((log-buf (magit-get-mode-buffer 'magit-log-mode)))
      (with-current-buffer log-buf
        (funcall move-fn)
        (mapc #'delete-overlay magit-section-highlight-overlays)
        (setq magit-section-highlight-overlays nil)
        (unless (overlayp branch-off/magit-log-nav-overlay)
          (setq branch-off/magit-log-nav-overlay (make-overlay 1 1))
          (overlay-put branch-off/magit-log-nav-overlay 'face 'magit-section-highlight)
          (overlay-put branch-off/magit-log-nav-overlay 'priority 200))
        (move-overlay branch-off/magit-log-nav-overlay
                      (line-beginning-position)
                      (1+ (line-end-position)))
        (when-let ((commit (magit-section-value-if 'commit)))
          (let ((magit-display-buffer-noselect t))
            (magit-show-commit commit))))))

  (defun branch-off/magit-revision-next ()
    (interactive)
    (branch-off/magit-revision-navigate #'magit-section-forward))

  (defun branch-off/magit-revision-prev ()
    (interactive)
    (branch-off/magit-revision-navigate #'magit-section-backward))

  (add-hook 'magit-log-mode-hook
            (lambda ()
              (setq-local hl-line-sticky-flag t)
              (hl-line-mode 1)))

  (defvar-local branch-off/magit-log-flat nil
    "Non-nil in log buffers opened with `branch-off/magit-log'.")

  (defvar branch-off/magit-log-flat--pending nil
    "Dynamic flag set during `branch-off/magit-log' so the hook fires correctly.")

  (defun branch-off/magit-log ()
    "Log all refs without --graph; commits not ancestral to HEAD are marked with 2-space indent."
    (interactive)
    (let ((branch-off/magit-log-flat--pending t))
      (magit-log-setup-buffer (list "--all") (list "--color" "--decorate" "--topo-order" "-n256") nil)))

  (defun branch-off/magit-log--mark ()
    "Overlay depth-based indent on branch-off commits and @ on worktree HEADs."
    (when (derived-mode-p 'magit-log-mode)
      (when branch-off/magit-log-flat--pending
        (setq-local branch-off/magit-log-flat t))
      (remove-overlays (point-min) (point-max) 'branch-off/log-marker t)
      (remove-overlays (point-min) (point-max) 'branch-off/archive-marker t))
    (when (and (derived-mode-p 'magit-log-mode)
               (bound-and-true-p branch-off/magit-log-flat))
      (let* ((raw (magit-git-lines "log" "--format=%H %P"
                                   "--all"
                                   "--not" "--glob=refs/heads/*"))
             (parent-map  (make-hash-table :test #'equal))
             (all-hashes  nil)
             (bo-ref-set  (let ((tbl (make-hash-table :test #'equal)))
                            (dolist (h (magit-git-lines "for-each-ref"
                                                        "--format=%(objectname)"
                                                        "refs/branch-off/"))
                              (puthash h t tbl))
                            tbl))
             (wt-hashes   (let (acc)
                            (dolist (line (magit-git-lines "worktree" "list" "--porcelain"))
                              (when (string-prefix-p "HEAD " line)
                                (push (substring line 5) acc)))
                            acc))
             (depth-cache (make-hash-table :test #'equal)))
        (dolist (line raw)
          (when (string-match
                 "^\\([0-9a-f]\\{40\\}\\)\\(?: \\([0-9a-f]\\{40\\}\\)\\)?" line)
            (let ((h (match-string 1 line))
                  (p (match-string 2 line)))
              (puthash h p parent-map)
              (push h all-hashes))))
        (when (or all-hashes wt-hashes)
          (cl-labels
              ((in-bo-p (h)
                 (not (eq (gethash h parent-map 'absent) 'absent)))
               (depth-of (h)
                 (or (gethash h depth-cache)
                     (let* ((p (gethash h parent-map))
                            (d (if (or (null p) (not (in-bo-p p)))
                                   1
                                 (let ((pd (depth-of p)))
                                   (if (or (gethash p bo-ref-set)
                                           (gethash h bo-ref-set))
                                       (1+ pd)
                                     pd)))))
                       (puthash h d depth-cache)
                       d))))
            (save-excursion
              (goto-char (point-min))
              (while (not (eobp))
                (when-let ((h (magit-section-value-if 'commit)))
                  (let* ((bo-full (cl-find-if (lambda (f) (string-prefix-p h f)) all-hashes))
                         (wt-full (cl-find-if (lambda (f) (string-prefix-p h f)) wt-hashes))
                         (d       (when bo-full (depth-of bo-full)))
                         (bol     (line-beginning-position)))
                    ;; depth indentation for branch-off commits (low priority)
                    (when d
                      (let ((ov (make-overlay bol bol)))
                        (overlay-put ov 'before-string (make-string (* d 2) ?\s))
                        (overlay-put ov 'priority 10)
                        (overlay-put ov 'branch-off/log-marker t)))
                    ;; @ before hash + hash face for worktree HEADs (higher priority)
                    (when wt-full
                      (let ((ov-at   (make-overlay bol bol))
                            (ov-hash (make-overlay bol (+ bol (length h)))))
                        (overlay-put ov-at 'before-string
                                     (propertize "@" 'face 'branch-off/log-worktree-marker))
                        (overlay-put ov-at 'priority 20)
                        (overlay-put ov-at 'branch-off/log-marker t)
                        (overlay-put ov-hash 'face 'branch-off/log-worktree-hash)
                        (overlay-put ov-hash 'branch-off/log-marker t)))))
                (forward-line 1))))))))

  (add-hook 'magit-refresh-buffer-hook #'branch-off/magit-log--mark)

  (defun branch-off/magit-status-tab ()
    "On a commit section show it; otherwise toggle the section."
    (interactive)
    (if-let ((commit (magit-section-value-if 'commit)))
        (magit-show-commit commit)
      (call-interactively #'magit-section-toggle)))

  (defun branch-off/magit-status-navigate (move-fn)
    (condition-case nil
        (progn
          (funcall move-fn)
          (when-let ((commit (magit-section-value-if 'commit)))
            (let ((magit-display-buffer-noselect t))
              (magit-show-commit commit))))
      (error nil)))

  (defun branch-off/magit-status-next ()
    (interactive)
    (branch-off/magit-status-navigate #'magit-section-forward))

  (defun branch-off/magit-status-prev ()
    (interactive)
    (branch-off/magit-status-navigate #'magit-section-backward))

  (map! :map magit-log-mode-map
        :n "TAB" #'magit-visit-thing
        :n "m"   #'branch-off/magit-mark
        :n "M"   #'branch-off/magit-mark)

  (map! :map magit-status-mode-map
        :n "TAB" #'branch-off/magit-status-tab
        :m "n"   #'branch-off/magit-status-next
        :m "p"   #'branch-off/magit-status-prev)

  (map! :map magit-revision-mode-map
        :n "TAB" #'magit-diff-visit-file
        :n "n" #'branch-off/magit-revision-next
        :n "p" #'branch-off/magit-revision-prev))
