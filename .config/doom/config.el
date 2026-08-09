;; Some functionality uses this to identify you, e.g. GPG configuration, email
;; clients, file templates and snippets. It is optional.
(setq user-full-name "user"
      user-mail-address "user@example.com")

(setq doom-theme 'doom-city-lights)

(setq doom-font (font-spec :family "JetBrains Mono" :size 12)
      doom-variable-pitch-font (font-spec :family "JetBrains Mono" :height 1.3)
      doom-unicode-font (font-spec :family "JetBrains Mono")
      doom-big-font (font-spec :family "JetBrains Mono" :size 22))

;; This may cause problems on Wayland (white background)
;; change theme background
;; https://www.reddit.com/r/DoomEmacs/comments/ig6ubw/how_to_properly_change_backgroundcolor_other_than/
;; enlarge org mode title font size - DOESN'T WORK - USE DOOM-DOCS-MODE INSTEAD
;; https://www.reddit.com/r/DoomEmacs/comments/13wkam9/how_to_toggle_size_of_headers_font_in_org_mode/?sort=new
;; https://stackoverflow.com/questions/21525436/orgmode-title-levels-height/76374044
;; (custom-theme-set-faces! 'doom-city-lights
;;   '(default :background "#10151a")
;;   )
;; (custom-theme-set-faces! 'doom-city-lights
;;   ;; This also borks all colors.
;;   ;; I've ended up editing doom-city-lights.el file directly - stupid.
;;   ;; https://www.reddit.com/r/DoomEmacs/comments/17i2x9v/is_there_any_documentation_for/
;;   ;; '(default :background "#10151a")
;;   ;; This makes everything "go white" on wayland.
;;   ;; '(default :foreground "#ffffff")
;;   '(org-level-1 :inherit outline-1 :height 1.2)
;;   '(org-level-2 :inherit outline-2 :height 1.0)
;;   '(org-level-3 :inherit outline-3 :height 1.0)
;;   )

;; For relative line numbers, set to `relative'.
(setq display-line-numbers-type nil)

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

;; (centered-window-mode)

(defun my-multi-occur-in-matching-buffers (regexp &optional allbufs)
  "https://stackoverflow.com/questions/2641211/emacs-interactively-search-open-buffers"
  (interactive (occur-read-primary-args))
  (multi-occur-in-matching-buffers "." regexp allbufs))

(defun my-multi-occur-in-all-matching-buffers (regexp &optional allbufs)
  "search only notmuch messages"
  (interactive (occur-read-primary-args))
  (multi-occur-in-matching-buffers "." regexp (not allbufs)))

(defun my-multi-occur-in-notmuch-message-matching-buffers (regexp &optional allbufs)
  "search only in notmuch messages"
  (interactive (occur-read-primary-args))
  (multi-occur-in-matching-buffers "notmuch" regexp (not allbufs)))

(defun notmuch-tree-show-all-messages ()
  "open all notmuch emails and run multi-occur
   https://emacs.stackexchange.com/questions/77535/open-all-emails-in-notmuch-tree-search-buffer"
  (interactive)
  (goto-char (point-min))
  (while (and (not (eobp)) (not (get-buffer (notmuch-tree-get-message-id))))
    (notmuch-tree-show-message-out)
    (previous-buffer)
    (forward-line 1)))

(map! :leader "s q" 'my-multi-occur-in-matching-buffers)
(map! :leader "s Q" 'my-multi-occur-in-all-matching-buffers)

;; add TAB to jump to occurances
(map! :map occur-mode-map "<tab>" 'occur-mode-display-occurrence)

;; push button with TAB
(map! :map button-map "<tab>" 'push-button)

(map! :map doom-leader-map "p /" 'helm-projectile-rg)

;; commented it out, because need cursor to be in backtrace after all (to show local variables)
;; (defun edebug-pop-to-backtrace-and-return ()
;;         (interactive)
;;         (edebug-pop-to-backtrace)
;;         (windmove-up))
;; (map! :map edebug-mode-map "d" 'edebug-pop-to-backtrace-and-return)
;; oh boy this took ages
(map! :map backtrace-mode-map :after backtrace :n "d" 'backtrace-toggle-locals)
(map! :map backtrace-mode-map :after backtrace :n "n" 'edebug-next-mode)

;; use zathura or whatever is default when clicking on attachment
;; modified also in ~/.mailcap
(setq notmuch-show-part-button-default-action 'notmuch-show-view-part)

;; preview messages with TAB key (ENTER by default)
(map! :map notmuch-search-mode-map "<tab>" 'notmuch-search-show-thread)

;; preview messages with TAB key (ENTER by default)
(map! :map notmuch-tree-mode-map "<tab>" 'notmuch-tree-show-message)
(map! :map notmuch-tree-mode-map "<tab>" 'notmuch-tree-show-message-in)

;; This apparently must be set before org loads
(setq org-directory "/home/user1/notes")
(setq org-roam-directory "/home/user1/notes/org-roam")

;; quickly add timestamps to new headings - hack
;; it may be useful for taking minutes during meetings
;; add timestamp to new list items: C-RET or M-RET
;; https://www.reddit.com/r/orgmode/comments/14br2xi/automatic_timestamps_in_listsheaders/
(defun org-insert-heading-with-timestamp (&rest r)
  (insert (format-time-string "~%H:%M:%S~ ")))
(defun org-insert-heading-with-timestamp-enable ()
  (interactive)
  (advice-add 'org-insert-item :after #'org-insert-heading-with-timestamp))
(defun org-insert-heading-with-timestamp-disable ()
  (interactive)
  (advice-remove 'org-insert-item 'org-insert-heading-with-timestamp))

;; to prettify org mode (hide title headers and =formatting= characters)
;; I had to disable it, because it was hiding inline images
;; (add-hook! 'org-mode-hook 'doom-docs-mode)
(advice-add #'org-mode-hook :after '+word-wrap-mode)

;; by default it was 8 characters
;; indent modified with double ">" keybyinding
;; https://github.com/doomemacs/doomemacs/issues/8268
(add-hook 'after-change-major-mode-hook (lambda () (setq evil-shift-width 2)))

(after! org

  ;; lord have mercy on doom emacs mess of keybinding precedence system
  ;; Remove the global bindings
  (map! :map global-map "C-S-<return>" nil)
  (map! :map global-map "C-<return>" nil)
  (map! :map global-map "M-h" nil)
  (map! :map global-map "M-l" nil)

  ;; Remove from evil states
  (map! :map evil-normal-state-map "C-<return>" nil)
  (map! :map evil-insert-state-map "C-<return>" nil)
  (map! :nvi "C-S-<return>" nil)
  (map! :nvi "C-S-RET" nil)

  ;; Add our org-specific bindings
  (map! :map org-mode-map
        "C-<return>" #'+org/insert-item-below
        "C-S-<return>" #'+org/insert-item-above
        "M-k" #'org-metaup
        "M-j" #'org-metadown
        "S-M-j" #'org-shiftmetaright
        "S-M-h" #'org-shiftmetaleft
        "M-h" #'org-metaleft
        "M-l" #'org-metaright)

  ;; by default 1000
  ;; orgzly tasks are SCHEDULED, which causes unfinished ones to accumulate in agenda
  ;; this will limit them to show them only up to 14 days instead
  (setq org-scheduled-past-days 14)

  ;; https://github.com/doomemacs/doomemacs/issues/8107#issuecomment-2400953977
  ;; sets directory name to save images using org-download-clipboard function
  ;; (setq-hook! 'org-mode-hook org-download-image-dir (concat (file-name-sans-extension (file-name-nondirectory buffer-file-name)) "-images"))

  ;; https://emacs.stackexchange.com/a/79627/39118
  ;; (defun org-no-frills-copy (beg end)
  ;;   (interactive "r")
  ;;   (let ((kill-transform-function (lambda (text)
  ;;                                    (replace-regexp-in-string "^*+ \\|:[[:alnum:]:]*:" "" text))))
  ;;     (clipboard-kill-ring-save beg end)))

  ;; This stopped working on wayland
  ;; https://github.com/tefkah/doom-emacs-config/blob/main/config.org
  (custom-set-faces!
    '((org-block) :background "#182027")
    )

  ;; I've had to give up on this - org-yt package seems to break loading order
  ;; https://github.com/TobiasZawada/org-yt/issues/6#issue-1826702028
  ;; pinning org-mode version: https://github.com/org-roam/org-roam/issues/2361#issuecomment-1650957932
  (advice-remove 'org-display-inline-images 'org-display-user-inline-images)

  (add-to-list 'org-capture-templates
               '("T" "Custom todo" entry
                 (file+headline +org-capture-todo-file "inbox")
                 "* TODO %?\n%i%u\n%a" :prepend t))
  (add-to-list 'org-capture-templates
               '("J" "Custom Journal" entry
                 (file+olp+datetree +org-capture-journal-file)
                 "* =%<%H:%M>= %?\n%i\n%a" :kill-buffer t))

  ;; oh god why was it sooooo hard (10 hours+)
  (org-wild-notifier-mode)
  (setq alert-default-style 'libnotify
        org-wild-notifier-alert-time '(0 15 60)
        org-wild-notifier-keyword-whitelist nil
        ;; good for testing
        org-wild-notifier--alert-severity 'high
        alert-fade-time 50
        )
  ;; https://www.reddit.com/r/orgmode/comments/14bx0v4/open_orgcapture_frame_maximized_to_the_window/
  ;; needs to be inside after! org block
  (defun stag-misanthropic-capture (&rest r)
    (delete-other-windows))
  (advice-add  #'org-capture-place-template :after 'stag-misanthropic-capture)
  (setq org-emphasis-alist
        '(("*" (bold))
          ;; ("/" italic)
          ("_" underline)
          ("=" (:foreground "#8bd49c"))
          ("~" (:foreground "#5ec4ff"))
          ("+" (:strike-through t))))
  ;; https://stackoverflow.com/questions/26204223/display-formatted-text-in-org-mode-without-formatting-characters
  (setq org-hide-emphasis-markers t)

  ;; specified in org-agenda-custom-commands instead
  (setq org-agenda-files '("/home/user1/notes/todo.org"
                           "/home/user1/notes/orgzly/todo.org"
                           ))
  ;; graphical line between org-agenda sections (blocks)
  ;; couldn't decide on the right look, 32 is still a bit too big, ideally it would be a single line
  ;; (setq org-agenda-block-separator 9472)
  (setq org-agenda-block-separator 32)
  ;; (setq org-agenda-block-separator nil)
  (setq org-tag-alist '(("priority")
                        ("ongoing")
                        ("idea")
                        ("planning")
                        ("materials")
                        ;; ("")
                        ))
  ;; https://github.com/zyrohex/.doom.d#agenda
  (setq org-agenda-custom-commands
        '(("o" "overview"
           ((agenda "" (
                        (org-agenda-overriding-header "")
                        (org-agenda-span '15)
                        ))
            (tags-todo "priority"
                       ((org-agenda-overriding-header "⚛ priority")
                        ;; graphical change to avoid repeating tags in agenda view (on the right)
                        (org-agenda-remove-tags t)
                        (org-agenda-todo-ignore-scheduled t)
                        (org-agenda-todo-ignore-deadlines t)
                        (org-agenda-todo-ignore-with-date t)
                        (org-tags-match-list-sublevels 'indented)
                        (org-agenda-sorting-strategy
                         '(category-up))))
            ;; source of endless frustration
            ;; https://emacs.stackexchange.com/questions/18179/org-agenda-command-with-org-agenda-filter-by-tag-not-working
            (alltodo "" (
                         (org-agenda-overriding-header " inbox")
                         (org-agenda-todo-ignore-scheduled t)
                         (org-agenda-todo-ignore-deadlines t)
                         (org-agenda-todo-ignore-with-date t)
                         (org-agenda-skip-function '(org-agenda-skip-entry-if 'regexp ":priority:\\|:ongoing:\\|:idea:"))
                         ))
            (tags-todo "ongoing"
                       ((org-agenda-overriding-header "📌 ongoing")
                        ;; graphical change to avoid repeating tags in agenda view (on the right)
                        (org-agenda-remove-tags t)
                        (org-agenda-todo-ignore-scheduled t)
                        (org-agenda-todo-ignore-deadlines t)
                        (org-agenda-todo-ignore-with-date t)
                        (org-tags-match-list-sublevels 'indented)
                        (org-agenda-sorting-strategy
                         '(category-up))))
            (tags-todo "idea"
                       ((org-agenda-overriding-header "🔍 idea")
                        ;; graphical change to avoid repeating tags in agenda view (on the right)
                        (org-agenda-remove-tags t)
                        (org-agenda-todo-ignore-scheduled t)
                        (org-agenda-todo-ignore-deadlines t)
                        (org-agenda-todo-ignore-with-date t)
                        (org-tags-match-list-sublevels 'indented)
                        (org-agenda-sorting-strategy
                         '(category-up))))
            ))
          ("p1" "project-1"
           ((agenda "" (
                        (org-agenda-overriding-header "")
                        (org-agenda-files '("/home/user1/notes/todo-project1.org"))
                        (org-agenda-span '8)
                        ))
            (tags-todo "priority"
                       ((org-agenda-overriding-header "⚛ priority")
                        (org-agenda-files '("/home/user1/notes/todo-project1.org"))
                        (org-agenda-todo-ignore-scheduled t)
                        (org-agenda-todo-ignore-deadlines t)
                        (org-agenda-todo-ignore-with-date t)
                        (org-tags-match-list-sublevels 'indented)
                        (org-agenda-sorting-strategy
                         '(category-up))))
            ;; i swear you just can't make up this shit:
            ;; https://emacs.stackexchange.com/questions/18179/org-agenda-command-with-org-agenda-filter-by-tag-not-working
            (alltodo "" (
                         (org-agenda-overriding-header " inbox")
                         (org-agenda-skip-function '(org-agenda-skip-entry-if 'regexp ":priority:\\|:ongoing:\\|:idea:"))
                         (org-agenda-files '("/home/user1/notes/todo-project1.org"))
                         ))
            (tags-todo "ongoing"
                       ((org-agenda-overriding-header "📌 ongoing")
                        (org-agenda-files '("/home/user1/notes/todo-project1.org"))
                        (org-agenda-todo-ignore-scheduled t)
                        (org-agenda-todo-ignore-deadlines t)
                        (org-agenda-todo-ignore-with-date t)
                        (org-tags-match-list-sublevels 'indented)
                        (org-agenda-sorting-strategy
                         '(category-up))))
            (tags-todo "idea"
                       ((org-agenda-overriding-header "🔍 idea")
                        (org-agenda-files '("/home/user1/notes/todo-project1.org"))
                        (org-agenda-todo-ignore-scheduled t)
                        (org-agenda-todo-ignore-deadlines t)
                        (org-agenda-todo-ignore-with-date t)
                        (org-tags-match-list-sublevels 'indented)
                        (org-agenda-sorting-strategy
                         '(category-up))))
            ))
          ;;             trying to list all scheduled tasks for notifications service, but doesn't work
          ;;             ("sc" "overview" (
          ;; (alltodo "" (
          ;;              (org-agenda-todo-ignore-deadlines t)
          ;;              (org-agenda-todo-ignore-with-date t)
          ;;             ))))
          ))

  (setq org-confirm-babel-evaluate t)
  (setq org-icalendar-combined-agenda-file "~/notes/org-agenda.ics")
  (setq org-icalendar-include-todo t)
  ;; start calendar on monday instead of sunday
  (setq calendar-week-start-day 1)

  (add-to-list 'org-structure-template-alist '("py" . "src python"))
  (add-to-list 'org-structure-template-alist '("sh" . "src shell"))

  (setq org-startup-with-inline-images t)
  ;; (set-face-font 'org-quote (font-spec :family "noto serif"))
  (custom-set-faces!
    '(org-document-title :height 1.75 :weight extrabold)
    ;; '(org-level-1 :inherit outline-1 :height 1.2 :weight bold :slant normal)
    ;; '(org-level-2 :inherit outline-2 :height 1.1 :weight bold :slant normal)
    ;; '(org-level-3 :inherit outline-3 :height 1.1 :weight regular :slant normal)
    ;; '(org-document-info  :inherit 'nano-face-faded)
    )
  ;; https://stackoverflow.com/questions/11718401/how-to-use-todo-tags-in-org-mode-without-defining-headings
  ;; https://www.reddit.com/r/orgmode/comments/14w45bt/how_to_use_orginline_task/
  ;; (require 'org-inlinetask)
  )

;; couldn't add this directly to org-mode-map
(map! :leader "d d" 'org-cut-subtree)

(map! :leader "e h" 'org-pandoc-export-to-html5-and-open)

;; for org-structure-template-alist
;; https://www.youtube.com/live/kkqVTDbfYp4?feature=share&t=723
(use-package! org-tempo
  :after org)

(use-package! org-ql
  :after org)

;; https://github.com/doomemacs/doomemacs/issues/7414#issuecomment-1732461759
(use-package! htmlz :commands (htmlz-mode))

;; moved to after! org
;; https://github.com/doomemacs/doomemacs/issues/8107#issuecomment-2400953977
(add-hook 'org-mode-hook
          (lambda ()
            (when buffer-file-name
              (setq org-download-image-dir
                    (concat (file-name-sans-extension (file-name-nondirectory buffer-file-name)) "-images")))))

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
  (setq-default org-download-heading-lvl 'nil)
  )

;; https://discourse.doomemacs.org/t/org-time-stamp-only-gives-date-no-time-hoursseconds/3269/3
;; (after! org
;;   (setq org-time-stamp-formats '("<%Y-%m-%d %a %H:%M>" . "<%Y-%m-%d %a %H:%M>")))

(setq deft-directory "/home/user1/notes"
      deft-recursive t)

(after! dap-mode
  (setq dap-python-debugger 'debugpy)
  ;; still can't seem to get rid of controls
  (setq dap-auto-configure-features '(locals tooltip))
  )

;; don't put deleted strings to X11 clipboard
(setq select-enable-clipboard nil)

;; https://www.reddit.com/r/orgmode/comments/14cm6j0/comment/jomihz4/?utm_source=share&utm_medium=web2x&context=3
(defun org-copy-visible-X11-clipboard (beg end)
  (interactive "r")
  (let ((select-enable-clipboard t))
    (org-copy-visible beg end)))

;; god damn I had to give up on this trash
;; https://github.com/doomemacs/doomemacs/issues/7257#issuecomment-1648522478
;; https://github.com/millejoh/emacs-ipython-notebook/issues/873
;; https://emacs.stackexchange.com/questions/14432/initialize-ipython-notebook-server-from-ipynb-file/77386
;; (add-hook 'ein:ipynb-mode-hook
;;           (lambda ()
;;             (cl-letf (((symbol-function 'read-directory-name)
;;                        (lambda (_prompt dir &rest _args) dir)))
;;               (ein:process-open-notebook nil (lambda (&rest _args)
;;               (mapc 'switch-to-buffer
;;                      (cl-remove-if-not (lambda (b)
;;                       (and
;;                        (string-match-p "ein" (buffer-name b))
;;                        (string-match-p "ipynb" (buffer-name b))))
;;                     (buffer-list)))
;;               (delete-other-windows)))
;;                 )))

;; henrik tried to solve it
;; https://github.com/doomemacs/doomemacs/issues/7257#issuecomment-1648522478
;; (add-hook! 'ein:ipynb-mode-hook
;;   ;; By adding it to this hook, we can be sure that the server
;;   ;; won't be started until the buffer is visible (prevents a
;;   ;; cascade of new processes when opening multiple *.ipynb files
;;   ;; all at once.
;;   (add-hook 'doom-switch-buffer-hook #'ein:process-open-notebook nil 'local))

;; https://emacs.stackexchange.com/questions/58339/async-shell-command-run-command-without-displaying-the-output
;; open an external shell and...
(defun open-terminal-alacritty ()
  (interactive)
  (add-to-list 'display-buffer-alist '("*Async Shell Command*" display-buffer-no-window (nil)))
  (async-shell-command "alacritty -e tmux" nil nil))


;; ...replace doom's default keybinding for vterm
(map! :leader "o t" 'open-terminal-alacritty)

;; I've lost sooo much time getting this to work, but
;; all it does is copying and pasting selected text to and from X11 clipboard
;; [2024-10-18 Fri 23:12] moved it to copy-selection-to-clipboard
;; it didn't seem to work in terminal
;; (map! "S-C-c" 'clipboard-kill-ring-save)
(map! "S-C-v" 'clipboard-yank)

(defun copy-selection-to-clipboard ()
  "Copy the selected region to the host clipboard."
  (interactive)
  (if (use-region-p)
      (clipboard-kill-ring-save (region-beginning) (region-end))
    (message "No region selected")))

(map! "S-C-c" 'copy-selection-to-clipboard)

(defun save-clipboard-image-to-file ()
  "Save clipboard image to a file in an images directory and insert org-mode link.
The image will be saved in a subdirectory named after the current buffer's file
name with '-images' suffix. The image filename will include timestamp.
Requires wl-clipboard package on Wayland systems."
  (interactive)
  (let* ((buffer-file (buffer-file-name))
         (buffer-name (when buffer-file
                        (file-name-sans-extension
                         (file-name-nondirectory buffer-file))))
         (date-time (format-time-string "%Y%m%d_%H%M%S"))
         (image-dir (when buffer-name
                      (concat (file-name-directory buffer-file)
                              buffer-name "-images")))
         (image-name (concat "_" date-time ".png"))
         (image-file (when image-dir
                       (expand-file-name image-name image-dir))))

    (if (not buffer-file)
        (message "Buffer is not visiting a file!")
      (progn
        ;; Create directory if it doesn't exist
        (unless (file-exists-p image-dir)
          (make-directory image-dir))

        ;; Save clipboard image using wl-paste
        (if (eq 0 (call-process-shell-command
                   (format "wl-paste --type image/png --no-newline > %s"
                           (shell-quote-argument image-file))
                   nil nil))
            (progn
              ;; Insert org-mode link at point
              (insert (format "#+attr_org: :width 600px\n[[file:%s-%s/%s]]"
                              buffer-name
                              "images"
                              image-name))
              (message "Image saved and linked!"))
          (message "No image data in clipboard or wl-paste failed!"))))))

(map! :leader "m a p" 'save-clipboard-image-to-file)

;; centaur tabs activate
;; (setq centaur-tabs-set-bar t)

;; link below where I'm groking how to override keybindings
;; turns out :nvi and other states are the way to do that in doom emacs
;; to prevent evil keybindings from taking over
;; https://discourse.doomemacs.org/t/how-to-bind-keys-with-higher-precedence-than-evil-keybindings/3743/3
;; (map! :nvi "C-<tab>" 'centaur-tabs-forward)
;; (map! :nvi "C-<iso-lefttab>" 'centaur-tabs-backward)

;; opening a new tab works strangely - opens a new group or whatever
;; use once groked
;; (map! :nvi "C-t" #'centaur-tabs--create-new-tab)

;; speed up which-key's buffer prompt
(setq which-key-idle-delay 0.25)

;; allow which-key to expand side-window to half the frame's height
(setq which-key-side-window-max-height 0.5)

(setq elfeed-feeds (quote (
                           ("https://lwn.net/headlines/rss" linux)
                           ("https://archlinux.org/feeds/news/" archlinux)
                           ("https://rss.slashdot.org/Slashdot/slashdotMain" linux)
                           ("https://www.phoronix.com/rss.php" linux)
                           ("https://architectsjournal.co.uk/feed" architecture)
                           ("https://community.osarch.org/discussions/feed.rss" architecture)
                           ("https://feeds.feedburner.com/Archdaily" architecture)
                           ("https://www.dezeen.com/rss" architecture)
                           ("https://www.thenbs.com/nbs-knowledge-feed" architecture)
                           ;; ("https://deljurgdn.dedyn.io/feeds/all.xml?sort=Active" lemmy)
                           )))
(setq elfeed-goodies/entry-pane-size 0.7)
;; copied from distrotube
(evil-define-key 'normal elfeed-show-mode-map
  (kbd "J") 'elfeed-goodies/split-show-next
  (kbd "K") 'elfeed-goodies/split-show-prev)
(evil-define-key 'normal elfeed-search-mode-map
  (kbd "J") 'elfeed-goodies/split-show-next
  (kbd "K") 'elfeed-goodies/split-show-prev)

;; Had to fork it and modify it
;; Originally it only provides modeline notifications
;; Even after modifying it, it only provided count of articles (read and unread).
(use-package! elfeed-system-notifier
  :defer t
  :commands elfeed-notifier-mode)
(elfeed-notifier-mode)

(defun elfeed-desktop-notifications (entry)
  "Parse and display new feeds as desktop notifications."
  (alert (elfeed-deref (elfeed-entry-content entry))
         :title (concat
                 (elfeed-feed-title (elfeed-deref (elfeed-entry-feed entry))) "\n"
                 (elfeed-deref (elfeed-entry-title entry))
                 )
         ;; :severity 'high
         ))

(add-hook! 'elfeed-new-entry-hook #'elfeed-desktop-notifications)

(defun toggle-last-buffer ()
  "Toggle between the current buffer and the last buffer."
  (interactive)
  (switch-to-buffer (other-buffer (current-buffer) 1)))

(map! :n "<C-tab>" #'toggle-last-buffer)

(advice-add 'kill-current-buffer :after #'+workspace/close-window-or-workspace)

(defun my/org-entry-range ()
  (let ((elt (org-element-at-point)))
    (cons (org-element-property :begin elt)
          (org-element-property :end elt))))

(defun my/make-invisible (range)
  "Hide text in RANGE and protect it from accidental edits."
  (let ((ov (make-overlay (car range) (cdr range))))
    (overlay-put ov 'invisible     t)   ; hide it
    (overlay-put ov 'org-hide-done t)   ; tag so we can find/remove later
    (overlay-put ov 'evaporate     t)   ; remove ov if text really *is* killed
    (overlay-put ov 'intangible    t)   ; keep point out
    (overlay-put ov 'read-only     t))) ; forbid edits while hidden

(defun my/org-hide-done-tasks ()
  (mapc #'my/make-invisible
        (org-map-entries #'my/org-entry-range "TODO=\"DONE\"" 'file)))

(defun my/org-toggle-done-tasks-visibility ()
  "Toggle visibility of DONE tasks in the current buffer."
  (interactive)
  (if (seq-find (lambda (ov) (overlay-get ov 'org-hide-done))
                (overlays-in (point-min) (point-max)))
      ;; DONE entries are hidden $(B"*(B show them
      (remove-overlays (point-min) (point-max) 'org-hide-done t)
    ;; otherwise hide them
    (my/org-hide-done-tasks)))
