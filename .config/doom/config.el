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

(add-hook 'org-mode-hook
          (lambda ()
            (when buffer-file-name
              (setq org-download-image-dir
                    (concat (file-name-sans-extension (file-name-nondirectory buffer-file-name)) "-images")))))

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

;; https://baty.net/2022/configuring-the-org-download-save-directory
;; https://github.com/abo-abo/org-download/issues/46
;; https://github.com/abo-abo/org-download/issues/151#issuecomment-1425096926
(after! org-download
  (setq org-download-method 'directory)
  ;; moved to org-mode-hook above
  ;; see https://github.com/abo-abo/org-download/issues/216
  ;; (setq org-download-image-dir (concat (file-name-sans-extension (buffer-file-name)) "-images"))
  (setq org-download-image-org-width 600)
  (setq org-download-link-format "[[file:%s]]"
        org-download-abbreviate-filename-function #'file-relative-name)
  (setq org-download-link-format-function #'org-download-link-format-function-default)
  (setq-default org-download-heading-lvl 'nil))

(defun wsl-org-download-clipboard ()
  "Save the clipboard image to a file in the configured org-download-image-dir."
  (interactive)
  (let* ((image-dir (or org-download-image-dir
                        (concat (file-name-sans-extension (file-name-nondirectory buffer-file-name)) "-images")))
         (file-path (concat image-dir "/"
                            (format-time-string "%Y%m%d_%H%M%S")
                            ".png")))
    (unless (file-exists-p image-dir)
      (make-directory image-dir t))
    ;; Use PowerShell to save the clipboard image to file
    (let ((powershell-script
           (concat "$image = [System.Windows.Forms.Clipboard]::GetImage(); "
                   "if ($image -ne $null) { "
                   "$image.Save('" (expand-file-name file-path) "', [System.Drawing.Imaging.ImageFormat]::Png); "
                   "} else { Write-Host 'No image in clipboard.' }")))
      (shell-command-to-string (concat "powershell.exe -Command \"" powershell-script "\"")))
    ;; Insert the link to the saved file in the buffer
    (if (file-exists-p file-path)
        (progn
          (insert (format "[[file:%s]]" (file-relative-name file-path)))
          (message "Saved image to %s" file-path))
      (message "No image found in clipboard."))))

(map! :leader
      :desc "Paste image - org-download-clipboard adapted for wsl"
      "m a w" #'wsl-org-download-clipboard)

;; couldn't get it to work
;; opens windows terminal, but fails if path has spaces
;; (defun open-wsl-terminal-in-current-directory ()
;;   "Open a WSL terminal in the current directory."
;;   (interactive)
;;   (let* ((wsl-path (shell-command-to-string
;;                     (concat "wslpath -w " (shell-quote-argument default-directory))))
;;          (windows-path (string-trim wsl-path)))
;;     (start-process "wsl-terminal" nil "cmd.exe" "/c"
;;                    (concat "wt.exe -d " (replace-regexp-in-string "/" "\\\\" windows-path)))))

;; (map! :leader "o t" 'open-wsl-terminal-in-current-directory)

(defun wsl-org-download-clipboard ()
  "Save an image from the Windows clipboard to a file and insert a link in the current buffer."
  (interactive)
  ;; Ensure the current buffer is associated with a file
  (if (not buffer-file-name)
      (error "Buffer is not associated with a file.")
    (let* (;; Get the base name of the current buffer file (without extension)
           (base-name (file-name-sans-extension (file-name-nondirectory buffer-file-name)))
           ;; Create a directory name based on the buffer file name
           ;; [2024-12-11 Wed 09:22] changed "-images" to ""
           (dir (concat base-name ""))
           ;; Ensure the directory exists
           (_ (unless (file-exists-p dir)
                (make-directory dir)))
           ;; Generate the image file name
           (filename (format "%sscreenshot.png" (format-time-string "_%Y%m%d_%H%M%S")))
           ;; Full path in WSL
           (filepath (expand-file-name filename dir))
           ;; Convert the path to Windows format
           (win-path (string-trim
                      (shell-command-to-string
                       (concat "wslpath -w "
                               (shell-quote-argument filepath)))))
           ;; Construct the PowerShell command
           (ps-command (concat
                        "Add-Type -AssemblyName System.Windows.Forms;"
                        "Add-Type -AssemblyName System.Drawing;"
                        "if ([System.Windows.Forms.Clipboard]::ContainsImage()) {"
                        "$img = [System.Windows.Forms.Clipboard]::GetImage();"
                        "$img.Save('" win-path "', [System.Drawing.Imaging.ImageFormat]::Png);"
                        "} else {"
                        "Write-Host 'No image found in clipboard.'; exit 1;"
                        "}")))
      ;; Run the PowerShell command
      (let ((exit-code (call-process "powershell.exe" nil "*wsl-org-download-clipboard*" nil
                                     "-Command" ps-command)))
        (if (and (eq exit-code 0) (file-exists-p filepath))
            (progn
              ;; Insert the #+attr_org line above the link
              (insert "#+attr_org: :width 600px\n")
              ;; Insert the link to the image under the cursor
              (insert (format "[[file:%s]]" (file-relative-name filepath)))
              ;; Optionally, add a newline after inserting the link
              ;; (insert "\n")
              )
          (error "Failed to save image from clipboard. Check *wsl-org-download-clipboard* buffer for details."))))))

(defun wsl-copy-to-clipboard (start end)
  "Copy the selected region or the entire buffer to the Windows clipboard using clip.exe."
  (interactive "r")
  (let ((text-to-copy (buffer-substring-no-properties start end)))
    (with-temp-buffer
      (insert text-to-copy)
      ;; Call clip.exe directly with the buffer contents
      (call-process-region (point-min) (point-max) "/mnt/c/Windows/system32/clip.exe"))))

;; in terminal mode it can be used without shift
(map! "S-C-v" #'wsl-paste-from-clipboard)
;; couldn't get it to work for some reason
;; (map! :v "C-S-c" #'wsl-copy-to-clipboard)
(map! :v "C-c c" 'wsl-copy-to-clipboard)


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

(defun wsl-open-image-in-nsxiv ()
  "Open the image file link under the cursor in nsxiv via wsl.exe."
  (interactive)
  ;; Get the Org element at point
  (let* ((element (org-element-context)))
    ;; Check if the element is a file link
    (if (and (eq (org-element-type element) 'link)
             (string= (org-element-property :type element) "file"))
        (let* ((path (org-element-property :path element))
               (full-path (expand-file-name path)))
          (if (file-exists-p full-path)
              ;; Pass the path to nsxiv via wsl.exe
              (start-process "nsxiv" nil "wsl.exe" "nsxiv" full-path)
            (message "File does not exist: %s" full-path)))
      (message "No valid file link under cursor."))))

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
