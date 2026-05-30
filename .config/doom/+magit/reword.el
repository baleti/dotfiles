;;; +magit/reword.el --- Commit reword and remove  -*- lexical-binding: t; -*-

;;; Commit reword

(defvar-local branch-off/magit-reword--commit nil)
(defvar-local branch-off/magit-reword--source-buffer nil)
(defvar-local branch-off/magit-reword--source-line nil)
(defvar-local branch-off/magit-reword--from-revision nil)

(defun branch-off/magit-reword--fix-highlight ()
  "Reposition highlights to the current line after a programmatic cursor move."
  (mapc #'delete-overlay magit-section-highlight-overlays)
  (setq magit-section-highlight-overlays nil)
  (hl-line-highlight))

(defun branch-off/magit-reword--refresh-log (line)
  "Refresh the magit-log buffer and restore point to LINE."
  (when-let ((log-buf (magit-get-mode-buffer 'magit-log-mode)))
    (with-current-buffer log-buf (magit-refresh))
    (when-let ((win (get-buffer-window log-buf)))
      (with-selected-window win
        (goto-char (point-min))
        (forward-line (1- line))
        (branch-off/magit-reword--fix-highlight))
      (run-with-timer 0 nil
        (lambda ()
          (when-let ((w (get-buffer-window log-buf)))
            (with-selected-window w
              (forward-line 1)
              (forward-line -1))))))))

(defun branch-off/magit-reword--parse-commit (hash)
  "Return plist for HASH: :tree :parent :author-name :author-email :author-date
:committer-name :committer-email :committer-date."
  (let (result)
    (dolist (line (split-string
                   (with-temp-buffer
                     (call-process "git" nil t nil "cat-file" "commit" hash)
                     (buffer-string))
                   "\n"))
      (cond
       ((string-match "^tree \\(.+\\)$" line)
        (setq result (plist-put result :tree (match-string 1 line))))
       ((string-match "^parent \\(.+\\)$" line)
        (setq result (plist-put result :parent (match-string 1 line))))
       ((string-match "^author \\(.*\\) <\\(.*\\)> \\([0-9]+ [+-][0-9]+\\)$" line)
        (setq result (plist-put result :author-name  (match-string 1 line)))
        (setq result (plist-put result :author-email (match-string 2 line)))
        (setq result (plist-put result :author-date  (match-string 3 line))))
       ((string-match "^committer \\(.*\\) <\\(.*\\)> \\([0-9]+ [+-][0-9]+\\)$" line)
        (setq result (plist-put result :committer-name  (match-string 1 line)))
        (setq result (plist-put result :committer-email (match-string 2 line)))
        (setq result (plist-put result :committer-date  (match-string 3 line))))))
    result))

(defun branch-off/magit-reword--new-commit (info new-parent msg)
  "Create a commit object from INFO plist, overriding parent with NEW-PARENT and message with MSG.
NEW-PARENT nil keeps the :parent from INFO.  Return new hash string."
  (let* ((tree   (plist-get info :tree))
         (parent (or new-parent (plist-get info :parent)))
         (process-environment
          (append
           (list (format "GIT_AUTHOR_NAME=%s"     (plist-get info :author-name))
                 (format "GIT_AUTHOR_EMAIL=%s"    (plist-get info :author-email))
                 (format "GIT_AUTHOR_DATE=%s"     (plist-get info :author-date))
                 (format "GIT_COMMITTER_NAME=%s"  (plist-get info :committer-name))
                 (format "GIT_COMMITTER_EMAIL=%s" (plist-get info :committer-email))
                 (format "GIT_COMMITTER_DATE=%s"  (plist-get info :committer-date)))
           process-environment))
         (args (append (list "commit-tree" tree "-m" msg)
                       (when parent (list "-p" parent)))))
    (apply #'magit-git-string args)))

(defun branch-off/magit-reword--cascade-branch-off (remap)
  "Rewrite all refs/branch-off/* whose parent changed according to REMAP.
Scans all branch-off refs; for each whose parent is a key in REMAP, creates
a new commit with the updated parent, replaces the ref, and adds the mapping
to REMAP.  Repeats until no further refs change, so chains of branch-off
commits are fully propagated.  Returns the augmented remap."
  (let ((bo-refs (split-string
                  (with-temp-buffer
                    (call-process "git" nil t nil "for-each-ref"
                                  "--format=%(refname)" "refs/branch-off/")
                    (buffer-string))
                  "\n" t))
        (changed nil))
    (dolist (ref bo-refs)
      (let* ((bo-hash   (magit-git-string "rev-parse" ref))
             (bo-info   (branch-off/magit-reword--parse-commit bo-hash))
             (bo-parent (plist-get bo-info :parent))
             (new-par   (cdr (assoc bo-parent remap))))
        (when new-par
          (let ((new-bo (branch-off/magit-reword--new-commit
                         bo-info new-par
                         (with-temp-buffer
                           (call-process "git" nil t nil "log" "-1" "--format=%B" bo-hash)
                           (buffer-string)))))
            (magit-call-git "update-ref" (format "refs/branch-off/%s" new-bo) new-bo)
            (magit-call-git "update-ref" "-d" ref)
            (push (cons bo-hash new-bo) remap)
            (setq changed t)))))
    (if changed
        (branch-off/magit-reword--cascade-branch-off remap)
      remap)))

(defun branch-off/magit-reword--apply (hash new-msg)
  "Reword HASH with NEW-MSG using git plumbing.
For branch-off refs, rewrites the commit and cascades through any chained
branch-off descendants.  For current-branch commits, rebases all descendants,
updates the branch ref, then cascades through all affected branch-off refs."
  (let* ((full-hash      (magit-git-string "rev-parse" hash))
         (branch-off-ref (format "refs/branch-off/%s" full-hash))
         (is-branch-off  (equal full-hash
                                (magit-git-string "rev-parse" "--verify" branch-off-ref))))
    (if is-branch-off
        (let* ((info     (branch-off/magit-reword--parse-commit full-hash))
               (new-hash (branch-off/magit-reword--new-commit info nil new-msg)))
          (unless new-hash (user-error "git commit-tree failed"))
          (magit-call-git "update-ref" (format "refs/branch-off/%s" new-hash) new-hash)
          (magit-call-git "update-ref" "-d" branch-off-ref)
          (branch-off/magit-reword--cascade-branch-off (list (cons full-hash new-hash))))
      (let ((branch (magit-git-string "symbolic-ref" "--short" "HEAD")))
        (unless branch
          (user-error "Cannot reword a branch commit in detached HEAD state"))
        (unless (= 0 (call-process "git" nil nil nil
                                   "merge-base" "--is-ancestor" full-hash "HEAD"))
          (user-error "Commit %s is not an ancestor of HEAD" (substring full-hash 0 8)))
        (let* ((chain  (split-string
                        (with-temp-buffer
                          (call-process "git" nil t nil "rev-list" "--reverse"
                                        (format "%s^..HEAD" full-hash))
                          (buffer-string))
                        "\n" t))
               (remap  nil)
               (target-info (branch-off/magit-reword--parse-commit full-hash))
               (new-target  (branch-off/magit-reword--new-commit target-info nil new-msg)))
          (unless new-target (user-error "git commit-tree failed"))
          (push (cons full-hash new-target) remap)
          (dolist (old-hash (cdr chain))
            (let* ((info       (branch-off/magit-reword--parse-commit old-hash))
                   (old-parent (plist-get info :parent))
                   (new-parent (or (cdr (assoc old-parent remap)) old-parent))
                   (msg        (with-temp-buffer
                                 (call-process "git" nil t nil "log" "-1" "--format=%B" old-hash)
                                 (buffer-string)))
                   (new-hash   (branch-off/magit-reword--new-commit info new-parent msg)))
              (push (cons old-hash new-hash) remap)))
          (magit-call-git "update-ref"
                          (format "refs/heads/%s" branch)
                          (cdr (assoc (car (last chain)) remap)))
          (branch-off/magit-reword--cascade-branch-off remap))))))

(defun branch-off/magit-reword--finish ()
  "Reword the target commit using git plumbing."
  (interactive)
  (let ((msg           (string-trim (buffer-substring-no-properties (point-min) (point-max))))
        (hash          branch-off/magit-reword--commit)
        (dir           default-directory)
        (source        branch-off/magit-reword--source-buffer)
        (line          branch-off/magit-reword--source-line)
        (from-revision branch-off/magit-reword--from-revision))
    (kill-buffer-and-window)
    (let ((default-directory dir))
      (branch-off/magit-reword--apply hash msg)
      (when (and from-revision (buffer-live-p source))
        (kill-buffer source))
      (branch-off/magit-reword--refresh-log line))))

(defun branch-off/magit-reword--abort ()
  "Abort reword without applying changes."
  (interactive)
  (kill-buffer-and-window)
  (message "reword: aborted"))

(defun branch-off/magit-commit-reword (commit)
  "Reword COMMIT message, editing in a dedicated buffer.
Pre-fills the buffer with the current message.  C-c C-c applies, C-c C-k aborts.
Works for both branch commits (rebases descendants and updates any branch-off refs
whose parents are in the rewritten chain) and refs/branch-off/ commits directly."
  (interactive (list (or (magit-commit-at-point)
                         (and (derived-mode-p 'magit-revision-mode)
                              magit-buffer-revision)
                         (magit-read-branch-or-commit "Reword commit"))))
  (let* ((dir          (magit-toplevel))
         (source-buf   (current-buffer))
         (from-revision (derived-mode-p 'magit-revision-mode))
         (source-line  (if from-revision
                           (with-current-buffer (magit-get-mode-buffer 'magit-log-mode)
                             (line-number-at-pos))
                         (line-number-at-pos)))
         (msg          (with-temp-buffer
                         (magit-git-insert "log" "-1" "--format=%B" commit)
                         (buffer-string)))
         (buf        (get-buffer-create
                      (format "*reword %s*" (substring commit 0 (min 7 (length commit)))))))
    (with-current-buffer buf
      (erase-buffer)
      (insert msg)
      (git-commit-mode)
      (setq-local default-directory dir)
      (setq-local branch-off/magit-reword--commit commit)
      (setq-local branch-off/magit-reword--source-buffer source-buf)
      (setq-local branch-off/magit-reword--source-line source-line)
      (setq-local branch-off/magit-reword--from-revision from-revision)
      (local-set-key (kbd "C-c C-c") #'branch-off/magit-reword--finish)
      (local-set-key (kbd "C-c C-k") #'branch-off/magit-reword--abort)
      (setq-local header-line-format
                  (list " "
                        (propertize "C-c C-c" 'face 'transient-key)
                        " apply  "
                        (propertize "C-c C-k" 'face 'transient-key)
                        " abort"))
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun branch-off/magit-commit-remove (commit)
  "Delete the refs/branch-off ref for COMMIT without touching history."
  (interactive (list (or (magit-commit-at-point)
                         (and (derived-mode-p 'magit-revision-mode)
                              magit-buffer-revision)
                         (magit-read-branch-or-commit "Remove branch-off ref for commit"))))
  (let* ((full-hash (magit-git-string "rev-parse" commit))
         (ref (format "refs/branch-off/%s" full-hash)))
    (unless (magit-git-string "rev-parse" "--verify" ref)
      (user-error "No branch-off ref for %s" (substring full-hash 0 8)))
    (magit-call-git "update-ref" "-d" ref)
    (magit-refresh)
    (message "Removed branch-off ref for %s" (substring full-hash 0 8))))
