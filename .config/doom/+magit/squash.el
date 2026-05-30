;;; +magit/squash.el --- Squash commits  -*- lexical-binding: t; -*-

;;; Squash commits (branch-off suite)

(defvar-local branch-off/magit-squash--chain nil)
(defvar-local branch-off/magit-squash--parent nil)
(defvar-local branch-off/magit-squash--tree nil)
(defvar-local branch-off/magit-squash--bo-p nil)
(defvar-local branch-off/magit-squash--branch nil)
(defvar-local branch-off/magit-squash--source-line nil)
(defvar-local branch-off/magit-squash--dir nil)
(defvar-local branch-off/magit-squash--log-buf nil)

(defvar-local branch-off/magit-squash--marks nil
  "Ordered list of commit hashes marked for squashing in this log buffer.")

(defvar-local branch-off/magit-squash--overlays nil
  "Alist of (full-hash . overlay) for marked commits in this log buffer.")

(defface branch-off/magit-squash-marked
  '((t :extend t))
  "Face applied to commit lines marked for squashing.")

(after! doom-themes
  (custom-set-faces!
    `(branch-off/magit-squash-marked
      :background ,(doom-blend (doom-color 'orange) (doom-color 'bg) 0.25)
      :extend t)))

(defun branch-off/magit-squash--clear-overlays ()
  "Delete all squash-mark overlays in the current buffer."
  (dolist (pair branch-off/magit-squash--overlays)
    (delete-overlay (cdr pair)))
  (setq branch-off/magit-squash--overlays nil))

(defun branch-off/magit-squash--mark-one (full bol)
  "Add FULL hash to marks with an overlay starting at BOL."
  (setq branch-off/magit-squash--marks (append branch-off/magit-squash--marks (list full)))
  (let* ((eol (save-excursion (goto-char bol) (end-of-line) (point)))
         (ov  (make-overlay bol (1+ eol) nil t nil)))
    (overlay-put ov 'face 'branch-off/magit-squash-marked)
    (push (cons full ov) branch-off/magit-squash--overlays)))

(defun branch-off/magit-squash--unmark-one (full)
  "Remove FULL hash from marks and delete its overlay."
  (setq branch-off/magit-squash--marks (delete full branch-off/magit-squash--marks))
  (when-let ((ov (cdr (assoc full branch-off/magit-squash--overlays))))
    (delete-overlay ov))
  (setq branch-off/magit-squash--overlays
        (cl-remove full branch-off/magit-squash--overlays :key #'car :test #'equal)))

(defun branch-off/magit-mark ()
  "Toggle squash mark on the commit at point, or on all commits in the visual selection.
With an active region (evil V), marks every commit in the selection — or
unmarks them all when every one is already marked.
Lines are highlighted with `branch-off/magit-squash-marked'.  Marks are used by
`branch-off/magit-squash' in preference to a live visual selection."
  (interactive)
  (if (not (use-region-p))
      ;; ── single commit at point ──────────────────────────────────────────────
      (let ((hash (magit-section-value-if 'commit)))
        (unless hash (user-error "No commit at point"))
        (let ((full (magit-git-string "rev-parse" hash)))
          (if (member full branch-off/magit-squash--marks)
              (progn
                (branch-off/magit-squash--unmark-one full)
                (message "Unmarked %s (%d remaining)"
                         (substring full 0 8) (length branch-off/magit-squash--marks)))
            (branch-off/magit-squash--mark-one full (line-beginning-position))
            (message "Marked %s (%d total)"
                     (substring full 0 8) (length branch-off/magit-squash--marks)))))
    ;; ── visual selection: mark/unmark all commits in region ─────────────────
    (let* ((beg (region-beginning))
           (end (region-end))
           (end-pos (save-excursion
                      (goto-char end)
                      (when (and (bolp) (> end beg)) (forward-line -1))
                      (line-beginning-position)))
           entries)
      (save-excursion
        (goto-char beg)
        (beginning-of-line)
        (while (<= (point) end-pos)
          (when-let ((hash (magit-section-value-if 'commit)))
            (let ((full (magit-git-string "rev-parse" hash)))
              (cl-pushnew (cons full (line-beginning-position)) entries
                          :key #'car :test #'equal)))
          (forward-line 1)))
      (unless entries (user-error "No commits in selection"))
      (if (cl-every (lambda (e) (member (car e) branch-off/magit-squash--marks)) entries)
          (progn
            (dolist (e entries) (branch-off/magit-squash--unmark-one (car e)))
            (message "Unmarked %d commit%s (%d remaining)"
                     (length entries) (if (= (length entries) 1) "" "s")
                     (length branch-off/magit-squash--marks)))
        (let ((newly 0))
          (dolist (e entries)
            (unless (member (car e) branch-off/magit-squash--marks)
              (branch-off/magit-squash--mark-one (car e) (cdr e))
              (cl-incf newly)))
          (message "Marked %d commit%s (%d total)"
                   newly (if (= newly 1) "" "s")
                   (length branch-off/magit-squash--marks)))))))

(defun branch-off/magit-squash--commits-in-region ()
  "Return commit hashes in the active region (display order), adjusted for evil visual-line."
  (when (use-region-p)
    (let* ((beg (region-beginning))
           (end (region-end))
           (end-pos (save-excursion
                      (goto-char end)
                      (when (and (bolp) (> end beg)) (forward-line -1))
                      (line-beginning-position)))
           commits)
      (save-excursion
        (goto-char beg)
        (beginning-of-line)
        (while (<= (point) end-pos)
          (when-let ((hash (magit-section-value-if 'commit)))
            (cl-pushnew hash commits :test #'equal))
          (forward-line 1)))
      (nreverse commits))))

(defun branch-off/magit-squash--build-chain (full-hashes)
  "Sort FULL-HASHES into a contiguous linear chain oldest-first.
Returns (SORTED-CHAIN . PARENT-OF-OLDEST) or signals `user-error'."
  (let ((parent-of (make-hash-table :test #'equal))
        (hash-set  (make-hash-table :test #'equal))
        (child-of  (make-hash-table :test #'equal)))
    (dolist (h full-hashes)
      (puthash h t hash-set)
      (let ((p (magit-git-string "rev-parse" "--verify" (format "%s^" h))))
        (puthash h (and p (not (string-empty-p p)) p) parent-of)))
    (dolist (h full-hashes)
      (let ((p (gethash h parent-of)))
        (when (and p (gethash p hash-set))
          (puthash p h child-of))))
    (let ((root (cl-find-if
                 (lambda (h) (not (gethash (gethash h parent-of) hash-set)))
                 full-hashes)))
      (unless root
        (user-error "Selected commits don't have a clear oldest commit (cycle?)"))
      (let ((chain nil) (cur root))
        (while cur
          (push cur chain)
          (setq cur (gethash cur child-of)))
        (let ((sorted (nreverse chain)))
          (unless (= (length sorted) (length full-hashes))
            (user-error "Selected commits are not a contiguous linear chain — cannot squash"))
          (cons sorted (gethash root parent-of)))))))

(defun branch-off/magit-squash--try-chain (full-hashes)
  "Try `branch-off/magit-squash--build-chain'; return nil instead of signaling on chain failure."
  (condition-case nil
      (branch-off/magit-squash--build-chain full-hashes)
    (user-error nil)))

(defun branch-off/magit-squash--sort-siblings (full-hashes)
  "Sort branch-off FULL-HASHES by committer date (oldest first) and verify a shared parent.
Returns (SORTED-LIST . COMMON-PARENT) or signals `user-error'."
  (let* ((dated (mapcar (lambda (h)
                          (cons (string-to-number
                                 (or (magit-git-string "log" "-1" "--format=%ct" h) "0"))
                                h))
                        full-hashes))
         (sorted (mapcar #'cdr (sort dated (lambda (a b) (< (car a) (car b))))))
         (parents (mapcar (lambda (h)
                            (let ((p (magit-git-string "rev-parse" "--verify"
                                                        (format "%s^" h))))
                              (and p (not (string-empty-p p)) p)))
                          sorted)))
    (unless (cl-every (lambda (p) (equal p (car parents))) (cdr parents))
      (user-error
       "Selected branch-off commits have different parents and don't form a chain — \
select commits that chain (each parent is the previous) or that all branch from the same commit"))
    (cons sorted (car parents))))

(defun branch-off/magit-squash--commit-tree (hash)
  "Return the tree SHA of commit HASH."
  (with-temp-buffer
    (call-process "git" nil t nil "rev-parse" (format "%s^{tree}" hash))
    (string-trim (buffer-string))))

;;; Conflict resolution via smerge (ediff available via C-c ^ e inside smerge)

(defvar-local branch-off/magit-squash--conflict-done-fn nil
  "Continuation called with the resolved blob SHA from the conflict buffer.")

(defvar branch-off/magit-squash--verbose nil
  "When non-nil, append the squash diff as comments to the message buffer.")

(defun branch-off/magit-squash--finish-conflict ()
  "Confirm conflict resolution and resume the in-progress squash."
  (interactive)
  (when (save-excursion
          (goto-char (point-min))
          (re-search-forward "^<<<<<<< " nil t))
    (user-error "Unresolved conflicts remain — use smerge (C-c ^ n/p) or ediff (C-c ^ e)"))
  (funcall branch-off/magit-squash--conflict-done-fn))

(defun branch-off/magit-squash--abort-conflict ()
  "Abort the squash from the conflict resolution buffer."
  (interactive)
  (kill-buffer-and-window)
  (message "Squash aborted"))

(defun branch-off/magit-squash--open-conflict-buffer (path commit-hash conflicted-content mode done-fn)
  "Open a smerge buffer for CONFLICTED-CONTENT of PATH.
DONE-FN is called with the resolved blob SHA when the user confirms with C-c C-c."
  (let ((buf (get-buffer-create (format "*squash conflict: %s*" path))))
    (with-current-buffer buf
      (erase-buffer)
      (insert conflicted-content)
      (smerge-mode 1)
      (setq-local branch-off/magit-squash--conflict-done-fn
                  (lambda ()
                    (let ((sha (with-temp-buffer
                                 (insert-buffer-substring buf)
                                 (unless (= 0 (call-process-region
                                               (point-min) (point-max)
                                               "git" t t nil "hash-object" "-w" "--stdin"))
                                   (user-error "git hash-object failed for %s" path))
                                 (string-trim (buffer-string)))))
                      (kill-buffer-and-window)
                      (funcall done-fn sha))))
      (local-set-key (kbd "C-c C-c") #'branch-off/magit-squash--finish-conflict)
      (local-set-key (kbd "C-c C-k") #'branch-off/magit-squash--abort-conflict)
      (setq-local header-line-format
                  (list (format " Conflict in %s (from %s) — " path (substring commit-hash 0 8))
                        (propertize "C-c C-c" 'face 'transient-key) " done  "
                        (propertize "C-c C-k" 'face 'transient-key) " abort  "
                        (propertize "C-c ^ e" 'face 'transient-key) " ediff"))
      (goto-char (point-min))
      (ignore-errors (smerge-next)))
    (pop-to-buffer buf)))

(defun branch-off/magit-squash--resolve-path-list (paths by-path commit-hash penv all-resolved-fn)
  "Open smerge for each path in PATHS in turn; when all done call ALL-RESOLVED-FN.
Temp index (in PENV via GIT_INDEX_FILE) is updated after each resolution."
  (if (null paths)
      (funcall all-resolved-fn)
    (let* ((path      (car paths))
           (rest      (cdr paths))
           (entry     (gethash path by-path))
           (base-sha  (plist-get entry :base))
           (ours-sha  (plist-get entry :ours))
           (their-sha (plist-get entry :theirs))
           (mode      (plist-get entry :mode)))
      (unless (and base-sha ours-sha their-sha)
        (user-error "Conflict in %s — add/delete conflict; resolve manually" path))
      (let ((base-f (make-temp-file "sq-base-"))
            (ours-f (make-temp-file "sq-ours-"))
            (thrs-f (make-temp-file "sq-thrs-")))
        (dolist (pair `((,base-sha . ,base-f) (,ours-sha . ,ours-f) (,their-sha . ,thrs-f)))
          (with-temp-buffer
            (call-process "git" nil t nil "cat-file" "blob" (car pair))
            (write-region (point-min) (point-max) (cdr pair) nil 'silent)))
        ;; Produce conflict markers in ours-f
        (call-process "git" nil nil nil "merge-file" ours-f base-f thrs-f)
        (ignore-errors (delete-file base-f))
        (ignore-errors (delete-file thrs-f))
        (let ((conflicted (with-temp-buffer
                            (insert-file-contents ours-f)
                            (buffer-string))))
          (ignore-errors (delete-file ours-f))
          (branch-off/magit-squash--open-conflict-buffer
           path commit-hash conflicted mode
           (lambda (resolved-sha)
             (let ((process-environment penv))
               (with-temp-buffer          ; remove all conflict stages
                 (insert (format "0 %s 0\t%s\n" (make-string 40 ?0) path))
                 (call-process-region (point-min) (point-max) "git" t nil nil
                                      "update-index" "--index-info"))
               (with-temp-buffer          ; add resolved blob at stage 0
                 (insert (format "%s %s 0\t%s\n" mode resolved-sha path))
                 (unless (= 0 (call-process-region (point-min) (point-max) "git" t t nil
                                                    "update-index" "--index-info"))
                   (user-error "git update-index failed for %s" path))))
             (branch-off/magit-squash--resolve-path-list rest by-path commit-hash penv
                                                  all-resolved-fn))))))))

(defun branch-off/magit-squash--merge-commits (remaining parent-tree current-tree temp-index penv done-fn)
  "Iteratively 3-way-merge REMAINING sibling commits into CURRENT-TREE.
PARENT-TREE is the constant base (shared ancestor of all siblings).
Calls DONE-FN with the final tree hash; may suspend for interactive conflict resolution."
  (if (null remaining)
      (funcall done-fn current-tree)
    (let* ((process-environment penv)
           (h        (car remaining))
           (rest     (cdr remaining))
           (bon-tree (branch-off/magit-squash--commit-tree h)))
      (call-process "git" nil nil nil "read-tree" "-i" "-m" parent-tree current-tree bon-tree)
      (let ((unmerged (with-temp-buffer
                        (call-process "git" nil t nil "ls-files" "--unmerged")
                        (buffer-string))))
        (if (string-empty-p (string-trim unmerged))
            ;; Clean merge: write tree and continue synchronously
            (let ((new-tree (with-temp-buffer
                              (unless (= 0 (call-process "git" nil t nil "write-tree"))
                                (user-error "git write-tree failed merging %s" (substring h 0 8)))
                              (string-trim (buffer-string)))))
              (branch-off/magit-squash--merge-commits rest parent-tree new-tree temp-index penv done-fn))
          ;; Conflict: parse unmerged entries, open smerge for each file, then resume
          (let ((by-path (make-hash-table :test #'equal)))
            (dolist (line (split-string unmerged "\n" t))
              (when (string-match "^\\([0-9]+\\) \\([0-9a-f]+\\) \\([123]\\)\t\\(.+\\)$" line)
                (let* ((mode  (match-string 1 line)) (sha (match-string 2 line))
                       (stage (string-to-number (match-string 3 line)))
                       (path  (match-string 4 line)))
                  (let ((e (or (gethash path by-path)
                               (let ((e (list :base nil :ours nil :theirs nil :mode nil)))
                                 (puthash path e by-path) e))))
                    (plist-put e (cl-case stage (1 :base) (2 :ours) (3 :theirs)) sha)
                    (plist-put e :mode mode)))))
            (let (paths)
              (maphash (lambda (k _) (push k paths)) by-path)
              (branch-off/magit-squash--resolve-path-list
               paths by-path h penv
               (lambda ()
                 (let ((new-tree (let ((process-environment penv))
                                   (with-temp-buffer
                                     (unless (= 0 (call-process "git" nil t nil "write-tree"))
                                       (user-error "git write-tree failed after resolving %s"
                                                   (substring h 0 8)))
                                     (string-trim (buffer-string))))))
                   (branch-off/magit-squash--merge-commits
                    rest parent-tree new-tree temp-index penv done-fn)))))))))))

(defun branch-off/magit-squash--combined-tree (parent-hash sorted-commits done-fn)
  "Async: build a merged tree from sibling SORTED-COMMITS branched from PARENT-HASH.
Calls DONE-FN with the merged tree hash; may open smerge buffers for conflicts."
  (let* ((parent-tree (branch-off/magit-squash--commit-tree parent-hash))
         (temp-index  (make-temp-file "git-squash" nil))
         (penv (append (list (format "GIT_INDEX_FILE=%s" temp-index)) process-environment)))
    (let ((process-environment penv))
      (with-temp-buffer
        (unless (= 0 (call-process "git" nil t nil "read-tree" parent-tree))
          (ignore-errors (delete-file temp-index))
          (user-error "git read-tree failed: %s" (buffer-string)))))
    (branch-off/magit-squash--merge-commits
     sorted-commits parent-tree parent-tree temp-index penv
     (lambda (tree-hash)
       (ignore-errors (delete-file temp-index))
       (funcall done-fn tree-hash)))))

(defun branch-off/magit-squash--make-info (tree-hash first-info)
  "Build a commit info plist: TREE-HASH as tree, author/committer identity from FIRST-INFO."
  (list :tree            tree-hash
        :author-name     (plist-get first-info :author-name)
        :author-email    (plist-get first-info :author-email)
        :author-date     (plist-get first-info :author-date)
        :committer-name  (plist-get first-info :committer-name)
        :committer-email (plist-get first-info :committer-email)
        :committer-date  (plist-get first-info :committer-date)))

(defun branch-off/magit-squash--apply-branch-off (sorted-chain parent-of-first tree-hash new-msg)
  "Squash SORTED-CHAIN branch-off commits into one new branch-off commit."
  (let* ((first-info (branch-off/magit-reword--parse-commit (car sorted-chain)))
         (info       (branch-off/magit-squash--make-info tree-hash first-info))
         (new-hash   (branch-off/magit-reword--new-commit info parent-of-first new-msg)))
    (unless new-hash (user-error "git commit-tree failed"))
    (magit-call-git "update-ref" (format "refs/branch-off/%s" new-hash) new-hash)
    (dolist (h sorted-chain)
      (magit-call-git "update-ref" "-d" (format "refs/branch-off/%s" h)))
    (branch-off/magit-reword--cascade-branch-off
     (mapcar (lambda (h) (cons h new-hash)) sorted-chain))
    (magit-refresh)
    (message "Squashed %d branch-off commits → %s"
             (length sorted-chain) (substring new-hash 0 8))))

(defun branch-off/magit-squash--apply-branch (sorted-chain parent-of-first tree-hash new-msg branch)
  "Squash SORTED-CHAIN branch commits into one, rebasing HEAD descendants."
  (let* ((first-info (branch-off/magit-reword--parse-commit (car sorted-chain)))
         (info       (branch-off/magit-squash--make-info tree-hash first-info))
         (new-squash (branch-off/magit-reword--new-commit info parent-of-first new-msg)))
    (unless new-squash (user-error "git commit-tree failed"))
    (let* ((last-hash   (car (last sorted-chain)))
           (descendants (split-string
                         (with-temp-buffer
                           (call-process "git" nil t nil
                                         "rev-list" "--reverse"
                                         (format "%s..HEAD" last-hash))
                           (buffer-string))
                         "\n" t))
           (remap (mapcar (lambda (h) (cons h new-squash)) sorted-chain)))
      (dolist (old-hash descendants)
        (let* ((d-info   (branch-off/magit-reword--parse-commit old-hash))
               (old-par  (plist-get d-info :parent))
               (new-par  (or (cdr (assoc old-par remap)) old-par))
               (msg      (with-temp-buffer
                           (call-process "git" nil t nil "log" "-1" "--format=%B" old-hash)
                           (buffer-string)))
               (new-hash (branch-off/magit-reword--new-commit d-info new-par msg)))
          (push (cons old-hash new-hash) remap)))
      (let* ((head-hash (magit-git-string "rev-parse" "HEAD"))
             (new-head  (or (cdr (assoc head-hash remap)) new-squash)))
        (magit-call-git "update-ref" (format "refs/heads/%s" branch) new-head))
      (branch-off/magit-reword--cascade-branch-off remap)
      (magit-refresh)
      (message "Squashed %d commits → %s"
               (length sorted-chain) (substring new-squash 0 8)))))

(defun branch-off/magit-squash--finish ()
  "Apply the squash using the message in the current buffer."
  (interactive)
  (let* ((msg    (string-trim
                  (mapconcat #'identity
                             (seq-remove (lambda (l) (string-prefix-p "#" l))
                                         (split-string
                                          (buffer-substring-no-properties (point-min) (point-max))
                                          "\n"))
                             "\n")))
         (chain  branch-off/magit-squash--chain)
         (parent branch-off/magit-squash--parent)
         (tree   branch-off/magit-squash--tree)
         (bo-p   branch-off/magit-squash--bo-p)
         (branch branch-off/magit-squash--branch)
         (line   branch-off/magit-squash--source-line)
         (dir    branch-off/magit-squash--dir))
    (when (string-empty-p msg)
      (user-error "Commit message cannot be empty"))
    (let ((log-buf branch-off/magit-squash--log-buf))
      (kill-buffer-and-window)
      (when (buffer-live-p log-buf)
        (with-current-buffer log-buf
          (setq branch-off/magit-squash--marks nil)
          (branch-off/magit-squash--clear-overlays)))
      (let ((default-directory dir))
        (if bo-p
            (branch-off/magit-squash--apply-branch-off chain parent tree msg)
          (branch-off/magit-squash--apply-branch chain parent tree msg branch))
        (branch-off/magit-reword--refresh-log line)))))

(defun branch-off/magit-squash--abort ()
  "Abort the squash."
  (interactive)
  (kill-buffer-and-window)
  (message "squash: aborted"))

(defun branch-off/magit-squash ()
  "Squash visually selected commits in the magit-log buffer into one.
Requires a visual selection; signals an error if none is active.
Opens a pre-filled message buffer combining the selected commits' messages.
C-c C-c applies, C-c C-k aborts.

For branch-off commits: supports both chained commits (each parent is the
previous) and sibling commits (all branched from the same parent commit).
For regular branch commits: the selected range must be a contiguous chain.
Respects branch-off refs and rebases HEAD after squashing branch commits."
  (interactive)
  (let ((log-buf (if (derived-mode-p 'magit-log-mode)
                     (current-buffer)
                   (or (magit-get-mode-buffer 'magit-log-mode)
                       (user-error "No magit-log buffer found")))))
    (with-current-buffer log-buf
      (let* ((raw  (if branch-off/magit-squash--marks
                       ;; Marks take priority; leave overlays visible until
                       ;; finish so abort restores the user's selection.
                       branch-off/magit-squash--marks
                     (unless (use-region-p)
                       (user-error
                        "No commits selected — mark commits with %s or visually select with V"
                        (substitute-command-keys "\\[branch-off/magit-mark]")))
                     (branch-off/magit-squash--commits-in-region))))
        (when (< (length raw) 2)
          (user-error "Select at least 2 commits to squash (got %d)" (length raw)))
        (let* ((full  (mapcar (lambda (h) (magit-git-string "rev-parse" h)) raw))
               ;; Detect branch-off before sorting so we can pick the right strategy
               (bo-p  (cl-every
                       (lambda (h)
                         (equal h (magit-git-string "rev-parse" "--verify"
                                                    (format "refs/branch-off/%s" h))))
                       full))
               ;; For branch-off: try chain first, fall back to sibling grouping.
               ;; For branch commits: require a chain (signal on failure).
               (chain-try (and bo-p (branch-off/magit-squash--try-chain full)))
               (sort-result
                (cond ((not bo-p) (branch-off/magit-squash--build-chain full))
                      (chain-try  chain-try)
                      (t          (branch-off/magit-squash--sort-siblings full))))
               (chain  (car sort-result))
               (par    (cdr sort-result))
               (branch (unless bo-p
                         (magit-git-string "symbolic-ref" "--short" "HEAD")))
               (on-branch
                (unless bo-p
                  (and branch
                       (cl-every
                        (lambda (h)
                          (= 0 (call-process "git" nil nil nil
                                             "merge-base" "--is-ancestor" h "HEAD")))
                        chain))))
               (source-line (line-number-at-pos))
               (dir  (magit-toplevel))
               (n    (length chain)))
          (unless (or bo-p on-branch)
            (user-error
             "Selected commits are not all branch-off commits or all on the current branch"))
          (let ((open-buf-fn
                 (lambda (tree-hash)
                   (let* ((combined
                           (mapconcat
                            (lambda (h)
                              (with-temp-buffer
                                (call-process "git" nil t nil "log" "-1" "--format=%B" h)
                                (string-trim (buffer-string))))
                            chain "\n\n"))
                          (buf (get-buffer-create (format "*squash %d commits*" n))))
                     (with-current-buffer buf
                       (erase-buffer)
                       (insert combined)
                       (when branch-off/magit-squash--verbose
                         (insert "\n\n")
                         (let ((diff (with-temp-buffer
                                       (let ((default-directory dir))
                                         (call-process "git" nil t nil
                                                       "diff-tree" "-r" "-p" "--no-commit-id"
                                                       par tree-hash))
                                       (buffer-string))))
                           (dolist (line (split-string diff "\n"))
                             (insert "# " line "\n"))))
                       (git-commit-mode)
                       (setq-local default-directory dir)
                       (setq-local branch-off/magit-squash--chain chain)
                       (setq-local branch-off/magit-squash--parent par)
                       (setq-local branch-off/magit-squash--tree tree-hash)
                       (setq-local branch-off/magit-squash--bo-p bo-p)
                       (setq-local branch-off/magit-squash--branch branch)
                       (setq-local branch-off/magit-squash--source-line source-line)
                       (setq-local branch-off/magit-squash--dir dir)
                       (setq-local branch-off/magit-squash--log-buf log-buf)
                       (local-set-key (kbd "C-c C-c") #'branch-off/magit-squash--finish)
                       (local-set-key (kbd "C-c C-k") #'branch-off/magit-squash--abort)
                       (setq-local header-line-format
                                   (list " "
                                         (propertize "C-c C-c" 'face 'transient-key)
                                         " squash  "
                                         (propertize "C-c C-k" 'face 'transient-key)
                                         " abort"))
                       (goto-char (point-min)))
                     (pop-to-buffer buf)))))
            (if (and bo-p (null chain-try))
                (branch-off/magit-squash--combined-tree par chain open-buf-fn)
              (funcall open-buf-fn
                       (plist-get (branch-off/magit-reword--parse-commit (car (last chain)))
                                  :tree)))))))))

(after! magit
  ;; Define here so transient is guaranteed loaded (magit requires it)
  (transient-define-suffix branch-off/magit-squash-verbose ()
    "Toggle whether the branch-off edit buffer shows the diff as comments."
    :transient t
    :description (lambda ()
                   (concat "show diff in edit buffer "
                           (if branch-off/magit-squash--verbose
                               (propertize "(on) " 'face 'success)
                             (propertize "(off)" 'face 'shadow))))
    (interactive)
    (setq branch-off/magit-squash--verbose (not branch-off/magit-squash--verbose)))
  ;; Rebase transient — Branch-off section
  (ignore-errors (transient-remove-suffix 'magit-rebase "W"))
  (ignore-errors (transient-remove-suffix 'magit-rebase "K"))
  (ignore-errors (transient-remove-suffix 'magit-rebase "S"))
  (ignore-errors (transient-remove-suffix 'magit-rebase "v"))
  (transient-append-suffix 'magit-rebase '(2)
    ["Branch-off"
     [("W" "reword" branch-off/magit-commit-reword)
      ("K" "remove" branch-off/magit-commit-remove)
      ("S" "squash" branch-off/magit-squash)]
     [("v" branch-off/magit-squash-verbose)]])
  ;; Merge transient — Branch Off section (appended after group 1 = "Actions")
  (ignore-errors (transient-remove-suffix 'magit-merge "M"))
  (transient-append-suffix 'magit-merge '(1)
    ["Branch Off"
     ("M" "toggle marker" branch-off/magit-mark)]))
