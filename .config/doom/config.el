;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

(setq initial-scratch-message nil)

(after! vertico
  (setq vertico-cycle nil)
  (map! :map (minibuffer-local-map vertico-map)
      "C-w" evil-window-map)
)

(setq doom-theme 'doom-one)

(setq display-line-numbers-type 'absolute)
;; reassign SPC t l directly to display-line-numbers-mode
(map! :leader
      (:prefix-map ("t" . "toggle")
       "l" #'display-line-numbers-mode))

(setq org-directory "~/notes/")

(add-hook 'after-change-major-mode-hook (lambda () (setq evil-shift-width 2)))

(add-to-list 'auto-mode-alist '("\\.bash_history\\'" . fundamental-mode))
(add-to-list 'auto-mode-alist '("\\.zsh_history\\'" . fundamental-mode))

;; you may want to use fx instead of json-mode
(map! :mode json-mode
      :n "TAB" #'hs-toggle-hiding
      :n "H" #'hs-hide-level)

;; save recentf on schedule not to lose entries if emacs exits incorrectly
(after! recentf
  (recentf-load-list)
  (run-at-time nil (* 5 60)
    (lambda ()
      (let ((inhibit-message t))
        (recentf-save-list)))))

(after! org
;; remove these global bindings
(map! :map global-map "C-S-<return>" nil)
(map! :map global-map "C-<return>" nil)
(map! :map global-map "M-h" nil)
(map! :map global-map "M-l" nil)

;; Remove from evil states
;; still doesn't work on wsl for some reason
(map! :map evil-normal-state-map "C-<return>" nil)
(map! :map evil-insert-state-map "C-<return>" nil)
(map! :nvi "C-S-<return>" nil)
(map! :nvi "C-S-RET" nil)

;; add our org-specific bindings
(map! :map org-mode-map
      "C-<return>" #'+org/insert-item-below
      "C-S-<return>" #'+org/insert-item-above
      "M-k" #'org-metaup
      "M-j" #'org-metadown
      "S-M-j" #'org-shiftmetaright
      "S-M-h" #'org-shiftmetaleft
      "M-h" #'org-metaleft
      "M-l" #'org-metaright)

(defun org-table-duplicate-column-right ()
  "Duplicate the current column in an org-mode table to the right."
  (interactive)
  (unless (org-at-table-p)
    (user-error "Not in an org-mode table"))
  (org-table-analyze)
  (let* ((col (org-table-current-column))
         (row (org-table-current-line))
         (beg (org-table-begin))
         (end (save-excursion
                (goto-char beg)
                (while (org-at-table-p)
                  (forward-line))
                (point)))
         (lines (save-excursion
                  (goto-char beg)
                  (org-table-to-lisp))))
    ;; Build new table with duplicated column
    (goto-char beg)
    (delete-region beg end)
    (insert (orgtbl-to-orgtbl
             (mapcar (lambda (line)
                       (if (eq line 'hline)
                           'hline
                         (let ((new-line '()))
                           (dotimes (i (length line))
                             (push (nth i line) new-line)
                             (when (= i (1- col))
                               (push (nth i line) new-line)))
                           (nreverse new-line))))
                     lines)
             nil))
    (when (and (not (eobp)) (not (looking-at-p "^")))
      (insert "\n"))
    ;; Return to original position
    (org-table-goto-line row)
    (org-table-goto-column col)
    (org-table-align)))

(defun org-table-duplicate-column-left ()
  "Duplicate the current column in an org-mode table to the left."
  (interactive)
  (unless (org-at-table-p)
    (user-error "Not in an org-mode table"))
  (org-table-analyze)
  (let* ((col (org-table-current-column))
         (row (org-table-current-line))
         (beg (org-table-begin))
         (end (save-excursion
                (goto-char beg)
                (while (org-at-table-p)
                  (forward-line))
                (point)))
         (lines (save-excursion
                  (goto-char beg)
                  (org-table-to-lisp))))
    ;; Build new table with duplicated column
    (goto-char beg)
    (delete-region beg end)
    (insert (orgtbl-to-orgtbl
             (mapcar (lambda (line)
                       (if (eq line 'hline)
                           'hline
                         (let ((new-line '()))
                           (dotimes (i (length line))
                             (when (= i (1- col))
                               (push (nth i line) new-line))
                             (push (nth i line) new-line))
                           (nreverse new-line))))
                     lines)
             nil))
    (when (and (not (eobp)) (not (looking-at-p "^")))
      (insert "\n"))
    ;; Return to original position (now shifted right by 1)
    (org-table-goto-line row)
    (org-table-goto-column (1+ col))
    (org-table-align)))

(global-set-key (kbd "C-l") 'org-table-duplicate-column-right)
(global-set-key (kbd "C-h") 'org-table-duplicate-column-left)

;; Optional: bind to a key (uncomment and modify as needed)
;; (define-key org-mode-map (kbd "C-c C-t c") 'org-table-copy-column-right)

;; Optional: bind to a key (uncomment and modify as needed)
;; (define-key org-mode-map (kbd "C-c C-t c") 'org-table-copy-column-right)

;; commands to navigate org mode tables, like ctrl up/down arrows in excel
(defun org-table-next-non-empty-field-down ()
  "Move cursor down to the next non-empty field in the current column."
  (interactive)
  (when (org-at-table-p)
    (let ((col (org-table-current-column))
          found)
      (save-excursion
        (while (and (not found)
                    (= 0 (forward-line 1))
                    (org-at-table-p))
          (org-table-goto-column col)
          (let ((content (org-table-get-field)))
            (when (and content
                       (not (string-match-p "^\\s-*$" content))
                       (not (string-match-p "^[-+|]+$" content)))
              (setq found (point))))))
      (if found
          (goto-char found)
        (message "No non-empty field found below")))))

(defun org-table-previous-non-empty-field-up ()
  "Move cursor up to the previous non-empty field in the current column."
  (interactive)
  (when (org-at-table-p)
    (let ((col (org-table-current-column))
          found)
      (save-excursion
        (while (and (not found)
                    (= 0 (forward-line -1))
                    (org-at-table-p))
          (org-table-goto-column col)
          (let ((content (org-table-get-field)))
            (when (and content
                       (not (string-match-p "^\\s-*$" content))
                       (not (string-match-p "^[-+|]+$" content)))
              (setq found (point))))))
      (if found
          (goto-char found)
        (message "No non-empty field found above")))))

(map! :after org
      :map org-mode-map
      :nvi "C-j" nil                                    ; Remove existing
      :nvi "C-j" #'org-table-next-non-empty-field-down) ; Add new

;; Add our org-specific bindings
(map! :map org-mode-map
  "C-<return>" #'org-insert-heading
  "C-S-<return>" #'+org/insert-item-above))

(defun insert-custom-timestamp-with-date ()
  "Insert the current date and time in the format: [YYYY-MM-DD Day HH:MM]."
  (interactive)
  (insert (format-time-string "[%Y-%m-%d %a %H:%M]")))

(defun insert-custom-timestamp ()
  "Insert the current date and time in the format: =HH:MM=]."
  (interactive)
  (insert (format-time-string "=%H:%M=")))

(map! :leader
      :desc "Insert custom timestamp with date"
      "i t" #'insert-custom-timestamp-with-date)
(map! :leader
      :desc "Insert custom timestamp with date"
      "i T" #'insert-custom-timestamp)

;; debugging
;; (map! :map backtrace-mode-map :after backtrace :n "d" 'backtrace-toggle-locals)
;; (map! :map backtrace-mode-map :after backtrace :n "n" 'edebug-next-mode)

(use-package! git-branch-off
  :after magit
  :config
  (git-branch-off-setup))

(after! magit
  (custom-set-faces!
    '(magit-diff-added
      :foreground "#98be65" :background "#1e2b1e")
    '(magit-diff-added-highlight
      :foreground "#b0d47a" :background "#263626" :weight bold)
    '(magit-diff-removed
      :foreground "#ff6c6b" :background "#2b1e1e")
    '(magit-diff-removed-highlight
      :foreground "#ff8080" :background "#3a2020" :weight bold)
    '(magit-diff-hunk-heading
      :foreground "#51afef" :background "#1e2535" :weight bold)
    '(magit-diff-hunk-heading-highlight
      :foreground "#7bc8f5" :background "#243050" :weight bold)
    '(magit-section-highlight
      :background "#3d4451" :extend t)))

(after! doom-themes
  (custom-set-faces!
    `(branch-off/magit-squash-marked
      :background ,(doom-blend (doom-color 'orange) (doom-color 'bg) 0.25)
      :extend t)))

(map! :after magit
      :leader
      "g c c" #'git-branch-off-stage-and-commit
      "g c o" #'git-branch-off-stage-and-commit-branch-off
      "g l l" #'git-branch-off-log
      "g w"   nil
      (:prefix ("g w" . "worktree")
       "c" #'git-branch-off-worktree-create
       "w" #'git-branch-off-worktree-create
       "d" #'git-branch-off-worktree-delete)
      (:prefix ("g a" . "amend hunk")
       "a" #'git-branch-off-amend-hunk
       "n" #'git-branch-off-amend-hunk-no-edit))

(map! :leader
      "s g" nil
      :desc "Git: file add/remove history"    "s g f" #'git-branch-off-search-filename-history
      :desc "Git: pickaxe -G (regex changed)" "s g g" #'git-branch-off-search-pickaxe-g
      :desc "Git: pickaxe -S (count changed)" "s g S" #'git-branch-off-search-pickaxe-s
      :desc "Git: grep all committed blobs"   "s g a" #'git-branch-off-search-all-grep)
