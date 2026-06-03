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

(defun branch-off/magit-commit-remove--chain-tips (full-hash)
  "Return list of tip descriptors that have FULL-HASH as ancestor (inclusive).
Each descriptor is a plist with keys:
  :hash    — full tip commit hash
  :type    — \\='bo (branch-off ref) or \\='wt (detached worktree HEAD)
  :ref     — ref name (\\='bo only)
  :wt-dir  — worktree directory path (\\='wt only)"
  (let (result)
    ;; branch-off ref tips
    (dolist (ref (split-string
                  (with-temp-buffer
                    (call-process "git" nil t nil "for-each-ref"
                                  "--format=%(refname)" "refs/branch-off/")
                    (buffer-string))
                  "\n" t))
      (let ((tip-hash (magit-git-string "rev-parse" ref)))
        (when (and tip-hash
                   (= 0 (call-process "git" nil nil nil
                                      "merge-base" "--is-ancestor" full-hash tip-hash)))
          (push (list :hash tip-hash :type 'bo :ref ref) result))))
    ;; detached-HEAD worktree tips — commits added inside a worktree after branch-off
    (let (current-wt current-head is-detached)
      (dolist (line (split-string
                     (with-temp-buffer
                       (call-process "git" nil t nil "worktree" "list" "--porcelain")
                       (buffer-string))
                     "\n"))
        (cond
         ((string-prefix-p "worktree " line)
          (setq current-wt (substring line 9) current-head nil is-detached nil))
         ((string-prefix-p "HEAD " line)
          (setq current-head (substring line 5)))
         ((string= line "detached")
          (setq is-detached t))
         ((string-blank-p line)
          (when (and current-wt current-head is-detached
                     (= 0 (call-process "git" nil nil nil
                                        "merge-base" "--is-ancestor" full-hash current-head)))
            (push (list :hash current-head :type 'wt :wt-dir current-wt) result))
          (setq current-wt nil current-head nil is-detached nil)))))
    result))

(defun branch-off/magit-commit-remove--rebase-drop (full-hash top)
  "Remove FULL-HASH from the current branch via `git rebase --onto'.
On conflict git pauses in mid-rebase state; magit shows the normal REBASING UI
and the user resolves with the usual flow then `git rebase --continue'.
After a clean rebase, cascades branch-off refs via the old→new commit remap.
Returns \\='rebase-ok or \\='rebase-conflict."
  (let* ((short          (substring full-hash 0 8))
         (removed-parent (plist-get (branch-off/magit-reword--parse-commit full-hash) :parent))
         (default-directory top))
    (unless removed-parent
      (user-error "Cannot remove root commit %s via rebase" short))
    (let ((old-chain (split-string
                      (with-temp-buffer
                        (call-process "git" nil t nil "rev-list" "--reverse"
                                      (concat full-hash "..HEAD"))
                        (buffer-string))
                      "\n" t)))
      (if (/= 0 (call-process "git" nil nil nil "rebase" "--onto"
                               removed-parent full-hash))
          (progn
            (message "Conflict removing %s — resolve in magit then `git rebase --continue'"
                     short)
            'rebase-conflict)
        (let* ((new-chain (split-string
                           (with-temp-buffer
                             (call-process "git" nil t nil "rev-list" "--reverse"
                                           (concat removed-parent "..HEAD"))
                             (buffer-string))
                           "\n" t))
               (remap (append (list (cons full-hash removed-parent))
                              (cl-mapcar #'cons old-chain new-chain))))
          (branch-off/magit-reword--cascade-branch-off remap)
          'rebase-ok)))))

(defun branch-off/magit-commit-remove--one (full-hash top)
  "Remove FULL-HASH from its chain(s) or current branch.
For branch-off/worktree chains: rewrites commits, updates refs (conflict-free).
For regular branch commits with no chain: uses `git rebase --onto' with full
conflict detection — git pauses on conflict for normal magit resolution flow.
After any successful operation cascades branch-off refs via the commit remap.
TOP is the git toplevel."
  (let* ((short (substring full-hash 0 8))
         (tips  (branch-off/magit-commit-remove--chain-tips full-hash)))
    (if (null tips)
        ;; not in any branch-off/worktree chain — try regular branch rebase
        (if (= 0 (call-process "git" nil nil nil
                                "merge-base" "--is-ancestor" full-hash "HEAD"))
            (branch-off/magit-commit-remove--rebase-drop full-hash top)
          (user-error "Commit %s is not an ancestor of HEAD or any branch-off chain" short))
      ;; found in chain(s) — plumbing-based rewrite (trees preserved)
      (let* ((is-bo-tip (equal full-hash
                               (magit-git-string "rev-parse" "--verify"
                                                 (format "refs/branch-off/%s" full-hash))))
             (bo-wt-dir (when (and top is-bo-tip)
                          (expand-file-name (concat ".worktree/" full-hash) top)))
             (bo-wt-exists (and bo-wt-dir (file-exists-p bo-wt-dir)))
             (proceed t))
        (when bo-wt-exists
          (let ((status (branch-off/delete-worktree--status bo-wt-dir)))
            (when (and (not (string= status "clean"))
                       (not (y-or-n-p (format "Worktree %s has changes (%s) — remove anyway? "
                                              short status))))
              (setq proceed nil))))
        (if (not proceed)
            'skipped
          (let* ((removed-info   (branch-off/magit-reword--parse-commit full-hash))
                 (removed-parent (plist-get removed-info :parent))
                 (remap          (list (cons full-hash removed-parent))))
            (dolist (tip-desc tips)
              (let ((tip      (plist-get tip-desc :hash))
                    (tip-type (plist-get tip-desc :type))
                    (tip-ref  (plist-get tip-desc :ref))
                    (tip-wt   (plist-get tip-desc :wt-dir)))
                (if (equal tip full-hash)
                    (pcase tip-type
                      ('bo (magit-call-git "update-ref" "-d" tip-ref))
                      ('wt (when (and removed-parent (file-exists-p tip-wt))
                             (call-process "git" nil nil nil
                                           "-C" tip-wt "reset" "--soft" removed-parent))))
                  (let ((path (split-string
                               (with-temp-buffer
                                 (call-process "git" nil t nil "rev-list"
                                               "--ancestry-path" "--reverse"
                                               (format "%s..%s" full-hash tip))
                                 (buffer-string))
                               "\n" t)))
                    (dolist (c path)
                      (let* ((info    (branch-off/magit-reword--parse-commit c))
                             (old-par (plist-get info :parent))
                             (new-par (or (cdr (assoc old-par remap)) old-par))
                             (msg     (with-temp-buffer
                                        (call-process "git" nil t nil "log" "-1" "--format=%B" c)
                                        (buffer-string)))
                             (new-c   (branch-off/magit-reword--new-commit info new-par msg)))
                        (push (cons c new-c) remap)))
                    (let ((new-tip (cdr (assoc tip remap))))
                      (pcase tip-type
                        ('bo (when new-tip
                               (magit-call-git "update-ref"
                                               (format "refs/branch-off/%s" new-tip) new-tip)
                               (magit-call-git "update-ref" "-d" tip-ref)))
                        ('wt (when (and new-tip (file-exists-p tip-wt))
                               (call-process "git" nil nil nil
                                             "-C" tip-wt "reset" "--soft" new-tip)))))))))
            (when (and is-bo-tip bo-wt-exists)
              (with-temp-buffer
                (unless (= 0 (call-process "git" nil t nil "worktree" "remove" "--force" bo-wt-dir))
                  (message "Warning: could not remove worktree for %s: %s"
                           short (string-trim (buffer-string))))))
            (branch-off/magit-reword--cascade-branch-off remap)
            (if (and is-bo-tip bo-wt-exists) 'ref-and-wt 'chain-rewrite)))))

(defun branch-off/magit-commit-remove (commit)
  "Remove commit(s) from their branch-off chain(s), rewriting descendants as needed.

From magit-log: reads m/M markers first, then visual selection, then the
commit at point.  Works for both chain tips and interior commits.  Commits
not part of any branch-off chain signal an error per commit.  Dirty
worktrees prompt y/n.  Marks are cleared after removal.  Multiple commits
from the same chain are processed descendants-first so each removal sees
the updated chain state left by prior removals.

From magit-revision or anywhere else: operates on COMMIT only."
  (interactive
   (list (cond
          ((derived-mode-p 'magit-log-mode) nil)
          ((and (derived-mode-p 'magit-revision-mode)
                (bound-and-true-p magit-buffer-revision))
           magit-buffer-revision)
          (t (or (magit-commit-at-point)
                 (magit-read-branch-or-commit "Remove commit from branch-off chain"))))))
  (if (not (derived-mode-p 'magit-log-mode))
      ;; ── single-commit path ──────────────────────────────────────────────────
      (let* ((full-hash (magit-git-string "rev-parse" commit))
             (result    (branch-off/magit-commit-remove--one full-hash (magit-toplevel))))
        (magit-refresh)
        (pcase result
          ('skipped          (message "Skipped %s" (substring full-hash 0 8)))
          ('ref-and-wt       (message "Removed branch-off ref and worktree for %s"
                                      (substring full-hash 0 8)))
          ('rebase-ok        (message "Removed %s from branch" (substring full-hash 0 8)))
          ('rebase-conflict  nil)  ; --rebase-drop already messaged
          (_                 (message "Removed %s from branch-off chain"
                                      (substring full-hash 0 8)))))
    ;; ── multi-commit path (magit-log-mode) ──────────────────────────────────
    (let* ((raw (cond
                 ((bound-and-true-p branch-off/magit-squash--marks)
                  branch-off/magit-squash--marks)
                 ((use-region-p)
                  (mapcar (lambda (h) (magit-git-string "rev-parse" h))
                          (branch-off/magit-squash--commits-in-region)))
                 (t (when-let ((h (magit-section-value-if 'commit)))
                      (list (magit-git-string "rev-parse" h))))))
           (_ (unless raw (user-error "No commits selected")))
           (top (magit-toplevel))
           ;; descendants first: each removal sees the updated chain state
           (sorted (sort (copy-sequence raw)
                         (lambda (a b)
                           (= 0 (call-process "git" nil nil nil
                                              "merge-base" "--is-ancestor" b a))))))
      (let (removed failed (conflict nil))
        (dolist (full-hash sorted)
          (unless conflict
            (condition-case err
                (let ((result (branch-off/magit-commit-remove--one full-hash top)))
                  (cond
                   ((eq result 'rebase-conflict)
                    (setq conflict (substring full-hash 0 8)))
                   ((not (eq result 'skipped))
                    (push (cons (substring full-hash 0 8) result) removed))))
              (error (push (format "%s: %s" (substring full-hash 0 8)
                                   (error-message-string err))
                           failed)))))
        (when (bound-and-true-p branch-off/magit-squash--marks)
          (setq branch-off/magit-squash--marks nil)
          (branch-off/magit-squash--clear-overlays))
        (magit-refresh)
        (cond
         (conflict
          (message "Removed %d; paused on conflict at %s — resolve then `git rebase --continue'"
                   (length removed) conflict))
         (failed
          (message "Removed %d; errors — %s"
                   (length removed) (string-join (nreverse failed) " | ")))
         (removed
          (let* ((with-wt (cl-count 'ref-and-wt removed :key #'cdr))
                 (shorts  (mapcar #'car (nreverse removed))))
            (message "Removed%s: %s"
                     (if (> with-wt 0) " (+worktree)" "")
                     (string-join shorts " "))))
         (t (message "Nothing removed")))))))))
