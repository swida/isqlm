;;; isqlm.el --- Interactive SQL Mode for MySQL  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Hadley Wang
;; URL: https://github.com/swida/isqlm
;; Keywords: sql, mysql, database, tools
;; Version: 2.1
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; ISQLM provides an interactive SQL console for MySQL, modeled after
;; Eshell's architecture — no external processes, no comint.  The mode
;; manages its own buffer, markers, prompt, and I/O directly.
;;
;; Features:
;;   - Eshell-style self-managed buffer (no comint, no external process)
;;   - Custom commands prefixed with `\' (e.g. \connect, \help)
;;   - Tabular and vertical (\G) result display
;;   - Ring-based input history with persistent file storage
;;   - Multi-line SQL input (terminated by `;' or `\G')
;;   - SQL keyword font-locking
;;
;; To start: M-x isqlm, then: \connect HOST USER PASSWORD DATABASE PORT
;; Or: M-x isqlm-connect
;; Type `\help' at the prompt for built-in commands.

;;; Code:

(require 'cl-lib)
(require 'ring)

;; ============================================================
;; Customization
;; ============================================================

(defgroup isqlm nil
  "Interactive SQL mode for MySQL."
  :group 'sql
  :group 'processes)

(defcustom isqlm-prompt "SQL> "
  "Prompt string for ISQLM."
  :type 'string :group 'isqlm)

(defcustom isqlm-prompt-continue "  -> "
  "Continuation prompt for multi-line SQL input."
  :type 'string :group 'isqlm)

(defcustom isqlm-prompt-read-only t
  "If non-nil, the ISQLM prompt is read-only."
  :type 'boolean :group 'isqlm)

(defcustom isqlm-noisy t
  "If non-nil, ISQLM will beep on errors."
  :type 'boolean :group 'isqlm)

(defcustom isqlm-history-file-name
  (locate-user-emacs-file "isqlm-history")
  "File to read/write ISQLM input history, or nil to disable."
  :type '(choice (const :tag "Disable" nil) file) :group 'isqlm)

(defcustom isqlm-history-size 512
  "Maximum number of entries in the ISQLM history ring."
  :type 'integer :group 'isqlm)

(defcustom isqlm-default-host "127.0.0.1"
  "Default MySQL host." :type 'string :group 'isqlm)

(defcustom isqlm-default-port 3306
  "Default MySQL port." :type 'integer :group 'isqlm)

(defcustom isqlm-default-user "root"
  "Default MySQL user." :type 'string :group 'isqlm)

(defcustom isqlm-default-database ""
  "Default MySQL database." :type 'string :group 'isqlm)

(defcustom isqlm-prompt-password nil
  "Whether to prompt for password when connecting.
When non-nil, `\\connect' always asks for a password via the echo area.
When nil, an empty password is used (useful for passwordless local connections)."
  :type 'boolean :group 'isqlm)

(defcustom isqlm-auto-reconnect t
  "Whether to automatically reconnect when the connection is lost.
When non-nil, if a SQL execution fails due to a lost connection,
isqlm will attempt to reconnect using the last connection parameters
and re-execute the failed SQL statement."
  :type 'boolean :group 'isqlm)

(defcustom isqlm-max-column-width 0
  "Maximum column width in result tables.
0 means no artificial limit — columns will be as wide as needed,
up to the current window width minus table borders."
  :type 'integer :group 'isqlm)

(defcustom isqlm-table-style 'unicode
  "Table border line-drawing style for result display.
`ascii'   — classic MySQL style using +, -, |
`unicode' — box-drawing characters ┌┬┐├┼┤└┴┘│─
`none'    — no borders"
  :type '(choice (const :tag "ASCII (+, -, |)" ascii)
                 (const :tag "Unicode box-drawing" unicode)
                 (const :tag "No borders" none))
  :group 'isqlm)

(defcustom isqlm-max-rows 1000
  "Maximum rows to display.  0 = unlimited."
  :type 'integer :group 'isqlm)

(defcustom isqlm-null-string "NULL"
  "String for SQL NULL values." :type 'string :group 'isqlm)

(defcustom isqlm-mode-hook nil
  "Hook run when entering `isqlm-mode'."
  :type 'hook :group 'isqlm)

;; ============================================================
;; Faces
;; ============================================================

(defface isqlm-prompt-face
  '((default :weight bold)
    (((class color) (background light)) :foreground "DarkBlue")
    (((class color) (background dark))  :foreground "LightSkyBlue"))
  "Face for the ISQLM prompt." :group 'isqlm)

(defface isqlm-error-face
  '((default :weight bold)
    (((class color) (background light)) :foreground "Red")
    (((class color) (background dark))  :foreground "OrangeRed"))
  "Face for error messages." :group 'isqlm)

(defface isqlm-info-face
  '((default :slant italic)
    (((class color) (background light)) :foreground "DarkGreen")
    (((class color) (background dark))  :foreground "LightGreen"))
  "Face for info messages." :group 'isqlm)

(defface isqlm-table-header-face
  '((default :weight bold)
    (((class color) (background light)) :foreground "DarkCyan")
    (((class color) (background dark))  :foreground "Cyan"))
  "Face for table column headers." :group 'isqlm)

(defface isqlm-null-face
  '((default :slant italic)
    (((class color) (background light)) :foreground "Gray50")
    (((class color) (background dark))  :foreground "Gray60"))
  "Face for NULL values." :group 'isqlm)

;; ============================================================
;; Internal variables
;; ============================================================

(defvar-local isqlm-connection nil)
(defvar-local isqlm-connection-info nil)
(defvar-local isqlm-pending-input "")
(defvar-local isqlm-prompt-internal nil)
(defvar-local isqlm-last-query nil
  "The last SQL query executed, for use by \\gset.")
(defvar-local isqlm-last-result nil
  "The last SELECT query result as (COLUMNS . ROWS), for use by \\gset.")
(defvar-local isqlm-last-input-start nil)
(defvar-local isqlm-last-input-end nil)
(defvar-local isqlm-last-output-start nil)
(defvar-local isqlm-last-output-end nil)
(defvar-local isqlm-history-ring nil)
(defvar-local isqlm-history-index nil)
(defvar-local isqlm-input-saved nil)
(defvar-local isqlm-cond-stack nil
  "Stack for \\if/\\elif/\\else/\\endif conditional flow.
Each element is a plist (:satisfied BOOL :active BOOL :depth-skip INT).
:satisfied — whether any branch in this \\if chain has been true.
:active    — whether the current branch should execute.
:depth-skip — nested \\if depth to skip when inactive (0 when active).")

(defvar-local isqlm-for-stack nil
  "Stack for \\for loops.  Each element is a plist:
:var      — variable name (symbol)
:values   — list of remaining values to iterate
:body     — list of body lines collected so far (in reverse)
:brace    — whether we've seen the opening `{' yet")

(defvar-local isqlm-for-bindings nil
  "Alist of active \\for loop variable bindings: (SYMBOL . VALUE).
Loop variables are bound here instead of via `set' so that names
which are Emacs Lisp constants (`t', `nil') can be used, and so the
global namespace is not polluted.  Both `isqlm--expand-arg' and
`isqlm--expand-sql-variables' consult this alist before falling back
to `symbol-value'.  Inside SQL, loop variables always expand as raw
text (like `::var'), since loop values are substitution tokens
\(e.g. table names).")

(defvar-local isqlm--async-state nil
  "Non-nil when an asynchronous query is in progress.
Plist with keys:
  :phase    — \\='query or \\='store (which async step we are in)
  :sql      — the original SQL string
  :query    — the stripped query (no terminator)
  :mode     — terminator mode (nil, t for \\G, or (:gset PREFIX))
  :timer    — the polling timer
  :stmts    — remaining statements to execute (for multi-statement)
  :callback — function to call when all statements are done")

(defvar-local isqlm--async-busy nil
  "Non-nil when an async query is running.  Used to block new input.")

(defvar-local isqlm--suppress-summary nil
  "When non-nil, suppress row-count summary in result output.
Set temporarily by \\d-family commands.")

(defvar-local isqlm-timing nil
  "When non-nil, display execution time after each SQL statement.")

(defvar-local isqlm-delimiter ";"
  "Current statement delimiter.
Use \\delimiter to change it (e.g. \\delimiter // for stored procedures).
Reset to \";\" with \\delimiter ; or \\delimiter without arguments.")

(defun isqlm--format-timing (elapsed)
  "Format ELAPSED seconds into a human-readable timing string.
Returns e.g. \"Time: 42.531 ms\", \"Time: 1234.567 ms (1 s)\",
\"Time: 65432.100 ms (1 min 5 s)\"."
  (let ((ms (* elapsed 1000.0)))
    (if (< ms 1000.0)
        (format "Time: %.3f ms" ms)
      (format "Time: %.3f ms (%s)" ms
              (format-seconds "%dd %hh %mmin %ss%z" (round elapsed))))))

;; ============================================================
;; Font-lock
;; ============================================================

(defvar isqlm-font-lock-keywords
  (list
   (cons (concat "\\<"
                 (regexp-opt
                  '("SELECT" "FROM" "WHERE" "INSERT" "INTO" "VALUES"
                    "UPDATE" "SET" "DELETE" "CREATE" "DROP" "ALTER"
                    "TABLE" "DATABASE" "INDEX" "VIEW" "TRIGGER"
                    "AND" "OR" "NOT" "IN" "IS" "NULL" "LIKE"
                    "BETWEEN" "EXISTS" "HAVING" "GROUP" "BY"
                    "ORDER" "ASC" "DESC" "LIMIT" "OFFSET"
                    "JOIN" "LEFT" "RIGHT" "INNER" "OUTER" "CROSS"
                    "ON" "AS" "DISTINCT" "ALL" "UNION" "EXCEPT"
                    "INTERSECT" "CASE" "WHEN" "THEN" "ELSE" "END"
                    "IF" "BEGIN" "COMMIT" "ROLLBACK" "TRANSACTION"
                    "START" "PRIMARY" "KEY" "FOREIGN" "REFERENCES"
                    "SHOW" "DESCRIBE" "EXPLAIN" "USE"
                    "COUNT" "SUM" "AVG" "MAX" "MIN"
                    "GRANT" "REVOKE" "TRUNCATE" "RENAME" "REPLACE"
                    "TRUE" "FALSE")
                  t)
                 "\\>")
         'font-lock-keyword-face)
   '("'[^']*'" . font-lock-string-face)
   '("\\b[0-9]+\\(\\.[0-9]+\\)?\\b" . font-lock-constant-face)
   '("\\(--\\|#\\).*$" . font-lock-comment-face))
  "Font-lock keywords for ISQLM buffers.")

;; ============================================================
;; Keymap
;; ============================================================

(defvar-keymap isqlm-mode-map
  :doc "Keymap for ISQLM mode."
  "RET"     #'isqlm-send-input
  "M-RET"   #'newline
  "C-c C-c" #'isqlm-interrupt
  "C-c C-q" #'isqlm-disconnect
  "C-c C-r" #'isqlm-reconnect
  "C-c C-n" #'isqlm-connect
  "C-c C-l" #'isqlm-clear-buffer
  "C-c C-u" #'isqlm-show-databases
  "C-c C-t" #'isqlm-show-tables
  "C-c C-d" #'isqlm-describe-table
  "M-p"     #'isqlm-previous-input
  "M-n"     #'isqlm-next-input
  "M-r"     #'isqlm-history-search
  "C-a"     #'isqlm-bol)

(easy-menu-define isqlm-menu isqlm-mode-map
  "ISQLM mode menu."
  '("ISQLM"
    ["Connect"        isqlm-connect t]
    ["Disconnect"     isqlm-disconnect t]
    ["Reconnect"      isqlm-reconnect t]
    "---"
    ["Show Databases" isqlm-show-databases t]
    ["Show Tables"    isqlm-show-tables t]
    ["Describe Table" isqlm-describe-table t]
    "---"
    ["Clear Buffer"   isqlm-clear-buffer t]))

;; ============================================================
;; Module loading
;; ============================================================

(defun isqlm--ensure-module ()
  "Ensure the mysql-el dynamic module is loaded."
  (unless (fboundp 'mysql-available-p)
    (condition-case err
        (require 'mysql-el)
      (error
       (error "Cannot load mysql-el module: %s" (isqlm--error-message err)))))
  (unless (mysql-available-p)
    (error "mysql-el module loaded but mysql-available-p returned nil")))

;; ============================================================
;; Error message extraction
;; ============================================================

;; mysql-el signals `mysql-error' with structured data: (ERRNO SQLSTATE ERRMSG).
;; In a `condition-case' handler, ERR is (mysql-error ERRNO SQLSTATE ERRMSG).
;; For generic `error' signals, ERR is (error . "message") or (error FORMAT ARGS...).

(defun isqlm--mysql-error-p (err)
  "Return non-nil if ERR is a `mysql-error' signal."
  (eq (car err) 'mysql-error))

(defun isqlm--mysql-error-errno (err)
  "Extract the MySQL error code (integer) from a `mysql-error' ERR."
  (nth 1 err))

(defun isqlm--mysql-error-sqlstate (err)
  "Extract the SQLSTATE string from a `mysql-error' ERR."
  (nth 2 err))

(defun isqlm--mysql-error-errmsg (err)
  "Extract the error message string from a `mysql-error' ERR."
  (nth 3 err))

(defun isqlm--error-message (err)
  "Extract a human-readable error message from ERR.
For `mysql-error' signals, format as \"ERROR <errno> (<sqlstate>): <msg>\".
For generic `error' signals, extract the message string."
  (if (isqlm--mysql-error-p err)
      (format "ERROR %d (%s): %s"
              (isqlm--mysql-error-errno err)
              (isqlm--mysql-error-sqlstate err)
              (isqlm--mysql-error-errmsg err))
    (let ((data (cdr err)))
      (cond
       ((stringp data) data)
       ((and (consp data) (stringp (car data)))
        (apply #'format (car data) (cdr data)))
       (t (error-message-string err))))))

(defun isqlm--output-mysql-error (&optional err)
  "Output a MySQL error in mysql-client format.
If ERR is a `mysql-error' signal, format its structured data as
\"ERROR <errno> (<sqlstate>): <message>\".  If ERR is a generic
`error' signal, output as \"*** Error *** <message>\".
If ERR is nil, output \"*** Error *** Unknown error\"."
  (if err
      (isqlm--output-error
       (concat (isqlm--error-message err) "\n"))
    (isqlm--output-error "*** Error *** Unknown error\n")))

(defun isqlm--warning-count-string (&optional result-plist)
  "Return a string like \", 2 warnings\" if there are warnings, else \"\".
If RESULT-PLIST is given, extract :warning-count from it.
Otherwise, query the connection with `mysql-warning-count'."
  (let ((wc (if result-plist
                (or (plist-get result-plist :warning-count) 0)
              (if (and isqlm-connection
                       (condition-case nil (mysqlp isqlm-connection) (error nil))
                       (fboundp 'mysql-warning-count))
                  (condition-case nil
                      (mysql-warning-count isqlm-connection)
                    (error 0))
                0))))
    (if (and (integerp wc) (> wc 0))
        (format ", %d %s" wc (if (= wc 1) "warning" "warnings"))
      "")))

;; ============================================================
;; Connection helpers
;; ============================================================

(defun isqlm--connected-p ()
  "Return non-nil if this buffer has a live MySQL connection."
  (and isqlm-connection
       (condition-case nil (mysqlp isqlm-connection) (error nil))))

(defun isqlm--connection-lost-p (err)
  "Return non-nil if ERR indicates a lost MySQL connection.
Checks for common MySQL error messages indicating server disconnect."
  (let ((msg (downcase (isqlm--error-message err))))
    (or (string-match-p "lost connection" msg)
        (string-match-p "server has gone away" msg)
        (string-match-p "connection was killed" msg)
        (string-match-p "disconnected by the server" msg)
        (string-match-p "closed database" msg)
        (string-match-p "can't connect" msg)
        ;; Also detect when mysqlp fails (handle invalidated)
        (not (isqlm--connected-p)))))

(defun isqlm--try-auto-reconnect ()
  "Attempt to reconnect using the last connection parameters.
Returns non-nil if reconnection succeeded."
  (when (and isqlm-auto-reconnect isqlm-connection-info)
    (let* ((info isqlm-connection-info)
           (host     (plist-get info :host))
           (user     (plist-get info :user))
           (password (plist-get info :password))
           (database (plist-get info :database))
           (port     (plist-get info :port)))
      (isqlm--output-info "Lost connection. Trying to reconnect...\n")
      ;; Close old connection silently
      (condition-case nil
          (when isqlm-connection (mysql-close isqlm-connection))
        (error nil))
      (setq isqlm-connection nil)
      (condition-case err
          (progn
            (setq isqlm-connection
                  (mysql-open host user (or password "")
                              (if (string= database "") nil database) port))
            (setq isqlm-connection-info
                  (list :host host :port port :user user
                        :password password :database database))
            (setq mode-line-process
                  (list (format " [%s]" (isqlm--format-connection-info))))
            (force-mode-line-update)
            (isqlm--output-info
             (format "Reconnected to %s\nCurrent database: %s\n\n"
                     (isqlm--format-connection-info)
                     (if (string= database "") "(none)" database)))
            t)
        (error
         (isqlm--output-error
          (format "*** Reconnection failed *** %s\n" (isqlm--error-message err)))
         nil)))))

(defun isqlm--format-connection-info ()
  "Return a human-readable connection description string."
  (if isqlm-connection-info
      (format "%s@%s:%d/%s"
              (plist-get isqlm-connection-info :user)
              (plist-get isqlm-connection-info :host)
              (plist-get isqlm-connection-info :port)
              (let ((db (plist-get isqlm-connection-info :database)))
                (if (or (null db) (string= db "")) "(none)" db)))
    "(not connected)"))

;; ============================================================
;; Output (eshell-style: direct buffer insertion, no process)
;; ============================================================

(defun isqlm--output (string)
  "Insert STRING into the ISQLM buffer as output at `isqlm-last-output-end'."
  (when (and string (> (length string) 0))
    (let ((inhibit-read-only t))
      (goto-char isqlm-last-output-end)
      (set-marker isqlm-last-output-start (point))
      (insert-before-markers string)
      (add-text-properties isqlm-last-output-start isqlm-last-output-end
                           '(rear-nonsticky t field output
                             inhibit-line-move-field-capture t
                             read-only t))
      (goto-char isqlm-last-output-end))))

(defun isqlm--output-error (msg)
  "Output MSG as error text."
  (isqlm--output (propertize msg 'font-lock-face 'isqlm-error-face)))

(defun isqlm--output-info (msg)
  "Output MSG as info text."
  (isqlm--output (propertize msg 'font-lock-face 'isqlm-info-face)))

;; ============================================================
;; Prompt (eshell-style: direct insertion with text properties)
;; ============================================================

(defun isqlm--emit-prompt ()
  "Insert a new prompt at `isqlm-last-output-end'."
  (let ((prompt (if (string= isqlm-pending-input "")
                    isqlm-prompt-internal
                  isqlm-prompt-continue))
        (inhibit-read-only t))
    (goto-char isqlm-last-output-end)
    (let ((start (point)))
      (insert prompt)
      (add-text-properties
       start (point)
       (list 'read-only      isqlm-prompt-read-only
             'field           'prompt
             'front-sticky    '(read-only field font-lock-face)
             'rear-nonsticky  '(read-only field font-lock-face)
             'font-lock-face  'isqlm-prompt-face
             'inhibit-line-move-field-capture t))
      (set-marker isqlm-last-output-end (point))
      (goto-char (point-max)))))

;; ============================================================
;; History
;; ============================================================

(defun isqlm--history-init ()
  "Initialize history ring and load from file."
  (setq isqlm-history-ring (make-ring isqlm-history-size))
  (setq isqlm-history-index nil)
  (setq isqlm-input-saved nil)
  (when (and isqlm-history-file-name
             (file-readable-p isqlm-history-file-name))
    (let ((lines (with-temp-buffer
                   (insert-file-contents isqlm-history-file-name)
                   (split-string (buffer-string) "\n" t))))
      (dolist (line (nreverse lines))
        (ring-insert isqlm-history-ring line)))))

(defun isqlm--history-save ()
  "Save history ring to file."
  (when (and isqlm-history-file-name isqlm-history-ring
             (> (ring-length isqlm-history-ring) 0))
    (let ((ring isqlm-history-ring)
          (file isqlm-history-file-name))
      (with-temp-file file
        (let ((len (ring-length ring)))
          (dotimes (i len)
            (insert (ring-ref ring (- len 1 i)) "\n")))))))

(defun isqlm--add-to-history (input)
  "Add INPUT to history ring if non-empty and not duplicate of last."
  (let ((trimmed (string-trim input)))
    (when (and (> (length trimmed) 0)
               (or (ring-empty-p isqlm-history-ring)
                   (not (string= trimmed (ring-ref isqlm-history-ring 0)))))
      (ring-insert isqlm-history-ring trimmed))))

(defun isqlm--get-current-input ()
  "Return current input text (from prompt end to point-max)."
  (buffer-substring-no-properties isqlm-last-output-end (point-max)))

(defun isqlm--replace-current-input (text)
  "Replace current input with TEXT."
  (let ((inhibit-read-only t))
    (delete-region isqlm-last-output-end (point-max))
    (goto-char isqlm-last-output-end)
    (insert text)))

(defun isqlm-previous-input ()
  "Navigate to previous history entry."
  (interactive)
  (when (and isqlm-history-ring (not (ring-empty-p isqlm-history-ring)))
    (when (null isqlm-history-index)
      (setq isqlm-input-saved (isqlm--get-current-input))
      (setq isqlm-history-index -1))
    (let ((new-idx (1+ isqlm-history-index)))
      (when (< new-idx (ring-length isqlm-history-ring))
        (setq isqlm-history-index new-idx)
        (isqlm--replace-current-input
         (ring-ref isqlm-history-ring isqlm-history-index))))))

(defun isqlm-next-input ()
  "Navigate to next history entry, or restore saved input."
  (interactive)
  (when isqlm-history-index
    (let ((new-idx (1- isqlm-history-index)))
      (cond
       ((>= new-idx 0)
        (setq isqlm-history-index new-idx)
        (isqlm--replace-current-input
         (ring-ref isqlm-history-ring isqlm-history-index)))
       (t
        (setq isqlm-history-index nil)
        (isqlm--replace-current-input (or isqlm-input-saved "")))))))

(defvar-local isqlm--history-isearch-index nil
  "Current history index during isearch history navigation.")

(defvar-local isqlm--history-isearch-message-overlay nil
  "Overlay used to display isearch message over the prompt.")

(defvar-local isqlm--force-history-isearch nil
  "Non-nil when M-r forces isearch into history mode.")

(defun isqlm-history-search ()
  "Incrementally search backward through history commands (like Eshell M-r).
Uses Emacs isearch framework with custom search function that
traverses the history ring, displaying matches on the command line."
  (interactive)
  (unless (and isqlm-history-ring (not (ring-empty-p isqlm-history-ring)))
    (user-error "History is empty"))
  (setq isqlm--force-history-isearch t)
  (isearch-backward-regexp nil t))

(defun isqlm--history-isearch-setup ()
  "Set up isearch to search through history when in isqlm-mode.
Called from `isearch-mode-hook'."
  (when (and (derived-mode-p 'isqlm-mode)
             isqlm--force-history-isearch
             isqlm-history-ring
             (not (ring-empty-p isqlm-history-ring)))
    (setq isearch-message-prefix-add "history ")
    (setq-local isearch-search-fun-function #'isqlm--history-isearch-search
                isearch-message-function #'isqlm--history-isearch-message
                isearch-wrap-function #'isqlm--history-isearch-wrap
                isearch-push-state-function #'isqlm--history-isearch-push-state)
    (add-hook 'isearch-mode-end-hook #'isqlm--history-isearch-end nil t)))

(defun isqlm--history-isearch-end ()
  "Clean up after history isearch ends."
  (setq isqlm--force-history-isearch nil)
  (setq isqlm--history-isearch-index nil)
  (when (overlayp isqlm--history-isearch-message-overlay)
    (delete-overlay isqlm--history-isearch-message-overlay))
  (setq isqlm--history-isearch-message-overlay nil)
  (kill-local-variable 'isearch-search-fun-function)
  (kill-local-variable 'isearch-message-function)
  (kill-local-variable 'isearch-wrap-function)
  (kill-local-variable 'isearch-push-state-function)
  (remove-hook 'isearch-mode-end-hook #'isqlm--history-isearch-end t))

(defun isqlm--history-goto (pos)
  "Replace current input with history entry at POS.
POS is an index into `isqlm-history-ring', or nil to restore."
  (let ((inhibit-read-only t))
    (delete-region isqlm-last-output-end (point-max))
    (goto-char isqlm-last-output-end)
    (when pos
      (insert (ring-ref isqlm-history-ring pos))))
  (setq isqlm--history-isearch-index pos))

(defun isqlm--history-isearch-search ()
  "Return the search function for history isearch."
  (lambda (string bound noerror)
    (let ((search-fun (isearch-search-fun-default))
          found)
      (or
       ;; First: search within the current command line text
       (funcall search-fun string
                (if isearch-forward bound isqlm-last-output-end)
                noerror)
       ;; Second: traverse history ring
       (unless bound
         (condition-case nil
             (progn
               (while (not found)
                 (cond
                  (isearch-forward
                   (when (or (null isqlm--history-isearch-index)
                             (eq isqlm--history-isearch-index 0))
                     (error "End of history"))
                   (isqlm--history-goto
                    (1- isqlm--history-isearch-index))
                   (goto-char isqlm-last-output-end))
                  (t
                   (let ((next (if isqlm--history-isearch-index
                                   (1+ isqlm--history-isearch-index)
                                 0)))
                     (when (>= next (ring-length isqlm-history-ring))
                       (error "Beginning of history"))
                     (isqlm--history-goto next)
                     (goto-char (point-max)))))
                 (setq isearch-barrier (point)
                       isearch-opoint (point))
                 (setq found (funcall search-fun string
                                      (unless isearch-forward
                                        isqlm-last-output-end)
                                      noerror)))
               (point))
           (error nil)))))))

(defun isqlm--history-isearch-message (&optional c-q-hack ellipsis)
  "Display isearch message for history search."
  (if (not (and isearch-success (not isearch-error)))
      (isearch-message c-q-hack ellipsis)
    ;; Show search prompt over the isqlm prompt using an overlay
    (let ((msg (isearch-message-prefix ellipsis isearch-nonincremental)))
      (if (overlayp isqlm--history-isearch-message-overlay)
          (move-overlay isqlm--history-isearch-message-overlay
                        (save-excursion
                          (goto-char isqlm-last-output-end)
                          (line-beginning-position))
                        isqlm-last-output-end)
        (setq isqlm--history-isearch-message-overlay
              (make-overlay
               (save-excursion
                 (goto-char isqlm-last-output-end)
                 (line-beginning-position))
               isqlm-last-output-end))
        (overlay-put isqlm--history-isearch-message-overlay 'evaporate t))
      (overlay-put isqlm--history-isearch-message-overlay 'display msg)
      (if (and isqlm--history-isearch-index (not ellipsis))
          (message "History item: %d"
                   (- (ring-length isqlm-history-ring)
                      isqlm--history-isearch-index))
        (message "")))))

(defun isqlm--history-isearch-wrap ()
  "Wrap around when history isearch hits the boundary."
  (if isearch-forward
      (isqlm--history-goto (1- (ring-length isqlm-history-ring)))
    (isqlm--history-goto nil))
  (goto-char (if isearch-forward isqlm-last-output-end (point-max))))

(defun isqlm--history-isearch-push-state ()
  "Save current history index for isearch state stack."
  (let ((idx isqlm--history-isearch-index))
    (lambda (_cmd)
      (isqlm--history-goto idx))))


(defun isqlm-bol ()
  "Move to beginning of input line, skipping prompt."
  (interactive)
  (let ((input-start (marker-position isqlm-last-output-end)))
    (if (and (= (line-number-at-pos) (line-number-at-pos input-start))
             (> (point) input-start))
        (goto-char input-start)
      (beginning-of-line))))

;; ============================================================
;; SQL parsing
;; ============================================================

(defun isqlm--sql-complete-p (sql)
  "Return non-nil if SQL is a complete statement.
When `isqlm-delimiter' is \";\", complete if it ends with `;', `\\G',
or `\\gset [PREFIX]'.  With a custom delimiter, complete if it ends
with that delimiter."
  (let ((trimmed (string-trim-right sql)))
    (or (string= trimmed "")
        (if (string= isqlm-delimiter ";")
            (or (string-suffix-p ";" trimmed)
                (string-suffix-p "\\G" trimmed)
                (string-match-p "\\\\gset\\(?:\\s-+\\S-+\\)?\\s-*$" trimmed))
          (string-suffix-p isqlm-delimiter trimmed)))))

(defun isqlm--strip-terminator (sql)
  "Remove trailing terminator from SQL.
Return (BODY . MODE) where MODE is:
  nil       — normal (terminated by `;' or custom delimiter)
  t         — vertical display (terminated by `\\G')
  (:gset PREFIX) — store result as variables (terminated by `\\gset [PREFIX]')"
  (let ((trimmed (string-trim-right sql)))
    (cond
     ;; Custom delimiter — strip it, no \G or \gset support
     ((and (not (string= isqlm-delimiter ";"))
           (string-suffix-p isqlm-delimiter trimmed))
      (cons (string-trim-right
             (substring trimmed 0 (- (length trimmed) (length isqlm-delimiter))))
            nil))
     ((string-match "\\\\gset\\(?:\\s-+\\(\\S-+\\)\\)?\\s-*$" trimmed)
      (let* ((prefix (or (match-string 1 trimmed) ""))
             (body (string-trim-right (substring trimmed 0 (match-beginning 0)))))
        ;; Also strip trailing ; (supports "stmt;\gset prefix")
        (when (string-suffix-p ";" body)
          (setq body (string-trim-right (substring body 0 -1))))
        (cons body (list :gset prefix))))
     ((string-suffix-p "\\G" trimmed)
      (cons (string-trim-right (substring trimmed 0 -2)) t))
     ((string-suffix-p ";" trimmed)
      (cons (string-trim-right (substring trimmed 0 -1)) nil))
     (t (cons trimmed nil)))))

(defun isqlm--expand-sql-variables (sql)
  "Expand `:varname' references in SQL string to variable values.
Skips expansion inside single-quoted strings, double-quoted strings,
backtick identifiers, and comments.  Variable values are formatted as:
  string → single-quoted (with internal quotes escaped)
  number → literal
  nil    → NULL
  other  → single-quoted via `format'"
  (let ((len (length sql))
        (i 0)
        (result nil)
        (in-sq nil) (in-dq nil) (in-bt nil)
        (in-lc nil) (in-bc nil))
    (while (< i len)
      (let ((ch (aref sql i)))
        (cond
         ;; Line comment
         (in-lc
          (push ch result)
          (when (= ch ?\n) (setq in-lc nil)))
         ;; Block comment
         (in-bc
          (push ch result)
          (when (and (= ch ?*) (< (1+ i) len) (= (aref sql (1+ i)) ?/))
            (push ?/ result)
            (cl-incf i)
            (setq in-bc nil)))
         ;; Single quote
         (in-sq
          (push ch result)
          (when (= ch ?')
            (if (and (< (1+ i) len) (= (aref sql (1+ i)) ?'))
                (progn (push ?' result) (cl-incf i))
              (setq in-sq nil))))
         ;; Double quote
         (in-dq
          (push ch result)
          (when (= ch ?\") (setq in-dq nil)))
         ;; Backtick
         (in-bt
          (push ch result)
          (when (= ch ?`) (setq in-bt nil)))
         ;; Normal context
         (t
          (cond
           ((= ch ?') (setq in-sq t) (push ch result))
           ((= ch ?\") (setq in-dq t) (push ch result))
           ((= ch ?`) (setq in-bt t) (push ch result))
           ((and (= ch ?-) (< (1+ i) len) (= (aref sql (1+ i)) ?-))
            (setq in-lc t) (push ch result))
           ((= ch ?#) (setq in-lc t) (push ch result))
           ((and (= ch ?/) (< (1+ i) len) (= (aref sql (1+ i)) ?*))
            (setq in-bc t) (push ch result) (push ?* result) (cl-incf i))
           ;; ::varname — raw expansion (no quoting, for identifiers)
           ;; :varname  — value expansion (strings quoted)
           ((and (= ch ?:)
                 (< (1+ i) len)
                 (let ((nc (aref sql (1+ i))))
                   (or (and (>= nc ?a) (<= nc ?z))
                       (and (>= nc ?A) (<= nc ?Z))
                       (= nc ?_)
                       (= nc ?:))))  ; :: prefix
            (let* ((raw-p (and (< (1+ i) len) (= (aref sql (1+ i)) ?:)))
                   (start (if raw-p (+ i 2) (1+ i)))
                   (j start))
              (while (and (< j len)
                          (let ((c (aref sql j)))
                            (or (and (>= c ?a) (<= c ?z))
                                (and (>= c ?A) (<= c ?Z))
                                (and (>= c ?0) (<= c ?9))
                                (= c ?_) (= c ?-))))
                (cl-incf j))
              (let* ((name (substring sql start j))
                     (binding (assq (intern name) isqlm-for-bindings))
                     (loop-var-p (and binding t))
                     (sym (intern-soft name))
                     (val (cond
                           (binding (cdr binding))
                           ((and sym (boundp sym)) (symbol-value sym))
                           (t (user-error "Void variable in SQL: %s%s"
                                          (if raw-p "::" ":") name))))
                     (replacement
                      (if (or raw-p loop-var-p)
                          ;; Raw: no quoting (identifiers, or \for loop vars)
                          (cond
                           ((null val) "NULL")
                           ((stringp val) val)
                           (t (format "%s" val)))
                        ;; Value: strings get quoted
                        (cond
                         ((null val) "NULL")
                         ((integerp val) (number-to-string val))
                         ((floatp val) (format "%g" val))
                         ((stringp val)
                          (concat "'" (replace-regexp-in-string "'" "''" val) "'"))
                         (t (concat "'"
                                    (replace-regexp-in-string
                                     "'" "''" (format "%s" val))
                                    "'"))))))
                (dolist (c (append replacement nil))
                  (push c result))
                (setq i (1- j)))))
           (t (push ch result))))))
      (cl-incf i))
    (apply #'string (nreverse result))))

(defun isqlm--split-statements (sql)
  "Split SQL into a list of individual statements.
Each element is a complete statement including its terminator.
When `isqlm-delimiter' is \";\", handles `;', `\\G', and `\\gset'.
With a custom delimiter, splits only on that delimiter.
Handles quoted strings and comments to avoid splitting inside them."
  (if (not (string= isqlm-delimiter ";"))
      ;; Custom delimiter mode — simple substring scanning
      (isqlm--split-statements-custom sql isqlm-delimiter)
    ;; Standard ; mode — full parser
    (isqlm--split-statements-standard sql)))

(defun isqlm--split-statements-custom (sql delimiter)
  "Split SQL by custom DELIMITER, respecting quotes and comments.
Returns a list of statements; each includes its trailing delimiter."
  (let ((len (length sql))
        (dlen (length delimiter))
        (i 0)
        (start 0)
        (statements nil)
        (in-single-quote nil)
        (in-double-quote nil)
        (in-backtick nil)
        (in-line-comment nil)
        (in-block-comment nil))
    (while (< i len)
      (let ((ch (aref sql i)))
        (cond
         (in-line-comment
          (when (= ch ?\n) (setq in-line-comment nil)))
         (in-block-comment
          (when (and (= ch ?*) (< (1+ i) len) (= (aref sql (1+ i)) ?/))
            (setq in-block-comment nil)
            (cl-incf i)))
         (in-single-quote
          (when (= ch ?')
            (if (and (< (1+ i) len) (= (aref sql (1+ i)) ?'))
                (cl-incf i)
              (setq in-single-quote nil))))
         (in-double-quote
          (when (= ch ?\") (setq in-double-quote nil)))
         (in-backtick
          (when (= ch ?`) (setq in-backtick nil)))
         (t
          (cond
           ((= ch ?') (setq in-single-quote t))
           ((= ch ?\") (setq in-double-quote t))
           ((= ch ?`) (setq in-backtick t))
           ((and (= ch ?-) (< (1+ i) len) (= (aref sql (1+ i)) ?-))
            (setq in-line-comment t) (cl-incf i))
           ((= ch ?#) (setq in-line-comment t))
           ((and (= ch ?/) (< (1+ i) len) (= (aref sql (1+ i)) ?*))
            (setq in-block-comment t) (cl-incf i))
           ;; Check for custom delimiter match
           ((and (<= (+ i dlen) len)
                 (string= (substring sql i (+ i dlen)) delimiter))
            (let ((stmt (string-trim (substring sql start (+ i dlen)))))
              (when (> (length stmt) 0)
                (push stmt statements)))
            (setq i (+ i dlen -1))
            (setq start (+ i 1)))))))
      (cl-incf i))
    ;; Remainder
    (let ((rest (string-trim (substring sql start))))
      (when (> (length rest) 0)
        (push rest statements)))
    (nreverse statements)))

(defun isqlm--split-statements-standard (sql)
  "Split SQL by standard terminators (`;', `\\G', `\\gset').
Handles quoted strings and comments to avoid splitting inside them."
  (let ((len (length sql))
        (i 0)
        (start 0)
        (statements nil)
        (in-single-quote nil)
        (in-double-quote nil)
        (in-backtick nil)
        (in-line-comment nil)
        (in-block-comment nil))
    (while (< i len)
      (let ((ch (aref sql i)))
        (cond
         ;; Line comment ends at newline
         (in-line-comment
          (when (= ch ?\n)
            (setq in-line-comment nil)))
         ;; Block comment: check for */
         (in-block-comment
          (when (and (= ch ?*) (< (1+ i) len) (= (aref sql (1+ i)) ?/))
            (setq in-block-comment nil)
            (cl-incf i)))
         ;; Inside single quote
         (in-single-quote
          (when (= ch ?')
            (if (and (< (1+ i) len) (= (aref sql (1+ i)) ?'))
                (cl-incf i)  ; escaped quote ''
              (setq in-single-quote nil))))
         ;; Inside double quote
         (in-double-quote
          (when (= ch ?\")
            (setq in-double-quote nil)))
         ;; Inside backtick
         (in-backtick
          (when (= ch ?`)
            (setq in-backtick nil)))
         ;; Normal context
         (t
          (cond
           ((= ch ?') (setq in-single-quote t))
           ((= ch ?\") (setq in-double-quote t))
           ((= ch ?`) (setq in-backtick t))
           ;; -- line comment
           ((and (= ch ?-) (< (1+ i) len) (= (aref sql (1+ i)) ?-))
            (setq in-line-comment t) (cl-incf i))
           ;; # line comment
           ((= ch ?#)
            (setq in-line-comment t))
           ;; /* block comment
           ((and (= ch ?/) (< (1+ i) len) (= (aref sql (1+ i)) ?*))
            (setq in-block-comment t) (cl-incf i))
           ;; \gset [PREFIX] terminator — must check before \G
           ((and (= ch ?\\) (< (+ i 4) len)
                 (string-match-p "\\`\\\\gset\\(?:\\s-\\|$\\)"
                                 (substring sql i (min len (+ i 20)))))
            ;; Find end of \gset [prefix]: scan to end of line or string
            (let ((j (+ i 5)))  ; skip past "\gset"
              ;; Skip optional whitespace + prefix
              (while (and (< j len)
                          (not (memq (aref sql j) '(?\n ?\; ?\\))))
                (cl-incf j))
              (let ((stmt (string-trim (substring sql start j))))
                (when (> (length stmt) 0)
                  (push stmt statements)))
              (setq i (1- j))
              (setq start j)))
           ;; \G terminator (but NOT \gset)
           ((and (= ch ?\\) (< (1+ i) len)
                 (memq (aref sql (1+ i)) '(?G ?g))
                 (or (>= (+ i 2) len)
                     (not (memq (aref sql (+ i 2)) '(?s ?S)))))
            (let ((stmt (string-trim (substring sql start (+ i 2)))))
              (when (> (length stmt) 0)
                (push stmt statements)))
            (cl-incf i)
            (setq start (1+ i)))
           ;; ; terminator — but check if \gset follows
           ((= ch ?\;)
            ;; Look ahead: skip whitespace, check for \gset
            (let ((peek (1+ i)))
              (while (and (< peek len) (memq (aref sql peek) '(?\s ?\t)))
                (cl-incf peek))
              (if (and (< (+ peek 4) len)
                       (string-match-p "\\`\\\\gset\\(?:\\s-\\|$\\)"
                                       (substring sql peek (min len (+ peek 20)))))
                  ;; ;\gset [prefix] — consume through end of \gset
                  (let ((j (+ peek 5))) ; skip past \gset
                    (while (and (< j len)
                                (not (memq (aref sql j) '(?\n ?\;))))
                      (cl-incf j))
                    (let ((stmt (string-trim (substring sql start j))))
                      (when (> (length stmt) 0)
                        (push stmt statements)))
                    (setq i (1- j))
                    (setq start j))
                ;; Normal ; terminator
                (let ((stmt (string-trim (substring sql start (1+ i)))))
                  (when (> (length stmt) 0)
                    (push stmt statements)))
                (setq start (1+ i)))))))))
      (cl-incf i))
    ;; Remainder (no terminator)
    (let ((rest (string-trim (substring sql start))))
      (when (> (length rest) 0)
        (push rest statements)))
    (nreverse statements)))

;; ============================================================
;; Result formatting
;; ============================================================

(defun isqlm--display-width (str)
  "Return the display width of single-line STR.
For multi-line strings, return the width of the longest line.
Correctly handles CJK double-width characters."
  (if (string-match-p "\n" str)
      (apply #'max (mapcar #'string-width (split-string str "\n")))
    (string-width str)))

(defun isqlm--truncate-string (str max-width)
  "Truncate single-line STR to MAX-WIDTH display columns with `...' if needed."
  (if (<= (string-width str) max-width)
      str
    (let ((result "")
          (i 0)
          (target (- max-width 3)))
      (while (and (< i (length str))
                  (<= (string-width (concat result (substring str i (1+ i))))
                      target))
        (setq result (concat result (substring str i (1+ i))))
        (setq i (1+ i)))
      (concat result "..."))))

(defun isqlm--pad-string (str width)
  "Pad STR with spaces to reach WIDTH display columns.
If STR is already wider than WIDTH, return STR unchanged."
  (let ((sw (string-width str)))
    (if (>= sw width)
        str
      (concat str (make-string (- width sw) ?\s)))))

(defun isqlm--value-to-string (val)
  "Convert VAL to display string."
  (cond
   ((null val) isqlm-null-string)
   ((stringp val) val)
   ((integerp val) (number-to-string val))
   ((floatp val) (format "%g" val))
   (t (format "%S" val))))

(defconst isqlm--table-chars-ascii
  '(:top-left    "+" :top-mid    "+" :top-right    "+"
    :mid-left    "+" :mid-mid    "+" :mid-right    "+"
    :bot-left    "+" :bot-mid    "+" :bot-right    "+"
    :horizontal  "-" :vertical   "|")
  "ASCII table drawing characters.")

(defconst isqlm--table-chars-unicode
  '(:top-left    "┌" :top-mid    "┬" :top-right    "┐"
    :mid-left    "├" :mid-mid    "┼" :mid-right    "┤"
    :bot-left    "└" :bot-mid    "┴" :bot-right    "┘"
    :horizontal  "─" :vertical   "│")
  "Unicode box-drawing table characters.")

(defconst isqlm--table-chars-none
  '(:top-left    "" :top-mid    "" :top-right    ""
    :mid-left    "" :mid-mid    "" :mid-right    ""
    :bot-left    "" :bot-mid    "" :bot-right    ""
    :horizontal  "" :vertical   "")
  "No-border table characters.")

(defun isqlm--table-chars ()
  "Return the active table character set based on `isqlm-table-style'."
  (pcase isqlm-table-style
    ('unicode isqlm--table-chars-unicode)
    ('none    isqlm--table-chars-none)
    (_        isqlm--table-chars-ascii)))

(defun isqlm--make-separator (widths left mid right horiz)
  "Build a separator line: LEFT───MID───MID───RIGHT\\n.
Returns empty string when HORIZ is empty (none style)."
  (if (string= horiz "")
      ""
    (let ((h (aref horiz 0)))
      (concat left
              (mapconcat (lambda (w) (make-string (+ w 2) h))
                         widths mid)
              right "\n"))))

(defun isqlm--format-table (columns rows)
  "Format COLUMNS and ROWS as a textual table string.
Handles multi-line cell values (containing newlines) by splitting
each data row into multiple display lines."
  (let* ((ncols (length columns))
         (chars (isqlm--table-chars))
         (h  (plist-get chars :horizontal))
         (v  (plist-get chars :vertical))
         (str-rows (mapcar (lambda (row)
                             (mapcar #'isqlm--value-to-string row))
                           rows))
         (widths (make-list ncols 0)))
    ;; Compute column widths from headers
    (dotimes (i ncols)
      (setf (nth i widths)
            (max (nth i widths) (string-width (nth i columns)))))
    ;; Compute column widths from data (using display-width for multi-line)
    (dolist (row str-rows)
      (dotimes (i (min ncols (length row)))
        (setf (nth i widths)
              (max (nth i widths) (isqlm--display-width (nth i row))))))
    ;; Apply max-column-width limit (0 = no limit)
    (when (and isqlm-max-column-width (> isqlm-max-column-width 0))
      (dotimes (i ncols)
        (setf (nth i widths)
              (min isqlm-max-column-width (nth i widths)))))
    (let* ((top-sep (isqlm--make-separator
                     widths
                     (plist-get chars :top-left)
                     (plist-get chars :top-mid)
                     (plist-get chars :top-right) h))
           (mid-sep (isqlm--make-separator
                     widths
                     (plist-get chars :mid-left)
                     (plist-get chars :mid-mid)
                     (plist-get chars :mid-right) h))
           (bot-sep (isqlm--make-separator
                     widths
                     (plist-get chars :bot-left)
                     (plist-get chars :bot-mid)
                     (plist-get chars :bot-right) h))
           (header (concat v " "
                           (mapconcat
                            (lambda (pair)
                              (let ((name (car pair)) (w (cdr pair)))
                                (isqlm--pad-string
                                 (isqlm--truncate-string name w) w)))
                            (cl-mapcar #'cons columns widths)
                            (concat " " v " "))
                           " " v "\n"))
           (data-lines
            (mapconcat
             (lambda (row)
               (isqlm--format-table-row row widths ncols v))
             str-rows "")))
      (concat top-sep
              (propertize header 'font-lock-face 'isqlm-table-header-face)
              mid-sep data-lines bot-sep))))

(defun isqlm--format-table-row (row widths ncols vertical)
  "Format a single ROW into one or more display lines.
ROW is a list of string cell values.  WIDTHS is the list of column widths.
NCOLS is the number of columns.  VERTICAL is the vertical bar character.
Cells containing newlines are split across multiple display lines."
  (let* ((cells (append row (make-list (max 0 (- ncols (length row))) "")))
         (cell-lines (cl-mapcar
                      (lambda (val w)
                        (mapcar (lambda (line)
                                  (isqlm--truncate-string line w))
                                (split-string val "\n")))
                      cells widths))
         (nlines (apply #'max 1 (mapcar #'length cell-lines))))
    (mapconcat
     (lambda (line-idx)
       (concat vertical " "
               (mapconcat
                (lambda (pair)
                  (let* ((lines (car pair))
                         (w (cdr pair))
                         (line (or (nth line-idx lines) ""))
                         (truncated (isqlm--truncate-string line w)))
                    (isqlm--pad-string truncated w)))
                (cl-mapcar #'cons cell-lines widths)
                (concat " " vertical " "))
               " " vertical "\n"))
     (number-sequence 0 (1- nlines)) "")))

(defun isqlm--format-vertical (columns row)
  "Format a single ROW vertically with COLUMNS."
  (let ((max-col-len (apply #'max (mapcar #'length columns))))
    (mapconcat
     (lambda (pair)
       (format (format "%%%ds: %%s" max-col-len)
               (car pair) (isqlm--value-to-string (cdr pair))))
     (cl-mapcar #'cons columns row) "\n")))

;; ============================================================
;; SQL Execution
;; ============================================================

(defun isqlm--execute-sql (sql)
  "Execute SQL and return formatted output string.
Handles terminator parsing, USE side-effects, and result formatting.
Connection check and auto-reconnect are delegated to `isqlm-execute-string'."
  (setq isqlm-last-query sql)
  (let* ((parsed (isqlm--strip-terminator sql))
         (query (car parsed))
         (mode (cdr parsed))
         (upper (upcase (string-trim-left query))))
    (when (string= query "")
      (error "Empty query"))
    ;; USE: execute + update connection-info and mode-line
    (if (string-prefix-p "USE" upper)
        (progn
          (isqlm-execute-string query)
          (let ((db-name (string-trim
                          (replace-regexp-in-string "\\`USE\\s-+" "" query))))
            (setq db-name (replace-regexp-in-string "[`'\"]" "" db-name))
            (plist-put isqlm-connection-info :database db-name)
            (setq mode-line-process
                  (list (format " [%s]" (isqlm--format-connection-info))))
            (force-mode-line-update)
            (propertize (format "Database changed to: %s\n" db-name)
                        'font-lock-face 'isqlm-info-face)))
      ;; All other SQL
      (let ((result (isqlm-execute-string query)))
        (isqlm--format-result-string result mode)))))

(defun isqlm-execute-string (sql)
  "Execute SQL on the current ISQLM connection, return a result plist.

This is the public API for programmatic SQL execution.  It abstracts
the underlying database module so that callers do not depend on
`mysql-el' directly.

The query is sent asynchronously and polled with `sit-for', so Emacs
remains responsive even for slow queries.

The returned plist has one of the following shapes:

  SELECT: (:type select :columns (\"col\" ...)
           :rows ((val ...) ...) :warning-count N)
  DML:    (:type dml :affected-rows N :warning-count N)

Signals `mysql-error' (or `error') on failure.
Auto-reconnect is attempted if `isqlm-auto-reconnect' is non-nil."
  (unless (or (isqlm--connected-p) isqlm-connection-info)
    (error "Not connected.  Use `\\connect' or M-x isqlm-connect"))
  (when (and (not (isqlm--connected-p)) isqlm-connection-info)
    (unless (isqlm--try-auto-reconnect)
      (error "Not connected.  Use `\\connect' or M-x isqlm-connect")))
  (condition-case err
      (isqlm--query-with-poll sql)
    (error
     (if (and isqlm-auto-reconnect
              isqlm-connection-info
              (isqlm--connection-lost-p err))
         (if (isqlm--try-auto-reconnect)
             (isqlm--query-with-poll sql)
           (signal (car err) (cdr err)))
       (signal (car err) (cdr err))))))

(defun isqlm--query-with-poll (sql)
  "Execute SQL via async `mysql-query' and poll until complete.
Returns the result plist.  Uses `sit-for' so Emacs stays responsive."
  (let ((result (mysql-query isqlm-connection sql t)))
    (while (eq result 'not-ready)
      (sit-for 0.02)
      (setq result (mysql-query-poll isqlm-connection)))
    result))

;; ============================================================
;; Async SQL Execution (non-blocking, via mysql-query / mysql-query-poll)
;; ============================================================

(defun isqlm--async-execute-statements (statements buffer)
  "Execute STATEMENTS asynchronously one by one in BUFFER.
Each statement is expanded, executed via the async API, and the
result is output.  When all statements finish, emit a prompt."
  (if (null statements)
      ;; All done
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq isqlm--async-busy nil)
          (setq isqlm--suppress-summary nil)
          (isqlm--emit-prompt)))
    ;; Execute the next statement
    (let* ((stmt (car statements))
           (rest (cdr statements))
           (expanded (isqlm--expand-sql-variables stmt)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (isqlm--async-execute-one
           expanded buffer
           (lambda ()
             (isqlm--async-execute-statements rest buffer))))))))

(defun isqlm--async-run-statements (statements buffer callback)
  "Execute STATEMENTS asynchronously, then call CALLBACK.
Like `isqlm--async-execute-statements' but does not manage
`isqlm--async-busy' or emit a prompt.  Used by scripts, for-loops,
and other internal callers that chain multiple lines."
  (if (null statements)
      (when callback (funcall callback))
    (let* ((stmt (car statements))
           (rest (cdr statements))
           (expanded (isqlm--expand-sql-variables stmt)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (isqlm--async-execute-one
           expanded buffer
           (lambda ()
             (isqlm--async-run-statements rest buffer callback))))))))

(defun isqlm--async-execute-one (sql buffer callback)
  "Execute a single SQL statement asynchronously.
SQL is the expanded statement.  BUFFER is the isqlm buffer.
CALLBACK is called (with no args) when this statement completes."
  (with-current-buffer buffer
    (catch 'done
      ;; Guard: if connection is nil, try auto-reconnect first
      (unless isqlm-connection
        (if (and isqlm-auto-reconnect
                 isqlm-connection-info
                 (isqlm--try-auto-reconnect))
            nil  ; reconnected — fall through to execute
          (isqlm--output-error
           "Not connected.  Use `\\connect' or M-x isqlm-connect\n")
          (funcall callback)
          (throw 'done nil)))
      (let* ((parsed (isqlm--strip-terminator sql))
             (query (car parsed))
             (mode (cdr parsed))
             (upper (upcase (string-trim-left query))))
        (setq isqlm-last-query sql)
        (when (string= query "")
          (isqlm--output-error "*** Error *** Empty query\n")
          (funcall callback)
          (throw 'done nil))
        ;; Start async query via mysql-query (including USE)
        (let ((start-time (current-time)))
          (condition-case err
              (let ((result (mysql-query isqlm-connection query t)))
                (if (not (eq result 'not-ready))
                    ;; Completed immediately — process result
                    (progn
                      (isqlm--async-handle-result result sql query mode
                                                 upper start-time)
                      (funcall callback))
                  ;; Not ready — poll with timer
                  (setq isqlm--async-state
                        (list :phase 'query :sql sql :query query
                              :mode mode :upper upper
                              :start-time start-time :callback callback
                              :timer (run-with-timer
                                      0.02 0.02
                                      #'isqlm--poll-query buffer)))))
            (error
             ;; Connection lost? Try auto-reconnect + retry async
             (if (and isqlm-auto-reconnect
                      isqlm-connection-info
                      (isqlm--connection-lost-p err))
                 (if (isqlm--try-auto-reconnect)
                     ;; Retry the query asynchronously after reconnect
                     (let ((retry-start (current-time)))
                       (condition-case err2
                           (let ((result (mysql-query isqlm-connection query t)))
                             (if (not (eq result 'not-ready))
                                 (progn
                                   (isqlm--async-handle-result
                                    result sql query mode upper retry-start)
                                   (funcall callback))
                               (setq isqlm--async-state
                                     (list :phase 'query :sql sql :query query
                                           :mode mode :upper upper
                                           :start-time retry-start
                                           :callback callback
                                           :timer (run-with-timer
                                                   0.02 0.02
                                                   #'isqlm--poll-query buffer)))))
                         (error
                          (when isqlm-noisy (ding))
                          (isqlm--output-mysql-error err2)
                          (funcall callback)))
                   ;; Reconnect failed
                   (when isqlm-noisy (ding))
                   (isqlm--output-mysql-error err)
                   (funcall callback))
               ;; Not a connection-lost error
               (when isqlm-noisy (ding))
               (isqlm--output-mysql-error err)
               (funcall callback)))))))))
)

(defun isqlm--async-handle-result (result sql query mode upper
                                          start-time)
  "Handle a completed async RESULT for QUERY.
SQL is the original statement with terminator.  UPPER is the uppercased
query.  MODE is the terminator mode.  START-TIME is the query start time.
Handles USE side-effects; for other statements, formats and
outputs the result.  Outputs timing info when `isqlm-timing' is non-nil."
  (if (string-prefix-p "USE" upper)
      ;; USE: update connection-info + mode-line
      (let ((db-name (string-trim
                      (replace-regexp-in-string "\\`USE\\s-+" "" query))))
        (setq db-name (replace-regexp-in-string "[`'\"]" "" db-name))
        (plist-put isqlm-connection-info :database db-name)
        (setq mode-line-process
              (list (format " [%s]" (isqlm--format-connection-info))))
        (force-mode-line-update)
        (isqlm--output
         (propertize (format "Database changed to: %s\n" db-name)
                     'font-lock-face 'isqlm-info-face)))
    ;; Normal result
    (isqlm--format-and-output-result result sql mode))
  ;; Timing
  (when (and isqlm-timing start-time)
    (isqlm--output-info
     (concat (isqlm--format-timing
              (float-time (time-subtract (current-time) start-time)))
             "\n"))))

(defun isqlm--poll-query (buffer)
  "Timer callback: poll async query progress via mysql-query-poll."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when isqlm--async-state
        (condition-case err
            (let ((result (mysql-query-poll isqlm-connection)))
              (unless (eq result 'not-ready)
                ;; Query complete — cancel timer and process result
                (let ((timer (plist-get isqlm--async-state :timer))
                      (sql (plist-get isqlm--async-state :sql))
                      (query (plist-get isqlm--async-state :query))
                      (mode (plist-get isqlm--async-state :mode))
                      (upper (plist-get isqlm--async-state :upper))
                      (start-time (plist-get isqlm--async-state :start-time))
                      (callback (plist-get isqlm--async-state :callback)))
                  (when timer (cancel-timer timer))
                  (setq isqlm--async-state nil)
                  (isqlm--async-handle-result result sql query mode
                                              upper start-time)
                  (when callback (funcall callback)))))
          (error
           (let ((timer (plist-get isqlm--async-state :timer))
                 (callback (plist-get isqlm--async-state :callback)))
             (when timer (cancel-timer timer))
             (setq isqlm--async-state nil)
             (setq isqlm--async-busy nil)
             (when isqlm-noisy (ding))
             (isqlm--output-mysql-error err)
             (when callback (funcall callback)))))))))

(defun isqlm--format-result-string (result mode)
  "Format RESULT plist from `mysql-query' into a string.
MODE is the terminator mode from `isqlm--strip-terminator'.
Returns the formatted string, or \"\" for \\gset."
  (let* ((type (plist-get result :type))
         (gset-p (and (listp mode) (eq (car mode) :gset)))
         (gset-prefix (and gset-p (cadr mode)))
         (vertical (and (not gset-p) (eq mode t)))
         (ws (isqlm--warning-count-string result)))
    (pcase type
      ('select
       (let ((columns (plist-get result :columns))
             (rows (plist-get result :rows)))
         (setq isqlm-last-result
               (when columns (cons columns rows)))
         (if gset-p
             ;; \gset: store result as variables
             (cond
              ((null rows)
               (error "Query returned no results"))
              ((/= (length rows) 1)
               (error "\\gset requires exactly 1 row, got %d" (length rows)))
              (t
               (let ((row (car rows)))
                 (dotimes (i (length columns))
                   (set (intern (concat (or gset-prefix "") (nth i columns)))
                        (nth i row)))
                 "")))
           ;; Normal SELECT display
           (if (null rows)
               (propertize (format "Empty set (0 rows)%s\n" ws)
                           'font-lock-face 'isqlm-info-face)
             (let* ((nrows (length rows))
                    (truncated nil))
               (when (and (> isqlm-max-rows 0) (> nrows isqlm-max-rows))
                 (setq rows (seq-take rows isqlm-max-rows))
                 (setq truncated t))
               (concat
                (if vertical
                    (let ((n 0))
                      (mapconcat
                       (lambda (row)
                         (cl-incf n)
                         (concat (format "*************************** %d. row ***************************\n" n)
                                 (isqlm--format-vertical columns row) "\n"))
                       rows ""))
                  (isqlm--format-table columns rows))
                (unless isqlm--suppress-summary
                  (propertize
                   (if truncated
                       (format "%d rows in set%s (truncated from %d)\n" (length rows) ws nrows)
                     (format "%d %s in set%s\n" nrows (if (= nrows 1) "row" "rows") ws))
                   'font-lock-face 'isqlm-info-face))))))))
      ('dml
       (let ((affected (plist-get result :affected-rows)))
         (propertize
          (if (and (integerp affected) (>= affected 0))
              (format "Query OK, %d %s affected%s\n"
                      affected (if (= affected 1) "row" "rows") ws)
            (format "Query OK%s\n" ws))
          'font-lock-face 'isqlm-info-face)))
      (_ (error "Unknown result type")))))

(defun isqlm--format-and-output-result (result _sql mode)
  "Format RESULT plist from `mysql-query' and output to buffer.
_SQL is the original statement (unused), MODE is the terminator mode."
  (let ((str (condition-case err
                 (isqlm--format-result-string result mode)
               (error
                (isqlm--output-error
                 (format "*** Error *** %s\n" (isqlm--error-message err)))
                nil))))
    (when (and str (not (string= str "")))
      (isqlm--output str))))

(defun isqlm--async-cancel ()
  "Cancel any in-progress async query."
  (when isqlm--async-state
    (let ((timer (plist-get isqlm--async-state :timer)))
      (when timer (cancel-timer timer)))
    (setq isqlm--async-state nil))
  (setq isqlm--async-busy nil))

(defun isqlm/help (&rest _args)
  "Display available ISQLM commands."
  (isqlm--output-info
   (concat
    "General\n"
    "  \\gset [PREFIX]         execute query, store result as variables\n"
    "  \\use DATABASE          switch database\n"
    "  \\help                  show this help\n"
    "  \\quit / \\exit          kill ISQLM buffer\n"
    "\n"
    "Connection\n"
    "  \\connect [NAME | [HOST] [USER] [DB] [PORT]]\n"
    "                         connect to MySQL server\n"
    "  \\connections           list connections from sql-connection-alist\n"
    "  \\disconnect            disconnect from server\n"
    "  \\reconnect             reconnect with last parameters\n"
    "  \\password              toggle password prompting on connect\n"
    "  \\status                show connection status\n"
    "\n"
    "Input/Output\n"
    "  \\i FILE / \\include FILE\n"
    "                         execute commands from file\n"
    "  \\echo TEXT...          output text\n"
    "  \\clear                 clear buffer\n"
    "  \\history               show input history\n"
    "  \\linestyle [a|u|n]     set border style (ascii/unicode/none)\n"
    "  \\timing [on|off]       toggle query execution timing\n"
    "  \\delimiter DELIM       set statement delimiter (e.g. // $$)\n"
    "  DELIMITER DELIM        same, MySQL CLI compatible (no \\ prefix)\n"
    "\n"
    "Informational (psql-style)\n"
    "  \\d [TABLE]             list tables/views, or describe TABLE\n"
    "  \\d+ [TABLE]            same with extra detail (engine, size, CREATE TABLE)\n"
    "  \\dt [PATTERN]          list tables only\n"
    "  \\dv [PATTERN]          list views only\n"
    "  \\di [TABLE]            list indexes (all or for TABLE)\n"
    "  \\df[np][S][+] [PATTERN [ARG_PATTERN ...]]\n"
    "                         list functions/procedures\n"
    "                         n=normal(function) p=procedure S=system +=detail\n"
    "  \\ef [NAME[(types)]]    edit function/procedure definition\n"
    "  PATTERN: * matches any, ? matches one character\n"
    "\n"
    "Control Flow\n"
    "  \\if EXPR               begin conditional block\n"
    "  \\elif EXPR             alternative within conditional block\n"
    "  \\else                  final alternative within conditional block\n"
    "  \\endif                 end conditional block\n"
    "  \\for VAR in V1 V2 ... { body }\n"
    "                         loop over values\n"
    "\n"
    "TDSQL 3\n"
    "  \\placement TARGET           show table/partition node\n"
    "  \\placement TARGET NODE      split + migrate future writes to NODE\n"
    "                              TARGET: [db.]table[.partition]\n"
    "\n"
    "Variables & Elisp\n"
    "  \\setq VAR VALUE        set an Emacs variable\n"
    "  \\eval EXPR             evaluate Elisp expression\n"
    "  :varname               reference variable (quoted in SQL)\n"
    "  ::varname              reference variable (raw in SQL)\n"
    "  \\CMD ARGS...           call Emacs Lisp function CMD\n"
    "\n"
    "Aliases: \\? = \\h = \\help, \\q = \\quit, \\u = \\use, \\. = \\i\n"
    "\n"
    "SQL statements must end with a terminator:\n"
    "  ;              execute and display results\n"
    "  \\G             execute and display results vertically\n"
    "  \\gset [PREFIX] execute and store results as variables\n"
    "Press M-RET for a literal newline.  C-c C-c to abort input.\n")))

(defun isqlm--resolve-sql-connection (name)
  "Look up NAME in `sql-connection-alist'.
Return a plist (:host :user :password :database :port) or nil."
  (when (boundp 'sql-connection-alist)
    (let* ((entry (assoc-string name sql-connection-alist t))
           (params (cdr entry)))
      (when params
        (let ((host     (cadr (assq 'sql-server   params)))
              (user     (cadr (assq 'sql-user     params)))
              (password (cadr (assq 'sql-password params)))
              (database (cadr (assq 'sql-database params)))
              (port     (cadr (assq 'sql-port     params))))
          (list :host     (or host isqlm-default-host)
                :user     (or user isqlm-default-user)
                :password password
                :database (or database isqlm-default-database)
                :port     (or port isqlm-default-port)))))))

(defun isqlm/connections (&rest _args)
  "List available connections from `sql-connection-alist'."
  (if (or (not (boundp 'sql-connection-alist))
          (null sql-connection-alist))
      (isqlm--output-info "No connections defined in sql-connection-alist.\n")
    (let ((lines (list "Available connections (from sql-connection-alist):\n")))
      (dolist (entry sql-connection-alist)
        (let* ((name (car entry))
               (params (cdr entry))
               (host (or (cadr (assq 'sql-server params)) ""))
               (user (or (cadr (assq 'sql-user params)) ""))
               (db   (or (cadr (assq 'sql-database params)) ""))
               (port (or (cadr (assq 'sql-port params)) "")))
          (push (format "  %-20s %s@%s:%s/%s\n"
                        name user host port db)
                lines)))
      (isqlm--output-info (apply #'concat (nreverse lines))))))

(defun isqlm/connect (&rest args)
  "Connect to MySQL.

Usage:
  \\connect NAME              — connect using sql-connection-alist entry
  \\connect [HOST] [USER] [DB] [PORT] — connect with explicit parameters
                                 (all optional, defaults applied)
  \\connect                   — use all defaults

Password is never specified on the command line.
When `isqlm-prompt-password' is non-nil (default), password is prompted
via the echo area.  Set it to nil with:
  \\password                  — toggle password prompting"
  (isqlm--ensure-module)
  (when (isqlm--connected-p)
    (isqlm--output-info "Disconnecting current session...\n")
    (isqlm/disconnect))
  ;; Check if first arg matches a sql-connection-alist entry
  (let ((conn-info (and (= (length args) 1)
                        (isqlm--resolve-sql-connection (car args)))))
    (if conn-info
        ;; Connect from sql-connection-alist
        (let ((host     (plist-get conn-info :host))
              (user     (plist-get conn-info :user))
              (password (or (plist-get conn-info :password)
                            (if isqlm-prompt-password
                                (read-passwd "Password: ")
                              "")))
              (database (plist-get conn-info :database))
              (port     (plist-get conn-info :port))
              (conn-name (car args)))
          ;; Rename buffer to *isqlm: NAME*
          (let ((new-name (format "*isqlm: <%s>*" conn-name)))
            (unless (string= (buffer-name) new-name)
              (rename-buffer new-name t)))
          (isqlm--do-connect host user password database port))
      ;; Connect with explicit positional args; all optional, defaults applied
      (let* ((host     (or (nth 0 args) isqlm-default-host))
             (user     (or (nth 1 args) isqlm-default-user))
             (database (or (nth 2 args) isqlm-default-database))
             (port     (or (and (nth 3 args) (string-to-number (nth 3 args)))
                           isqlm-default-port))
             (password (if isqlm-prompt-password
                           (read-passwd "Password: ")
                         "")))
        (isqlm--do-connect host user password database port)))))

(defun isqlm--do-connect (host user password database port)
  "Perform the actual MySQL connection (async when available).
HOST, USER, PASSWORD, DATABASE, PORT are connection parameters."
  (condition-case err
      (let ((db-arg (if (string= database "") nil database)))
        (setq isqlm-connection
              (mysql-open host user password db-arg port t))
        (setq isqlm-connection-info
              (list :host host :port port :user user
                    :password password :database database))
        ;; Poll until connected
        (isqlm--output-info "Connecting...\n")
        (setq isqlm--async-state
              (list :phase 'connect
                    :timer (run-with-timer
                            0.02 0.02
                            #'isqlm--poll-connect (current-buffer)))))
    (error
     (isqlm--output-mysql-error err))))

(defun isqlm--poll-connect (buffer)
  "Timer callback: poll async connect progress."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (condition-case err
          (pcase (mysql-open-poll isqlm-connection)
            ('not-ready nil)
            ('complete
             (when (plist-get isqlm--async-state :timer)
               (cancel-timer (plist-get isqlm--async-state :timer)))
             (setq isqlm--async-state nil)
             (setq mode-line-process
                   (list (format " [%s]" (isqlm--format-connection-info))))
             (force-mode-line-update)
             (let ((ver (condition-case nil (mysql-version) (error "unknown"))))
               (isqlm--output-info
                (format "Connected to %s (MySQL client library: %s)\n"
                        (isqlm--format-connection-info) ver)))
             (setq isqlm-pending-input "")
             (isqlm--emit-prompt)))
        (error
         (when (and isqlm--async-state (plist-get isqlm--async-state :timer))
           (cancel-timer (plist-get isqlm--async-state :timer)))
         (setq isqlm--async-state nil)
         (isqlm--output-mysql-error err)
         (isqlm--emit-prompt))))))

(defun isqlm/password (&rest _args)
  "Toggle whether \\connect prompts for a password.
When enabled, \\connect will ask for password via echo area.
When disabled, empty password is used."
  (setq isqlm-prompt-password (not isqlm-prompt-password))
  (isqlm--output-info
   (format "Password prompting: %s\n"
           (if isqlm-prompt-password "ON" "OFF"))))

(defun isqlm/disconnect (&rest _args)
  "Disconnect from MySQL."
  (if (not isqlm-connection)
      (isqlm--output-info "Not connected.\n")
    (condition-case nil (mysql-close isqlm-connection) (error nil))
    (setq isqlm-connection nil)
    (setq isqlm-pending-input "")
    (setq mode-line-process '(" [disconnected]"))
    (force-mode-line-update)
    (isqlm--output-info "Disconnected.\n")))

(defun isqlm/reconnect (&rest _args)
  "Reconnect with last connection parameters."
  (if (not isqlm-connection-info)
      (isqlm--output-error "No previous connection info.  Use `\\connect' instead.\n")
    (let ((info isqlm-connection-info))
      (isqlm/disconnect)
      (isqlm--do-connect (plist-get info :host)
                         (plist-get info :user)
                         (or (plist-get info :password) "")
                         (plist-get info :database)
                         (plist-get info :port)))))

(defun isqlm/use (&rest args)
  "Switch to a different database.  ARGS: DATABASE-NAME."
  (let ((db (car args)))
    (cond
     ((not db)
      (isqlm--output-error "Usage: \\use DATABASE\n"))
     ((not (isqlm--connected-p))
      (isqlm--output-error "Not connected.\n"))
     (t
      (condition-case err
          (progn
            (mysql-execute isqlm-connection (format "USE `%s`" db))
            (plist-put isqlm-connection-info :database db)
            (setq mode-line-process
                  (list (format " [%s]" (isqlm--format-connection-info))))
            (force-mode-line-update)
            (isqlm--output-info (format "Database changed to: %s\n" db)))
        (error
         (isqlm--output-mysql-error err)))))))

(defun isqlm/status (&rest _args)
  "Show connection status and configuration."
  (isqlm--output-info
   (concat
    (if (isqlm--connected-p)
        (format "Connected: %s\n" (isqlm--format-connection-info))
      "Not connected.\n")
    (format "Auto-reconnect: %s\n" (if isqlm-auto-reconnect "on" "off"))
    (format "Line style: %s\n" isqlm-table-style)
    (format "Timing: %s\n" (if isqlm-timing "on" "off"))
    (format "Password prompt: %s\n" (if isqlm-prompt-password "on" "off")))))

(defun isqlm/linestyle (&rest args)
  "Set or cycle the table border line-drawing style.
ARGS: [ascii|unicode|none] (unique abbreviations allowed: a, u, n).
Without argument, cycle ascii → unicode → none → ascii."
  (let ((arg (car args)))
    (if (null arg)
        ;; Cycle: ascii → unicode → none → ascii
        (progn
          (setq isqlm-table-style
                (pcase isqlm-table-style
                  ('ascii 'unicode)
                  ('unicode 'none)
                  (_ 'ascii)))
          (isqlm--output-info
           (format "Line style: %s\n" isqlm-table-style)))
      (let ((s (downcase arg)))
        (cond
         ((string-prefix-p s "ascii")
          (setq isqlm-table-style 'ascii)
          (isqlm--output-info "Line style: ascii\n"))
         ((string-prefix-p s "unicode")
          (setq isqlm-table-style 'unicode)
          (isqlm--output-info "Line style: unicode\n"))
         ((string-prefix-p s "none")
          (setq isqlm-table-style 'none)
          (isqlm--output-info "Line style: none\n"))
         (t
          (isqlm--output-error
           "Usage: \\linestyle [ascii|unicode|none]\n")))))))

(defun isqlm/timing (&rest args)
  "Toggle or set timing display for SQL statements.
With argument `on' or `off', set explicitly.
Without argument, toggle."
  (let ((arg (car args)))
    (cond
     ((null arg)
      (setq isqlm-timing (not isqlm-timing))
      (isqlm--output-info
       (format "Timing is %s.\n" (if isqlm-timing "on" "off"))))
     ((member (downcase arg) '("on" "1" "yes" "true"))
      (setq isqlm-timing t)
      (isqlm--output-info "Timing is on.\n"))
     ((member (downcase arg) '("off" "0" "no" "false"))
      (setq isqlm-timing nil)
      (isqlm--output-info "Timing is off.\n"))
     (t
      (isqlm--output-error "Usage: \\timing [on|off]\n")))))

(defun isqlm/delimiter (&rest args)
  "Set or reset the statement delimiter.
\\delimiter DELIM sets the delimiter to DELIM (e.g. // or $$).
\\delimiter without argument resets to \";\".
This is needed for CREATE PROCEDURE/FUNCTION/TRIGGER statements
that contain `;' inside BEGIN...END blocks."
  (let ((new-delim (car args)))
    (if new-delim
        (progn
          (setq isqlm-delimiter new-delim)
          (isqlm--output-info
           (format "Delimiter set to: %s\n" isqlm-delimiter)))
      (setq isqlm-delimiter ";")
      (isqlm--output-info "Delimiter reset to: ;\n"))))

(defun isqlm/eval (&rest args)
  "Evaluate an Elisp expression.  ARGS are joined and read as a sexp.
Examples:
  \\eval (+ 1 2)
  \\eval (dotimes (i 3) (isqlm--quick-sql (format \"SELECT %d;\" (1+ i))))
  \\eval (format \"hello %s\" user-login-name)"
  (if (not args)
      (isqlm--output-error "Usage: \\eval EXPRESSION\n")
    (let ((expr-str (string-join args " ")))
      (condition-case err
          (let ((result (eval (read expr-str) t)))
            (when result
              (isqlm--output
               (concat (if (stringp result) result (pp-to-string result))
                       "\n"))))
        (error
         (isqlm--output-error
          (format "*** Eval Error *** %s\n" (isqlm--error-message err))))))))

(defun isqlm--execute-line (line &optional callback)
  "Execute LINE as if typed at the prompt.
Handles built-in commands, complete SQL, and multi-statement input.
When CALLBACK is non-nil, it is called after execution completes
\(used by script and for-loop execution to chain lines)."
  (let ((trimmed (string-trim line))
        (buf (current-buffer)))
    (if (= (length trimmed) 0)
        (when callback (funcall callback))
      (cond
       ;; Built-in command
       ((string-prefix-p "\\" trimmed)
        (isqlm--try-builtin-command trimmed)
        (when callback (funcall callback)))
       ;; Complete SQL — execute asynchronously
       ((isqlm--sql-complete-p trimmed)
        (let ((statements (isqlm--split-statements trimmed)))
          (isqlm--async-run-statements
           statements buf
           (or callback #'ignore))))
       ;; Incomplete SQL — warning
       (t
        (isqlm--output-error
         (format "Incomplete statement: %s\n" trimmed))
        (when callback (funcall callback)))))))

(defun isqlm--execute-script (text)
  "Execute TEXT as a script asynchronously.
Multi-line SQL is accumulated until a terminator is found.
Respects \\if/\\elif/\\else/\\endif conditional flow.
Each SQL statement is executed via the async pipeline."
  (let ((lines (split-string text "\n"))
        (buf (current-buffer)))
    (isqlm--script-process-lines lines "" buf)))

(defun isqlm--delimiter-directive-p (line)
  "Return the new delimiter if LINE is a DELIMITER directive, nil otherwise.
Recognizes `DELIMITER //' style directives (case-insensitive).
Without argument, returns \";\" to reset."
  (when (string-match "\\`[Dd][Ee][Ll][Ii][Mm][Ii][Tt][Ee][Rr]\\(?:\\s-+\\(\\S-+\\)\\)?\\s-*\\'"
                       line)
    (or (match-string 1 line) ";")))

(defun isqlm--script-process-lines (lines pending buf)
  "Process LINES from a script with PENDING accumulated input in BUF.
Async: when a SQL statement is found, execute it and continue
processing remaining lines in the callback.
Recognizes DELIMITER directives (MySQL CLI compatible)."
  (if (null lines)
      ;; End of script — check for unterminated input
      (when (> (length (string-trim pending)) 0)
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (when (isqlm--cond-active-p)
              (isqlm--output-error
               (format "Unterminated statement at end of script: %s\n"
                       (string-trim pending)))))))
    (let* ((line (car lines))
           (rest (cdr lines))
           (line-trimmed (string-trim line)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          ;; DELIMITER directive — must appear on its own line, no pending SQL
          (let ((new-delim (and (string= (string-trim pending) "")
                                (isqlm--delimiter-directive-p line-trimmed))))
            (if new-delim
                (progn
                  (setq isqlm-delimiter new-delim)
                  (isqlm--script-process-lines rest "" buf))
              ;; Normal processing
              (let* ((new-pending (concat pending
                                         (if (string= pending "") "" "\n")
                                         line))
                     (trimmed (string-trim new-pending)))
                (cond
                 ;; Built-in command on its own line (no multi-line pending)
                 ((and (not (string-match-p "\n" new-pending))
                       (string-prefix-p "\\" trimmed))
                  (cond
                   ;; Conditional flow commands — always process, then continue
                   ((isqlm--cond-flow-command-p trimmed)
                    (isqlm--process-cond-flow trimmed)
                    (isqlm--script-process-lines rest "" buf))
                   ;; Other commands — only when active (async via callback)
                   ((isqlm--cond-active-p)
                    (isqlm--execute-line
                     new-pending
                     (lambda ()
                       (isqlm--script-process-lines rest "" buf))))
                   ;; Inactive — skip command, continue
                   (t
                    (isqlm--script-process-lines rest "" buf))))
                 ;; Complete SQL — execute only when active
                 ((isqlm--sql-complete-p new-pending)
                  (if (isqlm--cond-active-p)
                      (let ((statements (isqlm--split-statements new-pending)))
                        (isqlm--async-run-statements
                         statements buf
                         (lambda ()
                           (isqlm--script-process-lines rest "" buf))))
                    (isqlm--script-process-lines rest "" buf)))
                 ;; Incomplete — accumulate and continue
                 (t
                  (isqlm--script-process-lines rest new-pending buf)))))))))))


;; Minor mode for \i - editing buffer
(defvar-local isqlm--script-target nil
  "The ISQLM buffer to send the script to when finished editing.")

(defvar isqlm-script-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'isqlm-script-finish)
    (define-key map (kbd "C-c C-k") #'isqlm-script-abort)
    map)
  "Keymap for `isqlm-script-mode'.")

(define-minor-mode isqlm-script-mode
  "Minor mode for editing an ISQLM script.
\\<isqlm-script-mode-map>
\\[isqlm-script-finish] to execute the script.
\\[isqlm-script-abort] to abort."
  :lighter " ISQLM-Script"
  :keymap isqlm-script-mode-map)

(defun isqlm-script-finish ()
  "Execute the script in this buffer and close it."
  (interactive)
  (let ((text (buffer-substring-no-properties (point-min) (point-max)))
        (target isqlm--script-target)
        (buf (current-buffer)))
    (quit-window)
    (kill-buffer buf)
    (when (and target (buffer-live-p target))
      (with-current-buffer target
        (isqlm--execute-script text)
        (isqlm--emit-prompt)))))

(defun isqlm-script-abort ()
  "Abort the script editing."
  (interactive)
  (let ((buf (current-buffer)))
    (quit-window)
    (kill-buffer buf)
    (message "Script aborted.")))

(defun isqlm/i (&rest args)
  "Read and execute SQL from a file (à la psql \\i / \\include).
ARGS: FILENAME.
If FILENAME is `-', open a temporary buffer for script editing.
Press C-c C-c to execute, C-c C-k to abort."
  (let ((filename (car args)))
    (cond
     ((not filename)
      (isqlm--output-error "Usage: \\i FILENAME  (use - for interactive script)\n"))
     ;; Interactive mode: open editing buffer
     ((string= filename "-")
      (let ((target (current-buffer))
            (buf (generate-new-buffer "*isqlm-script*")))
        (pop-to-buffer buf)
        (sql-mode)
        (isqlm-script-mode 1)
        (setq isqlm--script-target target)
        (setq header-line-format
              "Edit SQL script.  C-c C-c to execute, C-c C-k to abort.")
        (message "Edit script, then C-c C-c to execute or C-c C-k to abort.")))
     ;; File mode
     (t
      (let ((path (expand-file-name filename)))
        (if (not (file-readable-p path))
            (isqlm--output-error (format "Cannot read file: %s\n" path))
          (isqlm--execute-script
           (with-temp-buffer
             (insert-file-contents path)
             (buffer-string)))))))))

(defalias 'isqlm/include #'isqlm/i
  "Alias for `isqlm/i'.  Read and execute SQL from a file.")

(defun isqlm/clear (&rest _args)
  "Clear the ISQLM buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq isqlm-last-input-start (point-min-marker))
    (setq isqlm-last-input-end (point-min-marker))
    (setq isqlm-last-output-start (point-min-marker))
    (setq isqlm-last-output-end (point-min-marker))))

(defun isqlm/history (&rest _args)
  "Show input history."
  (if (or (null isqlm-history-ring) (ring-empty-p isqlm-history-ring))
      (isqlm--output-info "History is empty.\n")
    (let ((len (ring-length isqlm-history-ring))
          (lines nil))
      (dotimes (i len)
        (push (format "  %3d  %s\n" (1+ i)
                      (ring-ref isqlm-history-ring (- len 1 i)))
              lines))
      (isqlm--output (apply #'concat (nreverse lines))))))

;; ============================================================
;; \l / \list — list databases (psql-inspired)
;; ============================================================

(defun isqlm--l-parse-modifiers (raw-cmd)
  "Parse RAW-CMD (e.g. \"l\", \"l+\", \"lx\", \"lx+\", \"list\", \"listx+\") into modifiers.
Returns a plist (:expanded BOOL :verbose BOOL)."
  (let* ((suffix (cond
                  ((string-prefix-p "list" raw-cmd) (substring raw-cmd 4))
                  ((string-prefix-p "l" raw-cmd) (substring raw-cmd 1))
                  (t "")))
         (expanded nil)
         (verbose nil))
    (dolist (ch (string-to-list suffix))
      (pcase ch
        (?x (setq expanded t))
        (?+ (setq verbose t))))
    (list :expanded expanded :verbose verbose)))

(defun isqlm--l-dispatch (raw-cmd args)
  "Dispatch a \\l-family command.
RAW-CMD is the command name without \\, ARGS is the argument list."
  (if (not (isqlm--connected-p))
      (isqlm--output-error "Not connected.\n")
    (setq isqlm--suppress-summary t)
    (let* ((mods (isqlm--l-parse-modifiers raw-cmd))
           (expanded (plist-get mods :expanded))
           (verbose (plist-get mods :verbose))
           (pattern (car args))
           ;; Build WHERE clause for pattern filtering
           (where (if pattern
                      (format " WHERE SCHEMA_NAME LIKE '%s'"
                              (replace-regexp-in-string
                               "\\*" "%" (replace-regexp-in-string
                                          "?" "_" pattern)))
                    ""))
           ;; Build SQL
           (sql (if verbose
                    ;; \l+ — include sizes, default tablespace (N/A in MySQL), description
                    (concat
                     "SELECT s.SCHEMA_NAME AS `Name`,"
                     " IFNULL(s.DEFAULT_CHARACTER_SET_NAME, '') AS `Encoding`,"
                     " IFNULL(s.DEFAULT_COLLATION_NAME, '') AS `Collation`,"
                     " IFNULL((SELECT CONCAT(ROUND(SUM(DATA_LENGTH + INDEX_LENGTH)"
                     " / 1024 / 1024, 2), ' MB')"
                     " FROM INFORMATION_SCHEMA.TABLES t"
                     " WHERE t.TABLE_SCHEMA = s.SCHEMA_NAME), '') AS `Size`,"
                     " '' AS `Tablespace`,"
                     " IFNULL((SELECT DISTINCT GRANTEE"
                     " FROM INFORMATION_SCHEMA.SCHEMA_PRIVILEGES sp"
                     " WHERE sp.TABLE_SCHEMA = s.SCHEMA_NAME"
                     " LIMIT 1), '') AS `Access privileges`"
                     " FROM INFORMATION_SCHEMA.SCHEMATA s"
                     where
                     " ORDER BY s.SCHEMA_NAME")
                  ;; \l — basic: name, owner (definer), encoding, access privileges
                  (concat
                   "SELECT s.SCHEMA_NAME AS `Name`,"
                   " IFNULL(s.DEFAULT_CHARACTER_SET_NAME, '') AS `Encoding`,"
                   " IFNULL(s.DEFAULT_COLLATION_NAME, '') AS `Collation`,"
                   " IFNULL((SELECT DISTINCT GRANTEE"
                   " FROM INFORMATION_SCHEMA.SCHEMA_PRIVILEGES sp"
                   " WHERE sp.TABLE_SCHEMA = s.SCHEMA_NAME"
                   " LIMIT 1), '') AS `Access privileges`"
                   " FROM INFORMATION_SCHEMA.SCHEMATA s"
                   where
                   " ORDER BY s.SCHEMA_NAME"))))
      ;; Execute with expanded (vertical) mode if x modifier
      (if expanded
          ;; Use vertical display by appending \G
          (isqlm--quick-sql (concat sql "\\G") t)
        (isqlm--quick-sql (concat sql ";") t)))))

;; Define the isqlm/ entry points for \l commands
(defun isqlm/l (&rest args)
  "List databases (psql-style).
\\l[x][+] [PATTERN]
  x = expanded display (vertical)
  + = extra detail (size, tablespace)
  PATTERN filters by name (* = %, ? = _)."
  (isqlm--l-dispatch "l" args))

(defun isqlm/lx (&rest args)
  "List databases in expanded mode."
  (isqlm--l-dispatch "lx" args))

(defun isqlm/l+ (&rest args)
  "List databases with extra detail (size, tablespace)."
  (isqlm--l-dispatch "l+" args))

(defun isqlm/lx+ (&rest args)
  "List databases in expanded mode with extra detail."
  (isqlm--l-dispatch "lx+" args))

(defun isqlm/list (&rest args)
  "List databases (psql-style).  Same as \\l."
  (isqlm--l-dispatch "list" args))

(defun isqlm/listx (&rest args)
  "List databases in expanded mode.  Same as \\lx."
  (isqlm--l-dispatch "listx" args))

(defun isqlm/list+ (&rest args)
  "List databases with extra detail.  Same as \\l+."
  (isqlm--l-dispatch "list+" args))

(defun isqlm/listx+ (&rest args)
  "List databases in expanded mode with extra detail.  Same as \\lx+."
  (isqlm--l-dispatch "listx+" args))

;; ============================================================
;; \d family — describe database objects (psql-inspired)
;; ============================================================

(defun isqlm--d-list-tables (pattern type-filter verbose)
  "List tables/views matching PATTERN.
TYPE-FILTER is nil (all), \"BASE TABLE\", or \"VIEW\".
VERBOSE non-nil adds engine, rows, size, comment (via TABLE STATUS)."
  (if (not (isqlm--connected-p))
      (isqlm--output-error "Not connected.\n")
    (if verbose
      ;; \dt+, \dv+, \d+ (list mode) — use information_schema.tables
      (let* ((where-parts
              (append
               (when type-filter
                 (list (format "TABLE_TYPE = '%s'" type-filter)))
               (when pattern
                 (list (format "TABLE_NAME LIKE '%s'"
                               (replace-regexp-in-string
                                "\\*" "%" (replace-regexp-in-string
                                           "?" "_" pattern)))))))
             (where (if where-parts
                        (concat " WHERE TABLE_SCHEMA = DATABASE() AND "
                                (mapconcat #'identity where-parts " AND "))
                      " WHERE TABLE_SCHEMA = DATABASE()"))
             (sql (concat
                   "SELECT TABLE_NAME AS `Name`,"
                   " CASE"
                   "   WHEN TABLE_TYPE = 'VIEW' THEN 'VIEW'"
                   "   WHEN CREATE_OPTIONS LIKE '%partitioned%'"
                   "     THEN 'PARTITION TABLE'"
                   "   ELSE 'TABLE'"
                   " END AS `Type`,"
                   " IFNULL(ENGINE, '') AS `Engine`,"
                   " IFNULL(TABLE_ROWS, '') AS `Rows`,"
                   " IFNULL(CONCAT(ROUND((DATA_LENGTH + INDEX_LENGTH)"
                   " / 1024 / 1024, 2), ' MB'), '') AS `Size`,"
                   " IFNULL(TABLE_COMMENT, '') AS `Comment`"
                   " FROM INFORMATION_SCHEMA.TABLES"
                   where
                   " ORDER BY TABLE_NAME")))
        (isqlm--quick-sql (concat sql ";") t))
    ;; Non-verbose: list Name + Type (detecting partitioned tables)
    (let* ((where-parts
            (append
             (when type-filter
               (list (format "TABLE_TYPE = '%s'" type-filter)))
             (when pattern
               (list (format "TABLE_NAME LIKE '%s'"
                             (replace-regexp-in-string
                              "\\*" "%" (replace-regexp-in-string
                                         "?" "_" pattern)))))))
           (where (if where-parts
                      (concat " AND "
                              (mapconcat #'identity where-parts " AND "))
                    ""))
           (sql (concat
                 "SELECT TABLE_NAME AS `Name`,"
                 " CASE"
                 "   WHEN TABLE_TYPE = 'VIEW' THEN 'VIEW'"
                 "   WHEN CREATE_OPTIONS LIKE '%partitioned%'"
                 "     THEN 'PARTITION TABLE'"
                 "   ELSE 'TABLE'"
                 " END AS `Type`"
                 " FROM INFORMATION_SCHEMA.TABLES"
                 " WHERE TABLE_SCHEMA = DATABASE()" where
                 " ORDER BY TABLE_NAME;")))
      (isqlm--quick-sql sql t)))))

(defun isqlm--d-format-partition-info (result)
  "Format partition information from RESULT into a psql-style string.
RESULT is a plist from querying INFORMATION_SCHEMA.PARTITIONS.
Returns a formatted string or nil if no partitions."
  (when (and result
             (eq (plist-get result :type) 'select)
             (plist-get result :rows))
    (let* ((rows (plist-get result :rows))
           ;; columns: PARTITION_METHOD, PARTITION_EXPRESSION,
           ;;          SUBPARTITION_METHOD, SUBPARTITION_EXPRESSION,
           ;;          PARTITION_NAME, PARTITION_DESCRIPTION,
           ;;          PARTITION_ORDINAL_POSITION
           (first-row (car rows))
           (method (nth 0 first-row))
           (expr (nth 1 first-row))
           (sub-method (nth 2 first-row))
           (sub-expr (nth 3 first-row)))
      (when method
        (let ((lines (list (format "Partition key: %s (%s)" method expr)))
              (parts nil))
          ;; Collect partition entries
          (dolist (row rows)
            (let ((pname (nth 4 row))
                  (pdesc (nth 5 row)))
              (when pname
                (push
                 (if pdesc
                     (format "%s VALUES %s"
                             pname
                             (cond
                              ((string-match-p "\\`RANGE" method)
                               (if (string= pdesc "MAXVALUE")
                                   "LESS THAN MAXVALUE"
                                 (format "LESS THAN (%s)" pdesc)))
                              ((string-match-p "\\`LIST" method)
                               (format "IN (%s)" pdesc))
                              (t pdesc)))
                   pname)
                 parts))))
          (setq parts (nreverse parts))
          (when sub-method
            (push (format "Subpartition key: %s (%s)" sub-method sub-expr)
                  lines))
          (when parts
            (let ((indent (make-string (length "Partitions: ") ?\s)))
              (push (concat "Partitions: "
                            (car parts)
                            (mapconcat (lambda (p) (concat ",\n" indent p))
                                       (cdr parts) ""))
                    lines)))
          (mapconcat #'identity (nreverse lines) "\n"))))))

(defun isqlm--d-describe-table (table verbose)
  "Describe TABLE in psql style.
When VERBOSE is nil, show: Column, Type, Null, Key, Default, Extra.
When VERBOSE is non-nil, additionally show Collation and Comment columns,
plus footer with Engine, Charset, and Indexes information."
  (if (not (isqlm--connected-p))
      (isqlm--output-error "Not connected.\n")
    (let* ((q-table (replace-regexp-in-string "`" "``" table))
           (q-name (replace-regexp-in-string "'" "''" table)))
      (setq isqlm--async-busy t)
      (condition-case err
          (let* ((col-result (isqlm-execute-string
                              (format "SHOW FULL COLUMNS FROM `%s`" q-table)))
                 (all-cols (plist-get col-result :columns))
                 (all-rows (plist-get col-result :rows))
                 ;; Select columns based on verbose mode
                 (want (if verbose
                           '("Field" "Type" "Collation" "Null" "Key"
                             "Default" "Extra" "Comment")
                         '("Field" "Type" "Null" "Key" "Default" "Extra")))
                 (indices (mapcar
                           (lambda (name)
                             (cl-position name all-cols :test #'string=))
                           want))
                 (columns (cl-remove nil
                            (cl-mapcar (lambda (name idx)
                                         (when idx name))
                                       want indices)))
                 (valid-indices (cl-remove nil indices))
                 (rows (mapcar
                         (lambda (row)
                           (mapcar (lambda (idx) (nth idx row))
                                   valid-indices))
                         all-rows))
                 (table-str (isqlm--format-table columns rows)))
            ;; Header
            (isqlm--output-info (format "-- Table: %s\n" table))
            ;; Column table
            (isqlm--output table-str)
            ;; Footer info for verbose mode
            (when verbose
              ;; Indexes
              (let ((idx-result
                     (ignore-errors
                       (isqlm-execute-string
                        (format "SHOW INDEX FROM `%s`" q-table)))))
                (when (and idx-result
                           (plist-get idx-result :rows))
                  (let* ((idx-cols (plist-get idx-result :columns))
                         (idx-rows (plist-get idx-result :rows))
                         (name-pos (cl-position "Key_name" idx-cols
                                                :test #'string=))
                         (col-pos (cl-position "Column_name" idx-cols
                                               :test #'string=))
                         (uniq-pos (cl-position "Non_unique" idx-cols
                                                :test #'string=))
                         (type-pos (cl-position "Index_type" idx-cols
                                                :test #'string=))
                         ;; Group columns by index name
                         (index-map nil))
                    (when (and name-pos col-pos)
                      (dolist (row idx-rows)
                        (let* ((iname (nth name-pos row))
                               (icol (nth col-pos row))
                               (existing (assoc iname index-map)))
                          (if existing
                              (setcdr existing
                                      (append (cdr existing) (list icol)))
                            (push (list iname icol) index-map))))
                      (setq index-map (nreverse index-map))
                      (isqlm--output-info "Indexes:\n")
                      (dolist (entry index-map)
                        (let* ((iname (car entry))
                               (icols (cdr entry))
                               (sample-row (cl-find iname idx-rows
                                                    :key (lambda (r)
                                                           (nth name-pos r))
                                                    :test #'string=))
                               (unique (and uniq-pos
                                            (equal (nth uniq-pos sample-row)
                                                   "0")))
                               (itype (and type-pos
                                           (nth type-pos sample-row)))
                               (desc (format "    \"%s\" %s%s (%s)\n"
                                             iname
                                             (or itype "")
                                             (if unique " UNIQUE" "")
                                             (mapconcat #'identity icols
                                                        ", "))))
                          (isqlm--output-info desc)))))))
              ;; Table status (Engine, Charset)
              (let ((status-result
                     (ignore-errors
                       (isqlm-execute-string
                        (format "SHOW TABLE STATUS LIKE '%s'" q-name)))))
                (when (and status-result (plist-get status-result :rows))
                  (let* ((st-cols (plist-get status-result :columns))
                         (st-row (car (plist-get status-result :rows)))
                         (engine-pos (cl-position "Engine" st-cols
                                                  :test #'string=))
                         (coll-pos (cl-position "Collation" st-cols
                                                :test #'string=))
                         (rows-pos (cl-position "Rows" st-cols
                                                :test #'string=))
                         (engine (and engine-pos (nth engine-pos st-row)))
                         (collation (and coll-pos (nth coll-pos st-row)))
                         (nrows (and rows-pos (nth rows-pos st-row))))
                    (isqlm--output-info
                     (format "Engine: %s" (or engine "?")))
                    (when collation
                      (isqlm--output-info
                       (format ", Collation: %s" collation)))
                    (when nrows
                      (isqlm--output-info
                       (format ", Rows: ~%s" nrows)))
                    (isqlm--output-info "\n"))))
              ;; Partition info
              (let* ((part-result
                      (ignore-errors
                        (isqlm-execute-string
                         (format
                          (concat
                           "SELECT PARTITION_METHOD, PARTITION_EXPRESSION,"
                           " SUBPARTITION_METHOD, SUBPARTITION_EXPRESSION,"
                           " PARTITION_NAME, PARTITION_DESCRIPTION,"
                           " PARTITION_ORDINAL_POSITION"
                           " FROM INFORMATION_SCHEMA.PARTITIONS"
                           " WHERE TABLE_SCHEMA = DATABASE()"
                           " AND TABLE_NAME = '%s'"
                           " AND PARTITION_NAME IS NOT NULL"
                           " ORDER BY PARTITION_ORDINAL_POSITION")
                          q-name))))
                     (info (isqlm--d-format-partition-info part-result)))
                (when info
                  (isqlm--output-info (concat info "\n")))))
            ;; Summary
            (isqlm--output-info
             (format "%d columns\n" (length all-rows)))
            (setq isqlm--async-busy nil)
            (setq isqlm--suppress-summary nil)
            (isqlm--emit-prompt))
        (error
         (setq isqlm--async-busy nil)
         (setq isqlm--suppress-summary nil)
         (isqlm--output-mysql-error err)
         (isqlm--emit-prompt))))))
(defun isqlm--d-parse-modifiers (raw-cmd)
  "Parse RAW-CMD (e.g. \"d\", \"dt\", \"d+\", \"dtS+\") into modifiers.
Returns a plist (:types TYPE-LIST :verbose BOOL :system BOOL)."
  (let ((suffix (substring raw-cmd 1))  ; strip leading "d"
        (types nil)
        (verbose nil)
        (system nil))
    (dolist (ch (string-to-list suffix))
      (pcase ch
        (?t (push 'table types))
        (?v (push 'view types))
        (?i (push 'index types))
        (?+ (setq verbose t))
        (?S (setq system t))))
    (list :types (nreverse types) :verbose verbose :system system)))

(defun isqlm--d-dispatch (raw-cmd args)
  "Dispatch a \\d-family command.
RAW-CMD is the command name without \\, ARGS is the argument list."
  (setq isqlm--suppress-summary t)
  (let* ((mods (isqlm--d-parse-modifiers raw-cmd))
         (types (plist-get mods :types))
         (verbose (plist-get mods :verbose))
         (_system (plist-get mods :system))
         (pattern (car args)))
    (cond
     ;; \d TABLE — describe a specific table (no type modifier, has pattern)
     ((and (null types) pattern)
      (isqlm--d-describe-table pattern verbose))
     ;; \d — list all tables and views
     ((null types)
      (isqlm--d-list-tables pattern nil verbose))
     ;; \dt — list tables only
     ((memq 'table types)
      (isqlm--d-list-tables pattern "BASE TABLE" verbose))
     ;; \dv — list views only
     ((memq 'view types)
      (isqlm--d-list-tables pattern "VIEW" verbose))
     ;; \di — list indexes
     ((memq 'index types)
      (if pattern
          (isqlm--quick-sql (format "SHOW INDEX FROM `%s`;" pattern) t)
        (isqlm--quick-sql
         (concat "SELECT TABLE_NAME, INDEX_NAME, COLUMN_NAME,"
                 " NON_UNIQUE, SEQ_IN_INDEX, INDEX_TYPE"
                 " FROM INFORMATION_SCHEMA.STATISTICS"
                 " WHERE TABLE_SCHEMA = DATABASE()"
                 " ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX;") t))))))

;; ============================================================
;; \df — list functions/procedures (psql-style)
;; ============================================================

(defun isqlm--df-parse-modifiers (raw-cmd)
  "Parse RAW-CMD (e.g. \"df\", \"dfn\", \"dfp\", \"dfnp+\") into modifiers.
Returns a plist (:types TYPE-LIST :verbose BOOL :system BOOL).
Type letters: n = normal (FUNCTION), p = PROCEDURE."
  (let ((suffix (substring raw-cmd 2))  ; strip leading "df"
        (types nil)
        (verbose nil)
        (system nil))
    (dolist (ch (string-to-list suffix))
      (pcase ch
        (?n (push 'function types))
        (?p (push 'procedure types))
        (?+ (setq verbose t))
        (?S (setq system t))))
    (list :types (nreverse types) :verbose verbose :system system)))

(defun isqlm--df-dispatch (raw-cmd args)
  "Dispatch a \\df-family command.
RAW-CMD is the command name without \\, ARGS is the argument list."
  (if (not (isqlm--connected-p))
      (isqlm--output-error "Not connected.\n")
    (setq isqlm--suppress-summary t)
    (let* ((mods (isqlm--df-parse-modifiers raw-cmd))
           (types (plist-get mods :types))
           (verbose (plist-get mods :verbose))
           (system (plist-get mods :system))
           (pattern (car args))
           (arg-patterns (cdr args))
           ;; Determine routine types to show
           (type-filter
            (cond
             ((null types) '("FUNCTION" "PROCEDURE"))
             (t (mapcar (lambda (tp)
                          (pcase tp
                            ('function "FUNCTION")
                            ('procedure "PROCEDURE")))
                        types))))
           ;; Build WHERE clause
           (where-parts
            (append
             ;; Schema filter
             (if system
                 nil  ; show all schemas
               (list "ROUTINE_SCHEMA = DATABASE()"))
             ;; Type filter
             (when type-filter
               (list (format "ROUTINE_TYPE IN (%s)"
                             (mapconcat (lambda (rt) (format "'%s'" rt))
                                        type-filter ", "))))
             ;; Name pattern
             (when pattern
               (list (format "ROUTINE_NAME LIKE '%s'"
                             (replace-regexp-in-string
                              "\\*" "%" (replace-regexp-in-string
                                         "?" "_" pattern)))))
             ;; Argument type patterns (match against parameter types)
             (let ((clauses nil)
                   (pos 0))
               (dolist (ap arg-patterns)
                 (if (string= ap "-")
                     ;; Dash means: no more parameters after this position
                     (progn
                       (push (format
                              (concat "(SELECT COUNT(*) FROM"
                                      " INFORMATION_SCHEMA.PARAMETERS p"
                                      " WHERE p.SPECIFIC_SCHEMA = r.ROUTINE_SCHEMA"
                                      " AND p.SPECIFIC_NAME = r.ROUTINE_NAME"
                                      " AND p.ORDINAL_POSITION > 0) = %d")
                              pos)
                             clauses))
                   (setq pos (1+ pos))
                   (push (format
                          (concat "(SELECT COUNT(*) FROM"
                                  " INFORMATION_SCHEMA.PARAMETERS p"
                                  " WHERE p.SPECIFIC_SCHEMA = r.ROUTINE_SCHEMA"
                                  " AND p.SPECIFIC_NAME = r.ROUTINE_NAME"
                                  " AND p.ORDINAL_POSITION = %d"
                                  " AND p.DATA_TYPE LIKE '%s') > 0")
                          pos
                          (replace-regexp-in-string
                           "\\*" "%" (replace-regexp-in-string
                                      "?" "_" ap)))
                         clauses)))
               (nreverse clauses))))
           (where (if where-parts
                      (concat " WHERE "
                              (mapconcat #'identity where-parts " AND "))
                    ""))
           ;; Build SELECT columns
           (sql (if verbose
                    (concat
                     "SELECT"
                     (if system " r.ROUTINE_SCHEMA AS `Schema`," "")
                     " r.ROUTINE_NAME AS `Name`,"
                     " r.DTD_IDENTIFIER AS `Result`,"
                     " IFNULL((SELECT GROUP_CONCAT("
                     "   CONCAT(p.PARAMETER_NAME, ' ', p.DTD_IDENTIFIER)"
                     "   ORDER BY p.ORDINAL_POSITION SEPARATOR ', ')"
                     "  FROM INFORMATION_SCHEMA.PARAMETERS p"
                     "  WHERE p.SPECIFIC_SCHEMA = r.ROUTINE_SCHEMA"
                     "  AND p.SPECIFIC_NAME = r.ROUTINE_NAME"
                     "  AND p.ORDINAL_POSITION > 0), '') AS `Arguments`,"
                     " CASE r.ROUTINE_TYPE"
                     "   WHEN 'FUNCTION' THEN 'normal'"
                     "   WHEN 'PROCEDURE' THEN 'procedure'"
                     " END AS `Type`,"
                     " r.SQL_DATA_ACCESS AS `Volatility`,"
                     " r.DEFINER AS `Owner`,"
                     " r.SECURITY_TYPE AS `Security`,"
                     " r.ROUTINE_COMMENT AS `Description`"
                     " FROM INFORMATION_SCHEMA.ROUTINES r"
                     where
                     " ORDER BY r.ROUTINE_NAME")
                  (concat
                   "SELECT"
                   (if system " r.ROUTINE_SCHEMA AS `Schema`," "")
                   " r.ROUTINE_NAME AS `Name`,"
                   " r.DTD_IDENTIFIER AS `Result`,"
                   " IFNULL((SELECT GROUP_CONCAT("
                   "   CONCAT(p.PARAMETER_NAME, ' ', p.DTD_IDENTIFIER)"
                   "   ORDER BY p.ORDINAL_POSITION SEPARATOR ', ')"
                   "  FROM INFORMATION_SCHEMA.PARAMETERS p"
                   "  WHERE p.SPECIFIC_SCHEMA = r.ROUTINE_SCHEMA"
                   "  AND p.SPECIFIC_NAME = r.ROUTINE_NAME"
                   "  AND p.ORDINAL_POSITION > 0), '') AS `Arguments`,"
                   " CASE r.ROUTINE_TYPE"
                   "   WHEN 'FUNCTION' THEN 'normal'"
                   "   WHEN 'PROCEDURE' THEN 'procedure'"
                   " END AS `Type`"
                   " FROM INFORMATION_SCHEMA.ROUTINES r"
                   where
                   " ORDER BY r.ROUTINE_NAME"))))
      (isqlm--quick-sql (concat sql ";") t))))

;; Define the isqlm/ entry points for \df commands
(defun isqlm/df (&rest args)
  "List functions and procedures (psql-style).
\\df[np][S][+] [PATTERN [ARG_PATTERN ...]]
  n = normal (functions), p = procedures
  S = include system routines, + = extra detail
  PATTERN filters by name, ARG_PATTERNs filter by argument types.
  Use - as last arg_pattern to match exact argument count."
  (isqlm--df-dispatch "df" args))

(defun isqlm/dfn (&rest args)
  "List functions only.  \\dfn PATTERN to filter."
  (isqlm--df-dispatch "dfn" args))

(defun isqlm/dfp (&rest args)
  "List procedures only.  \\dfp PATTERN to filter."
  (isqlm--df-dispatch "dfp" args))

(defun isqlm/df+ (&rest args)
  "List functions/procedures with extra detail."
  (isqlm--df-dispatch "df+" args))

(defun isqlm/dfn+ (&rest args)
  "List functions with extra detail."
  (isqlm--df-dispatch "dfn+" args))

(defun isqlm/dfp+ (&rest args)
  "List procedures with extra detail."
  (isqlm--df-dispatch "dfp+" args))

(defun isqlm/dfS (&rest args)
  "List functions/procedures including system routines."
  (isqlm--df-dispatch "dfS" args))

(defun isqlm/dfS+ (&rest args)
  "List functions/procedures including system routines, with extra detail."
  (isqlm--df-dispatch "dfS+" args))

(defun isqlm/dfnS (&rest args)
  "List functions including system routines."
  (isqlm--df-dispatch "dfnS" args))

(defun isqlm/dfpS (&rest args)
  "List procedures including system routines."
  (isqlm--df-dispatch "dfpS" args))

(defun isqlm/dfnS+ (&rest args)
  "List functions including system routines, with extra detail."
  (isqlm--df-dispatch "dfnS+" args))

(defun isqlm/dfpS+ (&rest args)
  "List procedures including system routines, with extra detail."
  (isqlm--df-dispatch "dfpS+" args))

;; ============================================================
;; \ef — edit function/procedure definition (psql-style)
;; ============================================================

(defvar isqlm-ef-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'isqlm-ef-finish)
    (define-key map (kbd "C-c C-k") #'isqlm-ef-abort)
    map)
  "Keymap for `isqlm-ef-mode'.")

(define-minor-mode isqlm-ef-mode
  "Minor mode for editing a function/procedure definition.
\\<isqlm-ef-mode-map>
\\[isqlm-ef-finish] to execute (save) the definition.
\\[isqlm-ef-abort] to discard changes."
  :lighter " ISQLM-EF"
  :keymap isqlm-ef-mode-map)

(defun isqlm-ef-finish ()
  "Execute the edited function definition and close the buffer.
The entire buffer content is sent as a single SQL statement.
A trailing semicolon is added automatically if missing."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties
                            (point-min) (point-max))))
        (target isqlm--script-target)
        (buf (current-buffer)))
    (quit-window)
    (kill-buffer buf)
    (when (and target (buffer-live-p target))
      (with-current-buffer target
        ;; Ensure trailing semicolon
        (unless (string-suffix-p ";" text)
          (setq text (concat text ";")))
        (setq isqlm--async-busy t)
        (isqlm--async-execute-one
         text target
         (lambda ()
           (setq isqlm--async-busy nil)
           (isqlm--emit-prompt)))))))

(defun isqlm-ef-abort ()
  "Abort editing the function definition."
  (interactive)
  (let ((buf (current-buffer)))
    (quit-window)
    (kill-buffer buf)
    (message "Function editing aborted.")))

(defun isqlm/ef (&rest args)
  "Edit a function or procedure definition (psql-style \\ef).
\\ef NAME — fetch and edit the named function/procedure.
\\ef NAME(type1, type2) — specify argument types if ambiguous.
\\ef without argument — open a blank CREATE FUNCTION template.
The entire remainder of the line is taken as the argument.
C-c C-c to execute, C-c C-k to discard."
  (if (not (isqlm--connected-p))
      (isqlm--output-error "Not connected.\n")
    (let* ((raw-arg (car args))
           (name nil)
           (arg-types nil))
      ;; Parse: "func_name" or "func_name(int, varchar)"
      (when raw-arg
        (if (string-match "\\`\\([^(]+\\)\\(?:(\\(.*\\))\\)?\\'" raw-arg)
            (progn
              (setq name (string-trim (match-string 1 raw-arg)))
              (when (match-string 2 raw-arg)
                (setq arg-types (match-string 2 raw-arg))))
          (setq name (string-trim raw-arg))))
      (if (not name)
          ;; No function specified — blank template
          (isqlm--ef-open-editor
           (concat "CREATE FUNCTION function_name()\n"
                   "RETURNS INT\n"
                   "DETERMINISTIC\n"
                   "BEGIN\n"
                   "    RETURN 0;\n"
                   "END")
           nil)
        ;; Fetch the function/procedure definition
        (isqlm--ef-fetch-and-edit name arg-types)))))

(defun isqlm--ef-fetch-and-edit (name arg-types)
  "Fetch the definition of NAME and open it in an editor.
ARG-TYPES is a comma-separated type list for disambiguation, or nil."
  (let* ((q-name (replace-regexp-in-string "'" "''" name))
         ;; First determine routine type
         (info-sql
          (concat "SELECT ROUTINE_TYPE, ROUTINE_SCHEMA"
                  " FROM INFORMATION_SCHEMA.ROUTINES"
                  " WHERE ROUTINE_SCHEMA = DATABASE()"
                  " AND ROUTINE_NAME = '" q-name "'"
                  (when arg-types
                    ;; Count matching parameters to disambiguate
                    (let* ((types (split-string arg-types "," t "[ \t]+"))
                           (clauses
                            (cl-loop for tp in types
                                     for pos from 1
                                     collect (format
                                              (concat "EXISTS (SELECT 1 FROM"
                                                      " INFORMATION_SCHEMA.PARAMETERS p"
                                                      " WHERE p.SPECIFIC_SCHEMA = r.ROUTINE_SCHEMA"
                                                      " AND p.SPECIFIC_NAME = r.ROUTINE_NAME"
                                                      " AND p.ORDINAL_POSITION = %d"
                                                      " AND p.DATA_TYPE LIKE '%s')")
                                              pos
                                              (string-trim tp)))))
                      (concat " AND "
                              (mapconcat #'identity clauses " AND "))))
                  " LIMIT 1"))
         (info-result
          (condition-case err
              (isqlm-execute-string info-sql)
            (error
             (isqlm--output-mysql-error err)
             nil))))
    (if (or (not info-result) (null (plist-get info-result :rows)))
        (isqlm--output-error
         (format "Function or procedure \"%s\" not found.\n" name))
      (let* ((row (car (plist-get info-result :rows)))
             (routine-type (nth 0 row))  ; "FUNCTION" or "PROCEDURE"
             (show-cmd (if (string= routine-type "PROCEDURE")
                           (format "SHOW CREATE PROCEDURE `%s`"
                                   (replace-regexp-in-string "`" "``" name))
                         (format "SHOW CREATE FUNCTION `%s`"
                                 (replace-regexp-in-string "`" "``" name))))
             (create-result
              (condition-case err
                  (isqlm-execute-string show-cmd)
                (error
                 (isqlm--output-mysql-error err)
                 nil))))
        (if (or (not create-result) (null (plist-get create-result :rows)))
            (isqlm--output-error
             (format "Cannot fetch definition for %s \"%s\".\n"
                     (downcase routine-type) name))
          ;; Extract CREATE statement (column index 2 in SHOW CREATE output)
          (let* ((create-row (car (plist-get create-result :rows)))
                 (create-sql (nth 2 create-row)))
            (if (or (null create-sql) (string= create-sql ""))
                (isqlm--output-error
                 (format "Definition not available (no SHOW CREATE privilege?).\n"))
              ;; Transform to CREATE OR REPLACE (MySQL 10.1.1+ / MariaDB)
              ;; For standard MySQL, just use DROP + CREATE or plain CREATE
              (let ((edit-sql (isqlm--ef-prepare-sql create-sql routine-type)))
                (isqlm--ef-open-editor edit-sql nil)))))))))

(defun isqlm--ef-prepare-sql (create-sql _routine-type)
  "Prepare CREATE-SQL for editing.
Strips any DEFINER clause for cleaner editing.
_ROUTINE-TYPE is \"FUNCTION\" or \"PROCEDURE\"."
  ;; Remove DEFINER=`user`@`host` clause for cleaner editing
  (let ((sql (replace-regexp-in-string
              "\\s-*DEFINER=`[^`]*`@`[^`]*`\\s-*" " "
              create-sql)))
    ;; Ensure consistent formatting
    (string-trim sql)))

(defun isqlm--ef-open-editor (text line-number)
  "Open an editor buffer with TEXT for function editing.
If LINE-NUMBER is non-nil, position cursor on that line."
  (let ((target (current-buffer))
        (buf (generate-new-buffer "*isqlm-ef*")))
    (setq isqlm--async-busy t)  ; prevent prompt emission
    (pop-to-buffer buf)
    (sql-mode)
    (isqlm-ef-mode 1)
    (setq isqlm--script-target target)
    (insert text)
    (goto-char (point-min))
    (when (and line-number (> line-number 1))
      (forward-line (1- line-number)))
    (setq header-line-format
          "Edit function.  C-c C-c to execute, C-c C-k to discard.")
    (set-buffer-modified-p nil)
    (message "Edit function definition.  C-c C-c to execute, C-c C-k to discard.")))

;; ============================================================
;; Generate DDL/DML from SQL (\genddl)
;; ============================================================

(defun isqlm--genddl-extract-tables-from-sql (sql)
  "Extract physical table names from SQL text by parsing.
Looks for table references after FROM, JOIN, UPDATE, INTO keywords.
Handles: backtick-quoted names, schema.table, aliases (skipped),
subqueries (balanced paren skipping), comma-separated table lists.
Returns a deduplicated list of table name strings."
  (let ((tables nil)
        (case-fold-search t)
        (pos 0)
        (table-kw-re (concat "\\<\\(FROM\\|JOIN\\|UPDATE\\|INTO"
                             "\\|STRAIGHT_JOIN\\)\\>"))
        (tbl-re (concat "\\`[ \t\n]*"
                        "`?\\([a-zA-Z_][a-zA-Z0-9_]*\\)`?"
                        "\\(?:\\.`?\\([a-zA-Z_][a-zA-Z0-9_]*\\)`?\\)?"))
        (alias-re "\\`[ \t\n]+\\(?:[Aa][Ss][ \t\n]+\\)?`?\\([a-zA-Z_][a-zA-Z0-9_]*\\)`?")
        (comma-re "\\`[ \t\n]*,[ \t\n]*")
        (subq-alias-re "\\`[ \t\n]+\\(?:[Aa][Ss][ \t\n]+\\)?`?[a-zA-Z_][a-zA-Z0-9_]*`?"))
    (while (string-match table-kw-re sql pos)
      (setq pos (match-end 0))
      (let ((continue t))
        (while continue
          (let ((rest (substring sql pos)))
            (cond
             ;; Subquery: recurse into content, then skip balanced parens
             ((string-match "\\`[ \t\n]*(" rest)
              (let* ((open-offset (match-end 0))
                     (depth 1)
                     (p (+ pos open-offset)))
                (while (and (< p (length sql)) (> depth 0))
                  (cond
                   ((= (aref sql p) ?\() (cl-incf depth))
                   ((= (aref sql p) ?\)) (cl-decf depth)))
                  (cl-incf p))
                ;; Recurse: extract tables from the subquery content
                (let ((inner (substring sql (+ pos open-offset) (max (+ pos open-offset) (1- p)))))
                  (dolist (tbl (isqlm--genddl-extract-tables-from-sql inner))
                    (unless (member tbl tables)
                      (push tbl tables))))
                (setq pos p)
                (let ((after (substring sql pos)))
                  (when (string-match subq-alias-re after)
                    (setq pos (+ pos (match-end 0)))))))
             ;; Table name
             ((string-match tbl-re rest)
              (let* ((part1 (match-string 1 rest))
                     (part2 (match-string 2 rest))
                     (tbl-name (or part2 part1)))
                (setq pos (+ pos (match-end 0)))
                (let ((after (substring sql pos)))
                  (when (string-match alias-re after)
                    (let ((maybe-alias (match-string 1 after)))
                      (unless (member (downcase maybe-alias)
                                      '("from" "join" "inner" "left" "right"
                                        "outer" "cross" "natural" "straight_join"
                                        "select" "where" "on" "using" "into"
                                        "update" "table" "set" "values" "group"
                                        "order" "having" "limit" "union" "except"
                                        "intersect" "for" "lock" "window"
                                        "partition"))
                        (setq pos (+ pos (match-end 0)))))))
                (unless (member (downcase tbl-name)
                                '("select" "set" "dual"))
                  (unless (member tbl-name tables)
                    (push tbl-name tables)))))
             ;; Nothing matched
             (t (setq continue nil))))
          ;; Check for comma to continue list
          (when continue
            (let ((rest (substring sql pos)))
              (if (string-match comma-re rest)
                  (setq pos (+ pos (match-end 0)))
                (setq continue nil)))))))
    (nreverse tables)))

(defun isqlm--genddl-fetch-create-table (tbl-name)
  "Fetch the CREATE TABLE statement for TBL-NAME from the server.
Returns the DDL string or nil on failure."
  (condition-case nil
      (let* ((result (isqlm-execute-string
                      (format "SHOW CREATE TABLE `%s`" tbl-name)))
             (rows (plist-get result :rows)))
        (when (and rows (car rows))
          (nth 1 (car rows))))
    (error nil)))

(defun isqlm--genddl-parse-columns-from-ddl (ddl)
  "Parse column names and types from a CREATE TABLE DDL string.
Returns a list of (NAME . TYPE) pairs."
  (let ((cols nil)
        (pos 0))
    (while (string-match
            "^[ \t]+`\\([^`]+\\)`[ \t]+\\([a-zA-Z_][a-zA-Z0-9_(),]*\\)"
            ddl pos)
      (let ((name (match-string 1 ddl))
            (type (match-string 2 ddl)))
        (push (cons name type) cols))
      (setq pos (match-end 0))
      (when (string-match "\n" ddl pos)
        (setq pos (match-end 0))))
    (nreverse cols)))

(defun isqlm--genddl-format-value (val col-type)
  "Format VAL for INSERT INTO based on COL-TYPE.
Numbers are unquoted, strings are single-quoted, NULL stays NULL."
  (cond
   ((null val) "NULL")
   ;; Numeric types: output without quotes
   ((and (stringp col-type)
         (string-match-p "\\`\\(?:int\\|tinyint\\|smallint\\|mediumint\\|bigint\\|float\\|double\\|decimal\\|numeric\\|bit\\)" (downcase col-type)))
    (if (and (stringp val) (string-match-p "\\`-?[0-9]*\\.?[0-9]+\\'" val))
        val
      (format "%s" val)))
   ;; Everything else: quote as string
   (t (format "'%s'"
              (replace-regexp-in-string "'" "''" (format "%s" val))))))

(defun isqlm--genddl-fetch-data (tbl-name col-types &optional num-rows)
  "Fetch real data from TBL-NAME and format as INSERT INTO statement.
COL-TYPES is a list of (NAME . TYPE).  NUM-ROWS defaults to 2.
Returns the INSERT statement string, or nil if the table is empty."
  (let ((num-rows (or num-rows 2)))
    (condition-case nil
        (let* ((col-names (mapcar #'car col-types))
               (sql (format "SELECT %s FROM `%s` LIMIT %d"
                            (mapconcat (lambda (c) (format "`%s`" c))
                                       col-names ", ")
                            tbl-name num-rows))
               (result (isqlm-execute-string sql))
               (rows (plist-get result :rows)))
          (when (and rows (> (length rows) 0))
            (let ((value-rows nil))
              (dolist (row rows)
                (let ((formatted-vals nil)
                      (i 0))
                  (dolist (val row)
                    (push (isqlm--genddl-format-value
                           val (cdr (nth i col-types)))
                          formatted-vals)
                    (cl-incf i))
                  (push (concat "(" (mapconcat #'identity
                                               (nreverse formatted-vals) ", ")
                                ")")
                        value-rows)))
              (concat
               "INSERT INTO `" tbl-name "` ("
               (mapconcat (lambda (c) (format "`%s`" c)) col-names ", ")
               ") VALUES\n"
               (mapconcat #'identity (nreverse value-rows) ",\n")
               ";\n"))))
      (error nil))))

(defun isqlm/genddl (&rest args)
  "Generate CREATE TABLE and INSERT statements for tables referenced in SQL.
Usage: \\genddl SQL-STATEMENT
If no argument, uses the last executed SQL query.

Requires a live database connection.  Parses SQL text to extract table names,
then uses SHOW CREATE TABLE for DDL and SELECT for sample data.

Example:
  \\genddl select t1.a, t2.b from t1 join t2 on t1.id = t2.t1_id
Produces DDL+DML for t1 and t2."
  (let* ((sql (if args
                  (string-trim (mapconcat #'identity args " "))
                (or isqlm-last-query "")))
         (sql (if (string= sql "")
                  (progn (isqlm--output-error "No SQL provided.  Usage: \\genddl SELECT ...\n")
                         nil)
                sql)))
    (when sql
      (unless (isqlm--connected-p)
        (isqlm--output-error "Not connected.  \\genddl requires a database connection.\n")
        (setq sql nil))
      (when sql
        ;; Strip trailing ; or \G
        (let* ((clean-sql (replace-regexp-in-string
                           "\\(?:;\\|\\\\[Gg]\\)[ \t]*\\'" "" sql))
               (table-names (isqlm--genddl-extract-tables-from-sql clean-sql)))
          (if (null table-names)
              (isqlm--output-error "No tables found in SQL.\n")
            (let ((parts nil)
                  (seen (make-hash-table :test 'equal)))
              (dolist (tbl-name table-names)
                (unless (gethash tbl-name seen)
                  (puthash tbl-name t seen)
                  (let ((real-ddl (isqlm--genddl-fetch-create-table tbl-name)))
                    (if real-ddl
                        (let ((col-types (isqlm--genddl-parse-columns-from-ddl real-ddl)))
                          (push (concat real-ddl ";\n") parts)
                          (when col-types
                            (let ((dml (isqlm--genddl-fetch-data tbl-name col-types)))
                              (when dml (push dml parts)))))
                      (push (format "-- Table `%s`: not found\n" tbl-name) parts)))))
              (isqlm--output-info
               (mapconcat #'identity (nreverse parts) "\n")))))))))

;; Define the isqlm/ entry points for the command dispatcher
(defun isqlm/d (&rest args)
  "Describe tables/views (psql-style).  See \\help for details."
  (isqlm--d-dispatch "d" args))

(defun isqlm/dt (&rest args)
  "List tables.  \\dt PATTERN to filter."
  (isqlm--d-dispatch "dt" args))

(defun isqlm/dv (&rest args)
  "List views.  \\dv PATTERN to filter."
  (isqlm--d-dispatch "dv" args))

(defun isqlm/di (&rest args)
  "List/show indexes.  \\di TABLE to show indexes for a table."
  (isqlm--d-dispatch "di" args))

(defun isqlm/d+ (&rest args)
  "Describe with extra detail (engine, size, CREATE TABLE)."
  (isqlm--d-dispatch "d+" args))

(defun isqlm/dt+ (&rest args)
  "List tables with extra detail (engine, rows, size, comment)."
  (isqlm--d-dispatch "dt+" args))

(defun isqlm/dv+ (&rest args)
  "List views with extra detail."
  (isqlm--d-dispatch "dv+" args))

(defun isqlm/quit (&rest _args)
  "Quit ISQLM."
  (isqlm/exit))

(defun isqlm/exit (&rest _args)
  "Exit ISQLM — disconnect and kill the buffer.
Returns symbol `killed' so the caller knows not to touch the buffer."
  (when isqlm-connection
    (condition-case nil (mysql-close isqlm-connection) (error nil)))
  (isqlm--history-save)
  (let ((buf (current-buffer)))
    (quit-window)
    (kill-buffer buf))
  'killed)

;; ============================================================
;; \placement — view/change table/partition node placement (TDSQL 3)
;; Uses SQL interface: ALTER INSTANCE SPLIT/MIGRATE
;; ============================================================

(defun isqlm--placement-parse-target (target)
  "Parse TARGET string into (DB TABLE PARTITION).
TARGET formats:
  table           → (current-db, table, nil)
  db.table        → (db, table, nil)
  db.table.part   → (db, table, part)
  table.part      → (current-db, table, part)
Returns a plist (:db DB :table TABLE :partition PART)."
  (let* ((parts (split-string target "\\." t))
         (nparts (length parts))
         (cur-db (plist-get isqlm-connection-info :database)))
    (pcase nparts
      (1 (list :db cur-db :table (nth 0 parts) :partition nil))
      (2 ;; Ambiguous: db.table or table.partition
       ;; Heuristic: if part2 starts with "p" followed by digits, treat as partition
       (if (string-match-p "\\`p[0-9]" (nth 1 parts))
           (list :db cur-db :table (nth 0 parts) :partition (nth 1 parts))
         (list :db (nth 0 parts) :table (nth 1 parts) :partition nil)))
      (3 (list :db (nth 0 parts) :table (nth 1 parts) :partition (nth 2 parts)))
      (_ (error "Invalid target format: %s (use [db.]table[.partition])" target)))))

(defun isqlm--placement-query-rows (sql)
  "Run SQL and return its result rows, or nil if it is not a SELECT or is empty."
  (let ((result (isqlm-execute-string sql)))
    (and result
         (eq (plist-get result :type) 'select)
         (plist-get result :rows))))

(defun isqlm--placement-query-scalar (sql)
  "Run SQL and return the first column of the first row, or nil."
  (caar (isqlm--placement-query-rows sql)))

(defun isqlm--placement-poll (tries interval check-fn &optional on-wait)
  "Poll CHECK-FN up to TRIES times, sleeping INTERVAL seconds before each try.
Return the first non-nil value CHECK-FN produces, or nil on timeout.  The wait
uses `sit-for', so it stays responsive and is cancellable with C-g / C-c C-c.
ON-WAIT, when non-nil, is called with the 1-based attempt count after each
unsuccessful check (use it to print progress)."
  (let ((value nil))
    (dotimes (i tries)
      (unless value
        (sit-for interval)
        (setq value (funcall check-fn))
        (when (and (not value) on-wait)
          (funcall on-wait (1+ i)))))
    value))

(defun isqlm--placement-get-nodes ()
  "Get all cluster node names from information_schema.meta_cluster_nodes."
  (mapcar #'car
          (isqlm--placement-query-rows
           "SELECT node_name FROM information_schema.meta_cluster_nodes")))

(defun isqlm--placement-resolve-node (hint all-nodes)
  "Resolve node HINT to real name from ALL-NODES.
Supports exact, case-insensitive, index, suffix."
  (let ((h (string-trim hint)))
    (or (cl-find h all-nodes :test #'string=)
        (cl-find-if (lambda (n) (string= (downcase n) (downcase h))) all-nodes)
        (and (string-match-p "\\`[0-9]+\\'" h)
             (let ((idx (string-to-number h)))
               (and (>= idx 0) (< idx (length all-nodes))
                    (nth idx all-nodes))))
        (cl-find-if (lambda (n) (string-suffix-p h n)) all-nodes)
        (error "Cannot resolve node '%s'. Available: %s" h all-nodes))))

(defun isqlm--placement-rg-leader (rg-id)
  "Return the current leader node name of RG-ID, or nil."
  (isqlm--placement-query-scalar
   (format
    "SELECT leader_node_name FROM information_schema.META_CLUSTER_RGS WHERE rep_group_id=%s"
    rg-id)))

(defun isqlm--placement-show-info (db table partition)
  "Show current placement (RG -> leader node) for TABLE or PARTITION in DB.
For a PARTITION we resolve the RGs from that partition's own regions, so each
partition reports only its own RGs.  Without PARTITION we use the aggregated
table->RG->leader mapping in META_CLUSTER_TABLE_LOCATION."
  (let ((target-name (if partition
                         (format "%s.%s.%s" db table partition)
                       (format "%s.%s" db table))))
    (if partition
        (let ((rg-ids (delete-dups
                       (mapcar (lambda (r) (plist-get r :rg-id))
                               (isqlm--placement-get-region-info
                                db table partition)))))
          (if rg-ids
              (progn
                (isqlm--output-info (format "%s:\n" target-name))
                (dolist (rg rg-ids)
                  (isqlm--output-info
                   (format "  RG %s → %s\n" rg
                           (or (isqlm--placement-rg-leader rg) "?")))))
            (isqlm--output-info
             (format "%s: no regions found\n" target-name))))
      (let ((rows (isqlm--placement-query-rows
                   (format
                    "SELECT DISTINCT rep_group_id, leader_node_name FROM information_schema.META_CLUSTER_TABLE_LOCATION WHERE schema_name='%s' AND table_name='%s'"
                    db table))))
        (if rows
            (progn
              (isqlm--output-info (format "%s:\n" target-name))
              (dolist (row rows)
                (isqlm--output-info
                 (format "  RG %s → %s\n" (nth 0 row) (nth 1 row)))))
          (isqlm--output-info
           (format "%s: not found in META_CLUSTER_TABLE_LOCATION\n"
                   target-name)))))))

(defun isqlm--placement-get-region-info (db table &optional partition)
  "Get region info for TABLE (or PARTITION) in DB.
Return a list of plists (:region-id ID :rg-id RG :start-key S :end-key E)."
  (let ((tindex-id (isqlm--placement-query-scalar
                    (if partition
                        (format
                         "SELECT TINDEX_ID FROM INFORMATION_SCHEMA.PARTITIONS_VERBOSE WHERE table_schema='%s' AND table_name='%s' AND partition_name='%s'"
                         db table partition)
                      (format
                       "SELECT tindex_id FROM information_schema.tables WHERE table_schema='%s' AND table_name='%s'"
                       db table)))))
    (when tindex-id
      (mapcar (lambda (row)
                (list :region-id (nth 0 row) :rg-id (nth 1 row)
                      :start-key (nth 2 row) :end-key (nth 3 row)))
              (isqlm--placement-query-rows
               (format
                "SELECT region_id, rep_group_id, start_key, end_key FROM information_schema.META_CLUSTER_REGIONS WHERE data_obj_id=%s"
                tindex-id))))))

(defun isqlm--placement-get-pk-col (db table)
  "Get the first primary key column name for TABLE in DB."
  (isqlm--placement-query-scalar
   (format
    "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA='%s' AND TABLE_NAME='%s' AND INDEX_NAME='PRIMARY' ORDER BY SEQ_IN_INDEX LIMIT 1"
    db table)))

(defun isqlm--placement-get-storage-prefix (db table &optional partition)
  "Get the hex storage prefix for TABLE (or PARTITION) in DB.
For a partition, prefer TINDEX_ID_STORAGE_FORMAT from PARTITION_INDEXES; when
the table has no PRIMARY index, fall back to LPAD(HEX(TINDEX_ID),8,'0') derived
from PARTITIONS_VERBOSE (the same TINDEX_ID used to locate the regions).
For a non-partitioned table, derive it from `tindex_id'."
  (if partition
      (or (isqlm--placement-query-scalar
           (format
            "SELECT TINDEX_ID_STORAGE_FORMAT FROM information_schema.PARTITION_INDEXES WHERE table_schema='%s' AND table_name='%s' AND partition_name='%s' AND index_name='PRIMARY'"
            db table partition))
          (isqlm--placement-query-scalar
           (format
            "SELECT LPAD(HEX(TINDEX_ID),8,'0') FROM information_schema.PARTITIONS_VERBOSE WHERE table_schema='%s' AND table_name='%s' AND partition_name='%s'"
            db table partition)))
    (isqlm--placement-query-scalar
     (format
      "SELECT LPAD(HEX(tindex_id),8,'0') FROM information_schema.tables WHERE table_schema='%s' AND table_name='%s'"
      db table))))

(defun isqlm--placement-get-encode-key (db table where-clause)
  "Get the encoded key for the row matching WHERE-CLAUSE using MYROCK_ENCODE()."
  (isqlm--placement-query-scalar
   (format
    "SELECT SUBSTRING_INDEX(SUBSTRING_INDEX(MYROCK_ENCODE(),';',1),':',-1) FROM `%s`.`%s` FORCE INDEX(PRIMARY) WHERE %s"
    db table where-clause)))

(defun isqlm--placement-get-max-encoded-key (db table &optional partition)
  "Get the largest encoded clustered key in TABLE (or PARTITION) of DB.
Works for tables without a PRIMARY KEY: it orders the per-row encoded keys
themselves (MyRocks encodes the hidden rowid big-endian, so the lexically
largest encoded key is the physically last row).  No index hint is used, so
the hidden clustered index is scanned even when there is no PRIMARY key."
  (isqlm--placement-query-scalar
   (format
    "SELECT SUBSTRING_INDEX(SUBSTRING_INDEX(MYROCK_ENCODE(),';',1),':',-1) AS k FROM `%s`.`%s`%s ORDER BY k DESC LIMIT 1"
    db table (if partition (format " PARTITION (%s)" partition) ""))))

(defun isqlm--placement-split-range-block (split-key)
  "Split the range block covering SPLIT-KEY.
Region split requires the split key to align with a range block boundary.
Finds the range block containing SPLIT-KEY and splits it using
launch_range_block_job(is_split=1, is_random=0, rb_start_key, split_key)."
  (if (isqlm--placement-query-scalar
       (format
        "SELECT range_block_id FROM information_schema.TDSTORE_RANGE_BLOCK_INFO WHERE start_key = '%s' LIMIT 1"
        split-key))
      (isqlm--output-info
       "[placement] Range block boundary already exists at split key\n")
    (let ((rb-start (isqlm--placement-query-scalar
                     (format
                      "SELECT start_key FROM information_schema.TDSTORE_RANGE_BLOCK_INFO WHERE start_key <= '%s' AND end_key > '%s' AND range_block_state = 'kNormal' LIMIT 1"
                      split-key split-key))))
      (unless rb-start
        (error "Cannot find range block containing key '%s'" split-key))
      (isqlm--output-info
       (format "[placement] Splitting range block [%s...) at '%s'\n"
               rb-start split-key))
      (let ((rb-sql (format
                     "CALL dbms_admin.launch_range_block_job(1, 0, '%s', '%s')"
                     rb-start split-key)))
        (isqlm--output-info (format "[placement] %s\n" rb-sql))
        (isqlm-execute-string rb-sql))
      (if (isqlm--placement-poll
           30 1
           (lambda ()
             (isqlm--placement-query-scalar
              (format
               "SELECT range_block_id FROM information_schema.TDSTORE_RANGE_BLOCK_INFO WHERE start_key = '%s' LIMIT 1"
               split-key)))
           (lambda (n)
             (isqlm--output-info
              (format "[placement] ... waiting for range block split %ds\n" n))))
          (isqlm--output-info "[placement] Range block split done\n")
        (error "Range block split did not take effect within 30s")))))

(defun isqlm--placement-split-region-sql (region-id rg-id split-key)
  "Split REGION-ID in RG-ID at SPLIT-KEY using SQL interface.
Returns the result of ALTER INSTANCE SPLIT REGION."
  (let ((sql (format
              "ALTER INSTANCE SPLIT REGION %s IN RG %s AT KEY '%s' FORCE"
              region-id rg-id split-key)))
    (isqlm--output-info (format "[placement] %s\n" sql))
    (isqlm-execute-string sql)))

(defun isqlm--placement-rg-has-node (rg-id node)
  "Return non-nil if RG-ID already has a replica on NODE."
  (let ((members (isqlm--placement-query-scalar
                  (format
                   "SELECT member_node_names FROM information_schema.META_CLUSTER_RGS WHERE rep_group_id=%s"
                   rg-id))))
    (and (stringp members)
         (string-match-p (regexp-quote node) members))))

(defun isqlm--placement-rg-leader-is (rg-id node)
  "Return non-nil if the leader of RG-ID is currently NODE."
  (let ((leader (isqlm--placement-rg-leader rg-id)))
    (and (stringp leader) (string= leader node))))

(defun isqlm--placement-wait-rg-working (rg-id)
  "Wait until RG-ID has a working leader (rep_group_state contains L_Working).
Polls up to 30s.  Returns non-nil once ready."
  (isqlm--placement-poll
   30 1
   (lambda ()
     (let ((state (isqlm--placement-query-scalar
                   (format
                    "SELECT rep_group_state FROM information_schema.META_CLUSTER_RGS WHERE rep_group_id=%s"
                    rg-id))))
       (and (stringp state) (string-match-p "L_Working" state))))
   (lambda (n)
     (isqlm--output-info
      (format "[placement] ... waiting for RG %s ready %ds\n" rg-id n)))))

(defun isqlm--placement-place-rg-leader (rg-id node)
  "Make NODE the raft leader of RG-ID, migrating a replica there if needed.

The new RG produced by SPLIT RG inherits replicas from its parent, but its
membership/snapshot may not be populated immediately.  We therefore:
  1. Wait for the RG to become working (leader elected, split synced).
  2. If NODE has no replica yet, MIGRATE one there (retrying while the parent
     RG snapshot condition is not yet met) and wait for it to join.
  3. TRANSFER LEADER to NODE, retrying until the follower is working and the
     leader is confirmed on NODE."
  (isqlm--output-info
   (format "[placement] Step 3: Place leader of RG %s on %s\n" rg-id node))
  ;; 1. Wait for the new RG to settle after the split.
  (isqlm--placement-wait-rg-working rg-id)
  ;; 2. Ensure NODE has a replica (only needed when #nodes > #replicas).
  (unless (isqlm--placement-rg-has-node rg-id node)
    (let ((migrated nil))
      (dotimes (attempt 6)
        (unless migrated
          (condition-case err
              (let ((sql (format "ALTER INSTANCE MIGRATE RG %s TO '%s'"
                                 rg-id node)))
                (isqlm--output-info (format "[placement] %s\n" sql))
                (isqlm-execute-string sql)
                (setq migrated t))
            (error
             (if (< attempt 5)
                 (progn
                   (isqlm--output-info
                    (format "[placement] Migrate retry in 5s (%s)...\n"
                            (error-message-string err)))
                   (sit-for 5))
               (signal (car err) (cdr err)))))))
      ;; Wait for NODE to actually join as a member.
      (let ((joined nil))
        (dotimes (i 30)
          (unless joined
            (sit-for 2)
            (if (isqlm--placement-rg-has-node rg-id node)
                (setq joined t)
              (isqlm--output-info
               (format "[placement] ... waiting for replica on %s %ds\n"
                       node (* 2 (1+ i)))))))))
    (isqlm--placement-wait-rg-working rg-id))
  ;; 3. Transfer leadership to NODE (retry until confirmed).
  (let ((leader-ok nil))
    (dotimes (_ 30)
      (unless leader-ok
        (if (isqlm--placement-rg-leader-is rg-id node)
            (setq leader-ok t)
          (condition-case err
              (let ((sql (format "ALTER INSTANCE TRANSFER LEADER RG %s TO '%s'"
                                 rg-id node)))
                (isqlm--output-info (format "[placement] %s\n" sql))
                (isqlm-execute-string sql)
                (sit-for 2)
                (when (isqlm--placement-rg-leader-is rg-id node)
                  (setq leader-ok t)))
            (error
             (isqlm--output-info
              (format "[placement] ... follower not ready, retry in 3s (%s)\n"
                      (error-message-string err)))
             (sit-for 3))))))
    (if leader-ok
        (isqlm--output-info (format "[placement] Leader now on %s\n" node))
      (isqlm--output-info
       "[placement] Warning: leader may not be on target node yet\n"))))

(defun isqlm--placement-usage ()
  "Print \\placement usage text and the list of available cluster nodes."
  (isqlm--output-info
   (concat "Usage:\n"
           "  \\placement [db.]table[.partition]         show current node\n"
           "  \\placement [db.]table[.partition] NODE    split + place leader\n"
           "\nAvailable nodes:\n"))
  (condition-case nil
      (let ((nodes (isqlm--placement-get-nodes)))
        (if nodes
            (cl-loop for n in nodes for i from 0
                     do (isqlm--output-info (format "  [%d] %s\n" i n)))
          (isqlm--output-info "  (could not retrieve nodes)\n")))
    (error (isqlm--output-info "  (could not retrieve nodes)\n"))))

(defun isqlm--placement-compute-split-key (db table partition pk-col prefix
                                              target-name)
  "Compute the split key and a human label for TABLE/PARTITION in DB.
With a PK-COL, split at the encoded MAX(PK-COL).  Without one, split at the
largest encoded clustered key.  PREFIX is the storage prefix; TARGET-NAME is
used in errors.  Return a cons (SPLIT-KEY . LABEL); signal if empty/unencodable."
  (let (encoded-key label)
    (if pk-col
        (let ((max-val (isqlm--placement-query-scalar
                        (if partition
                            (format "SELECT MAX(`%s`) FROM `%s`.`%s` PARTITION (%s)"
                                    pk-col db table partition)
                          (format "SELECT MAX(`%s`) FROM `%s`.`%s`"
                                  pk-col db table)))))
          (unless max-val
            (error "%s is empty, cannot determine split point" target-name))
          (setq encoded-key (isqlm--placement-get-encode-key
                             db table
                             (format "`%s` = %s" pk-col
                                     (if (stringp max-val)
                                         (format "'%s'" max-val)
                                       (format "%s" max-val))))
                label (format "MAX(%s)=%s" pk-col max-val)))
      ;; No PRIMARY KEY: split at the largest encoded clustered key.
      (setq encoded-key (isqlm--placement-get-max-encoded-key
                         db table partition)
            label "max clustered key"))
    (unless encoded-key
      (error "%s is empty or its key cannot be encoded" target-name))
    (cons (concat prefix encoded-key) label)))

(defun isqlm--placement-find-region-for-key (regions split-key)
  "Return the region in REGIONS whose [start,end) range contains SPLIT-KEY.
Falls back to the last region when none matches."
  (let ((sk (downcase split-key)))
    (or (cl-find-if
         (lambda (r)
           (let ((rstart (downcase (plist-get r :start-key)))
                 (rend (downcase (plist-get r :end-key))))
             (and (not (string< sk rstart)) (string< sk rend))))
         regions)
        (car (last regions)))))

(defun isqlm--placement-region-already-split (regions split-key)
  "Return the region in REGIONS that already starts exactly at SPLIT-KEY, or nil."
  (let ((sk (downcase split-key)))
    (cl-find-if (lambda (r) (string= (downcase (plist-get r :start-key)) sk))
                regions)))

(defun isqlm--placement-wait-region-split (db table partition region-id)
  "Poll up to 30s for REGION-ID to split into a new region.
Return the new region id, or nil on timeout."
  (isqlm--placement-poll
   30 1
   (lambda ()
     (cl-find-if
      (lambda (id) (not (equal id region-id)))
      (mapcar (lambda (r) (plist-get r :region-id))
              (isqlm--placement-get-region-info db table partition))))
   (lambda (n) (isqlm--output-info (format "[placement] ... %ds\n" n)))))

(defun isqlm--placement-do-region-split (db table partition split-key
                                            region-id rg-id)
  "Split the range block and REGION-ID (in RG-ID) at SPLIT-KEY, then wait.
Return the new region id, or nil if the split did not take effect."
  (isqlm--output-info "[placement] Step 0: Split range block\n")
  (isqlm--placement-split-range-block split-key)
  (isqlm--output-info
   (format "[placement] Step 1: Split region %s in RG %s at key '%s'\n"
           region-id rg-id split-key))
  (isqlm--placement-split-region-sql region-id rg-id split-key)
  (isqlm--output-info
   "[placement] Waiting for region split (C-c C-c to cancel)...\n")
  (let ((new-region (isqlm--placement-wait-region-split
                     db table partition region-id)))
    (isqlm--output-info
     (if new-region
         (format "[placement] Region split done (%s)\n" new-region)
       "[placement] Region split timeout (30s)\n"))
    new-region))

(defun isqlm--placement-split-rg (rg-id new-region)
  "Split RG-ID, moving NEW-REGION into a freshly created RG.
A failure is reported but not re-raised (the new RG may still be usable)."
  (isqlm--output-info
   (format "[placement] Step 2: Split RG %s (move region %s to new RG)\n"
           rg-id new-region))
  (let ((sql (format
              "ALTER INSTANCE SPLIT RG %s BY 'manual-assigned' SET 'right_regions' = '%s'"
              rg-id new-region)))
    (isqlm--output-info (format "[placement] %s\n" sql))
    (condition-case err
        (isqlm-execute-string sql)
      (error
       (isqlm--output-info
        (format "[placement] Split RG failed: %s\n"
                (error-message-string err)))))))

(defun isqlm--placement-find-new-rg (db table partition old-rg-id)
  "Return the id of the RG created by splitting OLD-RG-ID, or nil."
  (cl-find-if
   (lambda (id) (not (equal id old-rg-id)))
   (delete-dups
    (mapcar (lambda (r) (plist-get r :rg-id))
            (isqlm--placement-get-region-info db table partition)))))

(defun isqlm--placement-split-rg-and-place (db table partition rg-id new-region
                                              node)
  "Split RG-ID to isolate NEW-REGION, then place the new RG's leader on NODE."
  (isqlm--placement-split-rg rg-id new-region)
  (sleep-for 3)
  (let ((new-rg (isqlm--placement-find-new-rg db table partition rg-id)))
    (if new-rg
        (isqlm--placement-place-rg-leader new-rg node)
      (isqlm--output-info
       "[placement] Warning: Could not identify new RG after split\n"))))

(defun isqlm--placement-change (db table partition node-arg)
  "Split TABLE/PARTITION's tail region and route future writes to NODE-ARG.
DB/TABLE/PARTITION identify the target; NODE-ARG is a node name/index/suffix."
  (let* ((target-name (if partition
                          (format "%s.%s.%s" db table partition)
                        (format "%s.%s" db table)))
         (all-nodes (isqlm--placement-get-nodes))
         (node (isqlm--placement-resolve-node node-arg all-nodes))
         (regions (isqlm--placement-get-region-info db table partition))
         (pk-col (isqlm--placement-get-pk-col db table))
         (prefix (isqlm--placement-get-storage-prefix db table partition)))
    (unless regions (error "Cannot find region info for %s" target-name))
    (unless prefix (error "Cannot get storage prefix for %s" target-name))
    (let* ((sk (isqlm--placement-compute-split-key
                db table partition pk-col prefix target-name))
           (split-key (car sk))
           (label (cdr sk))
           (target-region (isqlm--placement-find-region-for-key
                           regions split-key))
           (region-id (plist-get target-region :region-id))
           (rg-id (plist-get target-region :rg-id))
           (already (isqlm--placement-region-already-split regions split-key))
           (new-region nil))
      (isqlm--output-info
       (format "[placement] %s: split at %s, target → %s\n"
               target-name label node))
      (if already
          ;; A previous \placement already split at this key.
          (progn
            (setq new-region (plist-get already :region-id))
            (if (not (equal (plist-get already :rg-id) rg-id))
                (progn
                  (isqlm--output-info
                   "[placement] Already split, skipping to migrate\n")
                  (setq rg-id (plist-get already :rg-id)))
              (isqlm--output-info
               "[placement] Region already split, need RG split\n")))
        (setq new-region (isqlm--placement-do-region-split
                          db table partition split-key region-id rg-id)))
      (if new-region
          (isqlm--placement-split-rg-and-place
           db table partition rg-id new-region node)
        (isqlm--output-info
         (concat
          "[placement] Region split did not take effect.\n"
          "[placement] This cluster may not support manual region split.\n"
          "[placement] Ensure: sufficient data (OPTIMIZE TABLE to update stats),\n"
          "[placement]   split-region-key-count-lower-bound satisfied,\n"
          "[placement]   and TDStore supports split in this configuration.\n")))
      ;; Refresh the SQL-layer route cache so new writes see the new RG.
      (isqlm-execute-string "CALL dbms_admin.flush_route()")
      (isqlm--output-info "[placement] Route flushed. Done.\n"))))

(defun isqlm/placement (&rest args)
  "View or change table/partition node placement (TDSQL 3).

\\placement TARGET             show current node for TARGET
\\placement TARGET NODE        split RG + place leader on NODE for future writes

TARGET format: [db.]table[.partition]
  table              use current database
  db.table           specify database
  db.table.p0        specify partition
  table.p0           partition with current database

NODE: node name, 0-based index, or suffix.

When NODE is given:
  1. Finds the table/partition's tail region and RG
  2. Splits the region at MAX(pk) via ALTER INSTANCE SPLIT REGION
  3. Splits the RG via ALTER INSTANCE SPLIT RG (new RG gets the new region)
  4. Places the new RG's raft leader on NODE (MIGRATE if needed, then
     TRANSFER LEADER) so future writes route there
  5. Flushes the route cache

Examples:
  \\placement test.t1             show which node t1 is on
  \\placement test.t1.p0          show which node partition p0 is on
  \\placement t1 node-1-003       split + place leader, new writes → node-1-003
  \\placement t1.p2 node-1-003    split partition p2, new writes → node-1-003"
  (cond
   ((not (isqlm--connected-p))
    (isqlm--output-error "Not connected.\n"))
   ((null args)
    (isqlm--placement-usage))
   (t
    (condition-case err
        (let* ((parsed (isqlm--placement-parse-target (car args)))
               (db (plist-get parsed :db))
               (table (plist-get parsed :table))
               (partition (plist-get parsed :partition))
               (node-arg (cadr args)))
          (if (null node-arg)
              (isqlm--placement-show-info db table partition)
            (isqlm--placement-change db table partition node-arg)))
      (error
       (isqlm--output-error
        (format "[placement] Error: %s\n" (error-message-string err))))))))

;; ============================================================
;; Conditional flow (\if / \elif / \else / \endif)
;; ============================================================

(defun isqlm--cond-active-p ()
  "Return non-nil if the current conditional context is active.
When `isqlm-cond-stack' is empty, always active."
  (or (null isqlm-cond-stack)
      (plist-get (car isqlm-cond-stack) :active)))

(defun isqlm--cond-falsy-value-p (v)
  "Return non-nil if V is a \"falsy\" value for conditional checks.
Falsy: nil, 0, empty string, or strings \"0\"/\"false\"/\"no\"/\"nil\"/\"off\"."
  (or (null v)
      (eq v 0)
      (equal v 0.0)
      (and (stringp v)
           (member (downcase v) '("" "0" "false" "no" "nil" "off")))))

(defun isqlm--expand-expr-variables (expr)
  "Expand `:varname' references in EXPR string to variable values.
Replaces `:name' with the variable's value (as a Lisp literal) for
use in Elisp expressions.  Does not expand `::' (keyword symbols)."
  (replace-regexp-in-string
   ":\\([a-zA-Z_][a-zA-Z0-9_-]*\\)"
   (lambda (match)
     (let* ((name (match-string 1 match))
            (sym (intern-soft name)))
       (if (and sym (boundp sym))
           (let ((val (symbol-value sym)))
             (cond
              ((null val) "nil")
              ((stringp val) (format "%S" val))
              (t (format "%s" val))))
         match)))  ; leave unchanged if not bound
   expr t t))

(defun isqlm--cond-truthy-p (val)
  "Return non-nil if VAL is \"truthy\" for \\if/\\elif conditions.
VAL is a string from the command line.  Supported forms:
  :varname     — look up Emacs variable, check its value
  (elisp-expr) — evaluate, check result; :varname expanded inside
  literal      — check against falsy list"
  (cond
   ((null val) nil)
   ((string= val "") nil)
   ;; Elisp expression — expand :var references first
   ((string-prefix-p "(" val)
    (condition-case nil
        (let ((expanded (isqlm--expand-expr-variables val)))
          (not (isqlm--cond-falsy-value-p (eval (read expanded) t))))
      (error nil)))
   ;; Variable reference with :
   ((string-prefix-p ":" val)
    (let ((sym (intern-soft (substring val 1))))
      (and sym (boundp sym)
           (not (isqlm--cond-falsy-value-p (symbol-value sym))))))
   ;; Literal false values
   ((member (downcase val) '("0" "false" "no" "nil" "off")) nil)
   ;; Everything else is truthy
   (t t)))

(defun isqlm/if (&rest args)
  "Begin a conditional block.  ARGS: CONDITION.
CONDITION can be:
  - :varname     — true if variable is bound and non-nil
  - (elisp-expr) — true if expression evaluates to non-nil
  - literal      — true unless \"0\", \"false\", \"no\", \"nil\", \"\""
  (let* ((condition (string-join args " "))
         (result (isqlm--cond-truthy-p condition)))
    (push (list :satisfied result :active result) isqlm-cond-stack)))

(defun isqlm/elif (&rest args)
  "Add an elif branch to current \\if block.  ARGS: CONDITION."
  (if (not isqlm-cond-stack)
      (isqlm--output-error "\\elif without \\if\n")
    (let* ((frame (car isqlm-cond-stack))
           (already-satisfied (plist-get frame :satisfied))
           (condition (string-join args " "))
           (result (and (not already-satisfied)
                        (isqlm--cond-truthy-p condition))))
      (setcar isqlm-cond-stack
              (list :satisfied (or already-satisfied result)
                    :active result)))))

(defun isqlm/else (&rest _args)
  "Add an else branch to current \\if block."
  (if (not isqlm-cond-stack)
      (isqlm--output-error "\\else without \\if\n")
    (let* ((frame (car isqlm-cond-stack))
           (already-satisfied (plist-get frame :satisfied)))
      (setcar isqlm-cond-stack
              (list :satisfied t
                    :active (not already-satisfied))))))

(defun isqlm/endif (&rest _args)
  "End a conditional block."
  (if isqlm-cond-stack
      (pop isqlm-cond-stack)
    (isqlm--output-error "\\endif without \\if\n")))

(defun isqlm/echo (&rest args)
  "Output ARGS as text.  Supports :varname expansion."
  (let ((parts (mapcar (lambda (a)
                         (let ((expanded (isqlm--expand-arg a)))
                           (if (stringp expanded)
                               expanded
                             (format "%s" expanded))))
                       args)))
    (isqlm--output (concat (string-join parts " ") "\n"))))

(defun isqlm/gset (&rest args)
  "Store the last query result into Emacs variables (à la psql \\gset).
Usage: first run a SELECT, then \\gset [PREFIX].
The last query must have returned exactly one row."
  (let ((prefix (or (car args) "")))
    (cond
     ((not isqlm-last-result)
      (isqlm--output-error "No previous query result.  Run a SELECT first.\n"))
     ((/= (length (cdr isqlm-last-result)) 1)
      (isqlm--output-error
       (format "\\gset requires exactly 1 row, got %d.\n"
               (length (cdr isqlm-last-result)))))
     (t
      (let ((columns (car isqlm-last-result))
            (row (cadr isqlm-last-result)))
        (dotimes (i (length columns))
          (set (intern (concat prefix (nth i columns)))
               (nth i row))))))))

;; ============================================================
;; For loop (\for var in val1 val2 ... { body })
;; ============================================================

(defun isqlm--for-collecting-p ()
  "Return non-nil if we are currently collecting for-loop body lines."
  (and isqlm-for-stack (plist-get (car isqlm-for-stack) :brace)))

(defun isqlm--for-find-matching-brace (str start)
  "Return index of the `}' matching the `{' at START in STR, or nil.
Tracks single quotes, double quotes and backticks so that braces
inside SQL string/identifier literals are ignored, and handles
nested braces."
  (let ((i (1+ start)) (len (length str)) (depth 1) (in-quote nil) result)
    (while (and (< i len) (not result))
      (let ((ch (aref str i)))
        (cond
         (in-quote
          (cond
           ;; backslash escape inside quotes
           ((and (eq ch ?\\) (< (1+ i) len)) (setq i (1+ i)))
           ((eq ch in-quote) (setq in-quote nil))))
         ((memq ch '(?\' ?\" ?\`)) (setq in-quote ch))
         ((eq ch ?{) (setq depth (1+ depth)))
         ((eq ch ?})
          (setq depth (1- depth))
          (when (= depth 0) (setq result i)))))
      (setq i (1+ i)))
    result))

(defun isqlm--for-sql-values (sql)
  "Execute SQL and return the first column of each row as a list of strings.
Used by the `\\for VAR in {SQL} { body }' form (Eshell-style command
substitution).  Returns nil on error or when there is no result set."
  (let* ((stripped (string-trim sql))
         (stripped (if (string-suffix-p ";" stripped)
                       (string-trim (substring stripped 0 -1))
                     stripped))
         (result (condition-case err
                     (isqlm-execute-string stripped)
                   (error
                    (isqlm--output-error
                     (format "*** SQL Error in \\for *** %s\n"
                             (isqlm--error-message err)))
                    'error))))
    (cond
     ((eq result 'error) nil)
     ((and result (eq (plist-get result :type) 'select))
      (mapcar (lambda (row)
                (let ((v (car row)))
                  (if (stringp v) v (format "%s" v))))
              (plist-get result :rows)))
     (t
      (isqlm--output-error "\\for: {SQL} source must be a SELECT query\n")
      nil))))

(defun isqlm--for-parse-values (rest)
  "Parse the value source at the start of REST (text after `VAR in ').
Return a cons (VALUES . BODY-SPEC) where VALUES is the resolved list of
value strings and BODY-SPEC is the remaining string (the loop body,
starting at its `{' or empty).  Three value-source forms are supported:
  {SQL}       — run SQL, use the first column of each row (Eshell-style)
  (elisp)     — evaluate an Elisp expression yielding a list
  v1 v2 ...   — literal whitespace-separated values"
  (cond
   ;; {SQL} command-substitution source
   ((string-prefix-p "{" rest)
    (let ((close (isqlm--for-find-matching-brace rest 0)))
      (if (not close)
          (progn
            (isqlm--output-error "\\for: unterminated `{' in value source\n")
            (cons nil ""))
        (let ((sql (substring rest 1 close))
              (body-spec (string-trim (substring rest (1+ close)))))
          (cons (isqlm--for-sql-values sql) body-spec)))))
   ;; (elisp) expression source
   ((string-prefix-p "(" rest)
    (condition-case err
        (let* ((read-result (read-from-string rest))
               (expr (car read-result))
               (end (cdr read-result))
               (body-spec (string-trim (substring rest end)))
               (result (eval expr t)))
          (cons (mapcar (lambda (v) (if (stringp v) v (format "%s" v)))
                        (if (listp result) result (list result)))
                body-spec))
      (error
       (isqlm--output-error
        (format "*** Eval Error in \\for values *** %s\n"
                (isqlm--error-message err)))
       (cons nil ""))))
   ;; literal whitespace-separated values
   (t
    (let* ((brace-open (string-match "{" rest))
           (values-str (string-trim (if brace-open
                                        (substring rest 0 brace-open)
                                      rest)))
           (body-spec (if brace-open (string-trim (substring rest brace-open)) ""))
           (values (mapcar (lambda (v)
                             (let ((expanded (isqlm--expand-arg v)))
                               (if (stringp expanded) expanded
                                 (format "%s" expanded))))
                           (isqlm--parse-command-line values-str))))
      (cons values body-spec)))))

(defun isqlm--for-start (input)
  "Parse `\\for var in VALUE-SOURCE { body }' and push a for-loop frame.
INPUT is the full line.  The value source may be a list of literal
values, an Elisp expression `(...)', or a SQL query `{...}' whose first
column supplies the values (Eshell-style command substitution).  The
body may take three forms:
  \\for VAR in SRC { body lines... }  — inline (single line)
  \\for VAR in SRC {                  — brace on same line, body follows
  \\for VAR in SRC                    — brace expected on next line
Examples:
  \\for i in 1 2 3 { select :i; }
  \\for i in (number-sequence 1 10) { select :i; }
  \\for t in {select table_name from information_schema.tables;} \
      { analyze table :t; }"
  (let* ((trimmed (string-trim input))
         (after-for (string-trim (substring trimmed (length "\\for")))))
    (if (not (let ((case-fold-search t))
               (string-match "\\`\\([^ \t]+\\)[ \t]+in\\(?:[ \t]+\\|\\'\\)"
                             after-for)))
        (isqlm--output-error "Usage: \\for VAR in VALUE-SOURCE { body }\n")
      (let* ((var-name (match-string 1 after-for))
             (rest (substring after-for (match-end 0)))
             (parsed (isqlm--for-parse-values rest))
             (values (car parsed))
             (body-spec (cdr parsed)))
        (when values
          (isqlm--for-dispatch-body (intern var-name) values body-spec))))))

(defun isqlm--for-dispatch-body (var values body-spec)
  "Dispatch the loop body given VAR, VALUES and BODY-SPEC.
BODY-SPEC is the text following the value source (starting at its `{'
or empty).  Handles inline `{ ... }', a same-line opening `{', or an
empty spec (brace expected on the next line)."
  (let* ((brace-open (and (> (length body-spec) 0)
                          (string-prefix-p "{" body-spec)))
         (brace-close (and brace-open
                           (string-match "}[[:space:]]*\\'" body-spec))))
    (cond
     ;; Inline: { body } all on one line
     ((and brace-open brace-close)
      (let* ((body-str (string-trim
                        (substring body-spec 1 (match-beginning 0))))
             (body-lines (split-string body-str ";" t "[ \t\n]+")))
        (setq body-lines
              (mapcar (lambda (l)
                        (let ((s (string-trim l)))
                          (if (and (> (length s) 0)
                                   (not (string-prefix-p "\\" s))
                                   (not (string-suffix-p ";" s))
                                   (not (string-suffix-p "\\G" s)))
                              (concat s ";")
                            s)))
                      body-lines))
        (isqlm--for-execute-body var values body-lines)))
     ;; Brace on same line, body follows on subsequent lines
     (brace-open
      (push (list :var var :values values :body nil :brace t :depth 0)
            isqlm-for-stack))
     ;; No brace yet, expect { on next line
     (t
      (push (list :var var :values values :body nil :brace nil :depth 0)
            isqlm-for-stack)))))
(defun isqlm--for-collect-line (input)
  "Collect INPUT as a body line for the current for-loop.
Handle nested { } and detect the closing }."
  (let* ((trimmed (string-trim input))
         (frame (car isqlm-for-stack)))
    (cond
     ;; Opening { on its own line (first line after \for without {)
     ((and (not (plist-get frame :brace))
           (string= trimmed "{"))
      (plist-put frame :brace t))
     ;; Not yet seen opening brace — error
     ((not (plist-get frame :brace))
      (isqlm--output-error "Expected `{' after \\for\n")
      (pop isqlm-for-stack))
     ;; Closing } at depth 0 — execute
     ((and (string= trimmed "}")
           (= (plist-get frame :depth) 0))
      (let ((var (plist-get frame :var))
            (values (plist-get frame :values))
            (body (nreverse (plist-get frame :body))))
        (pop isqlm-for-stack)
        (isqlm--for-execute-body var values body)))
     ;; Nested { — track depth
     ((string= trimmed "{")
      (plist-put frame :depth (1+ (plist-get frame :depth)))
      (plist-put frame :body (cons input (plist-get frame :body))))
     ;; Nested } — track depth
     ((string= trimmed "}")
      (plist-put frame :depth (1- (plist-get frame :depth)))
      (plist-put frame :body (cons input (plist-get frame :body))))
     ;; Normal body line
     (t
      (plist-put frame :body (cons input (plist-get frame :body)))))))

(defun isqlm--for-execute-body (var values body)
  "Execute BODY lines for each value in VALUES, binding VAR.
Each line is executed asynchronously via `isqlm--execute-line'."
  (isqlm--for-iterate var values body))

(defun isqlm--for-iterate (var values body)
  "Iterate: bind VAR to (car VALUES), run BODY lines, then recurse.
VAR is bound in `isqlm-for-bindings' (not via `set') so that constant
names such as `t'/`nil' work and the global namespace stays clean."
  (if (null values)
      nil  ; done
    (setf (alist-get var isqlm-for-bindings) (car values))
    (isqlm--for-run-lines
     body var (cdr values) body)))

(defun isqlm--for-run-lines (lines var remaining-values all-body)
  "Run LINES one by one (async), then iterate to next value."
  (if (null lines)
      ;; This iteration done — proceed to next value
      (isqlm--for-iterate var remaining-values all-body)
    (isqlm--execute-line
     (car lines)
     (lambda ()
       (isqlm--for-run-lines
        (cdr lines) var remaining-values all-body)))))

(defconst isqlm--cond-flow-commands '("if" "elif" "else" "endif")
  "List of conditional flow command names.")

(defun isqlm--cond-flow-command-p (input)
  "Return non-nil if INPUT is a conditional flow command."
  (let* ((trimmed (string-trim input))
         (parts (split-string trimmed "[ \t]+" t))
         (first (car parts)))
    (and first
         (string-prefix-p "\\" first)
         (> (length first) 1)
         (member (downcase (substring first 1)) isqlm--cond-flow-commands))))

(defun isqlm--process-cond-flow (input)
  "Process a conditional flow command in INPUT.
Dispatches to isqlm/if, isqlm/elif, isqlm/else, or isqlm/endif.
When in an inactive branch, only \\if (to track nesting) and
\\endif/\\elif/\\else (to manage the stack) are fully processed."
  (let* ((trimmed (string-trim input))
         (parts (isqlm--parse-command-line trimmed))
         (first (car parts))
         (cmd (downcase (substring first 1)))
         (args (cdr parts)))
    (cond
     ;; \if — always push a new frame; if parent is inactive, push inactive
     ((string= cmd "if")
      (if (isqlm--cond-active-p)
          (isqlm/if (string-join args " "))
        ;; Nested \if in inactive branch: push unconditionally inactive frame
        (push (list :satisfied t :active nil) isqlm-cond-stack)))
     ;; \elif — only evaluate if in an active parent context
     ((string= cmd "elif")
      (when isqlm-cond-stack
        ;; Check if the *parent* (one level up) is active
        (let ((parent-active (or (null (cdr isqlm-cond-stack))
                                 (plist-get (cadr isqlm-cond-stack) :active))))
          (if parent-active
              (apply #'isqlm/elif args)
            ;; In inactive parent: keep current frame inactive
            nil))))
     ;; \else — same logic as \elif
     ((string= cmd "else")
      (when isqlm-cond-stack
        (let ((parent-active (or (null (cdr isqlm-cond-stack))
                                 (plist-get (cadr isqlm-cond-stack) :active))))
          (if parent-active
              (isqlm/else)
            nil))))
     ;; \endif — always pop
     ((string= cmd "endif")
      (isqlm/endif)))))

;; ============================================================
;; Command dispatch (eshell-style)
;; ============================================================

(defvar isqlm-command-aliases
  '(("?" . "help")
    ("h" . "help")
    ("q" . "quit")
    ("u" . "use")
    ("." . "i"))
  "Alist mapping command aliases to canonical command names.
E.g. \\? and \\h both map to \\help.")

(defun isqlm--try-numeric (str)
  "If STR looks like a number, return the number; otherwise return STR."
  (if (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]*\\)?\\'" str)
      (string-to-number str)
    str))

(defun isqlm--expand-arg (arg)
  "Expand ARG: if it starts with `:' treat as a variable reference.
`:varname' expands to the value of varname.  Active `\\for' loop
bindings (in `isqlm-for-bindings') take precedence over global
variables.  Otherwise return ARG as-is (with numeric coercion)."
  (if (and (stringp arg) (string-prefix-p ":" arg) (> (length arg) 1))
      (let* ((name (substring arg 1))
             (binding (assq (intern name) isqlm-for-bindings)))
        (if binding
            (cdr binding)
          (let ((sym (intern-soft name)))
            (if (and sym (boundp sym))
                (symbol-value sym)
              (user-error "Void variable: %s" name)))))
    (isqlm--try-numeric arg)))

(defun isqlm--parse-command-line (str)
  "Parse STR into a list of tokens, respecting double-quoted strings.
E.g. `\\message \"hello world\"' → (\"\\\\message\" \"hello world\")."
  (let ((i 0) (len (length str)) tokens current)
    (while (< i len)
      (let ((ch (aref str i)))
        (cond
         ;; Whitespace outside quotes: flush current token
         ((memq ch '(?\s ?\t))
          (when current
            (push (apply #'string (nreverse current)) tokens)
            (setq current nil)))
         ;; Double quote: read until closing quote
         ((= ch ?\")
          (cl-incf i)
          (while (and (< i len) (/= (aref str i) ?\"))
            (push (aref str i) current)
            (cl-incf i)))
         ;; Normal character
         (t (push ch current))))
      (cl-incf i))
    (when current
      (push (apply #'string (nreverse current)) tokens))
    (nreverse tokens)))

(defun isqlm--try-builtin-command (input)
  "Try to dispatch INPUT as a built-in command.
Built-in commands start with `\\'.  E.g. `\\connect', `\\help'.
Lookup order:
  1. isqlm/CMD (built-in isqlm command)
  2. CMD as an Emacs Lisp function (à la Eshell)
Return t if handled, `killed' if the buffer was killed,
nil if it should be treated as SQL."
  (let* ((trimmed (string-trim input))
         (parts (isqlm--parse-command-line trimmed))
         (first (car parts)))
    (when (and first (string-prefix-p "\\" first) (> (length first) 1))
      ;; Skip \G — it's a SQL terminator, not a command
      (unless (string= (upcase first) "\\G")
        (let* ((raw-cmd (downcase (substring first 1)))
               (cmd (or (cdr (assoc raw-cmd isqlm-command-aliases)) raw-cmd))
               ;; For \eval and \ef, pass the raw rest of the line (not tokenized)
               (args (if (member cmd '("eval" "ef"))
                         (let ((rest (string-trim
                                      (substring trimmed (length first)))))
                           (and (> (length rest) 0) (list rest)))
                       (cdr parts)))
               (isqlm-func (intern-soft (concat "isqlm/" cmd)))
               (elisp-func (intern-soft cmd)))
          (cond
           ;; 1. isqlm built-in command
           ((and isqlm-func (fboundp isqlm-func))
            (let* ((expanded-args (mapcar #'isqlm--expand-arg args))
                   ;; isqlm commands expect string args, convert back
                   (str-args (mapcar (lambda (a)
                                       (if (stringp a) a (format "%s" a)))
                                     expanded-args))
                   (ret (apply isqlm-func str-args)))
              (if (eq ret 'killed) 'killed t)))
           ;; 2. Emacs Lisp function (interactive or not)
           ((and elisp-func (fboundp elisp-func))
            (condition-case err
                (let* ((expanded-args
                        (if (eq elisp-func 'setq)
                            ;; setq is a special form; use `set' instead
                            (if (< (length args) 2)
                                (user-error "Usage: \\setq VARIABLE VALUE")
                              (let ((val (isqlm--expand-arg (nth 1 args))))
                                (set (intern (car args)) val)
                                (when val
                                  (isqlm--output
                                   (concat (if (stringp val) val (pp-to-string val))
                                           "\n")))
                                nil))  ; nil so the outer `when result' is skipped
                          (mapcar #'isqlm--expand-arg args)))
                       (result (and expanded-args
                                    (apply elisp-func expanded-args))))
                  (when result
                    (isqlm--output
                     (concat (if (stringp result)
                                 result
                               (pp-to-string result))
                             "\n"))))
              (error
               (isqlm--output-error
                (format "*** Lisp Error *** %s\n" (isqlm--error-message err)))))
            t)
           ;; 3. Unknown
           (t
            (isqlm--output-error
             (format "Unknown command: %s.  Type \\help for help.\n" first))
            t)))))))

;; ============================================================
;; Input handling (eshell-style: read from buffer, no process)
;; ============================================================

(defun isqlm-send-input ()
  "Read current input and execute it.
If point is in the history area (before the current prompt), copy
the current line to the input area and execute it — similar to
Eshell and sql-mode behavior.
If the input is a built-in command, dispatch it.
If it is SQL and complete (ends with `;' or `\\G'), execute it.
Otherwise, insert a continuation prompt for multi-line input."
  (interactive)
  ;; Block input while async query is running
  (if isqlm--async-busy
      (message "Query in progress... (C-c C-c to cancel)")
  ;; Normal input handling
  (progn
  ;; If point is before the current input area, grab the (possibly
  ;; edited) input from this line and copy it to the input area, then
  ;; execute.  Past input lines are not read-only, so the user can
  ;; edit them in place before pressing RET — Eshell-style.
  (when (< (point) (marker-position isqlm-last-output-end))
    (let* ((bol (line-beginning-position))
           (eol (line-end-position))
           ;; Find the end of the prompt region on this line.
           ;; Walk forward from bol past any field=prompt text.
           (input-start
            (if (eq (get-text-property bol 'field) 'prompt)
                (next-single-property-change bol 'field nil eol)
              bol))
           (line (string-trim (buffer-substring-no-properties
                               input-start eol))))
      (when (> (length line) 0)
        ;; Place the line in the current input area and fall through
        (isqlm--replace-current-input line)
        (goto-char (point-max)))))
  ;; Now proceed with normal input handling
  (let ((isqlm-buf (current-buffer))
        (input (buffer-substring-no-properties
                isqlm-last-output-end (point-max))))
    ;; Record input markers
    (set-marker isqlm-last-input-start (marker-position isqlm-last-output-end))
    (set-marker isqlm-last-input-end (point-max))
    ;; Move past input (insert newline to "submit" it)
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (insert "\n")
      ;; Mark the submitted input as field=input but NOT read-only,
      ;; so the user can edit previous input lines in place (Eshell-style).
      ;; rear-nonsticky only for read-only — field must remain sticky so
      ;; newly inserted characters inherit field=input.
      ;; The trailing newline IS read-only to prevent deletion across boundaries.
      (add-text-properties isqlm-last-input-start (1- (point))
                           '(rear-nonsticky (read-only) field input))
      (add-text-properties (1- (point)) (point)
                           '(read-only t rear-nonsticky (read-only) field input)))
    ;; Update output-end to current position
    (set-marker isqlm-last-output-end (point))
    ;; Reset history navigation
    (setq isqlm-history-index nil)
    (setq isqlm-input-saved nil)
    ;; Build accumulated input
    (let ((accumulated (concat isqlm-pending-input
                               (if (string= isqlm-pending-input "") "" "\n")
                               input)))
      (cond
       ;; Empty input
       ((string= (string-trim accumulated) "")
        (setq isqlm-pending-input "")
        (isqlm--emit-prompt))

       ;; Collecting for-loop body lines
       ((isqlm--for-collecting-p)
        (isqlm--for-collect-line accumulated)
        (setq isqlm-pending-input "")
        (isqlm--emit-prompt))

       ;; \for — start a new for-loop (may have { on same line)
       ((and (string= isqlm-pending-input "")
             (let ((first (car (split-string (string-trim accumulated) "[ \t]+" t))))
               (and first (string-prefix-p "\\" first)
                    (string= (downcase (substring first 1)) "for"))))
        (isqlm--for-start accumulated)
        (isqlm--add-to-history accumulated)
        (setq isqlm-pending-input "")
        (isqlm--emit-prompt))

       ;; Waiting for opening { of a for-loop
       ((and isqlm-for-stack (not (plist-get (car isqlm-for-stack) :brace)))
        (isqlm--for-collect-line accumulated)
        (setq isqlm-pending-input "")
        (isqlm--emit-prompt))

       ;; Conditional flow commands — always processed, even in inactive branches
       ((and (string= isqlm-pending-input "")
             (isqlm--cond-flow-command-p accumulated))
        (isqlm--process-cond-flow accumulated)
        (isqlm--add-to-history accumulated)
        (setq isqlm-pending-input "")
        (isqlm--emit-prompt))

       ;; In inactive conditional branch — skip everything else
       ((not (isqlm--cond-active-p))
        (setq isqlm-pending-input "")
        (isqlm--emit-prompt))

       ;; DELIMITER directive (MySQL CLI compatible, no \ prefix)
       ((and (string= isqlm-pending-input "")
             (isqlm--delimiter-directive-p (string-trim accumulated)))
        (let ((new-delim (isqlm--delimiter-directive-p
                          (string-trim accumulated))))
          (setq isqlm-delimiter new-delim)
          (isqlm--add-to-history accumulated)
          (setq isqlm-pending-input "")
          (isqlm--output-info
           (if (string= new-delim ";")
               "Delimiter reset to: ;\n"
             (format "Delimiter set to: %s\n" new-delim)))
          (isqlm--emit-prompt)))

       ;; If no pending input, try builtin command first
       ((and (string= isqlm-pending-input "")
             (isqlm--try-builtin-command accumulated))
        (when (buffer-live-p isqlm-buf)
          (with-current-buffer isqlm-buf
            (isqlm--add-to-history accumulated)
            (setq isqlm-pending-input "")
            ;; Don't emit prompt if the command started an async operation
            ;; (async-execute-statements will emit it when done)
            (unless isqlm--async-busy
              (isqlm--emit-prompt)))))

       ;; Incomplete SQL (no terminator yet)
       ((not (isqlm--sql-complete-p accumulated))
        (setq isqlm-pending-input accumulated)
        (isqlm--emit-prompt))

       ;; Complete SQL — execute (possibly multiple statements)
       (t
        (isqlm--add-to-history accumulated)
        (setq isqlm-pending-input "")
        (let ((statements (isqlm--split-statements accumulated)))
          (setq isqlm--async-busy t)
          (isqlm--async-execute-statements statements isqlm-buf)))))))))

;; ============================================================
;; Interactive commands (for keybindings / M-x)
;; ============================================================

(defun isqlm-connect (&optional host user database port)
  "Connect to MySQL interactively or from Lisp.
When called interactively:
  - If `sql-connection-alist' is non-empty, prompt for a connection name
    (like `isqlm-sql-connect').
  - Otherwise, use default parameters.
Ensures an ISQLM buffer exists before connecting.
PASSWORD is prompted via echo area when `isqlm-prompt-password' is non-nil."
  (interactive)
  (if (and (called-interactively-p 'any)
           (boundp 'sql-connection-alist)
           sql-connection-alist)
      ;; Prompt for connection name
      (let ((name (completing-read "Connection: "
                                   (mapcar #'car sql-connection-alist) nil t)))
        (isqlm-sql-connect name))
    ;; Positional args or defaults
    (unless (derived-mode-p 'isqlm-mode)
      (isqlm))
    (let ((args nil))
      (when port (push (number-to-string port) args))
      (when database (push database args))
      (when user (push user args))
      (when host (push host args))
      (apply #'isqlm/connect args))))

(defun isqlm-disconnect ()
  "Disconnect from MySQL."
  (interactive)
  (isqlm/disconnect)
  (isqlm--emit-prompt))

(defun isqlm-reconnect ()
  "Reconnect to MySQL."
  (interactive)
  (isqlm/reconnect)
  (isqlm--emit-prompt))

(defun isqlm-clear-buffer ()
  "Clear the ISQLM buffer."
  (interactive)
  (isqlm/clear)
  (isqlm--emit-prompt))

(defun isqlm-interrupt ()
  "Abort the current (possibly multi-line) input and show a fresh prompt.
If an async query is in progress, cancel it."
  (interactive)
  ;; Cancel any async query
  (when isqlm--async-busy
    (isqlm--async-cancel)
    (isqlm--output-error "Query cancelled.\n"))
  ;; Discard any pending multi-line input
  (setq isqlm-pending-input "")
  ;; Make the current input line visible as context (editable, Eshell-style)
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert "\n")
    (add-text-properties isqlm-last-output-end (1- (point))
                         '(rear-nonsticky (read-only) field input))
    (add-text-properties (1- (point)) (point)
                         '(read-only t rear-nonsticky (read-only) field input))
    (set-marker isqlm-last-output-end (point)))
  ;; Reset history navigation
  (setq isqlm-history-index nil)
  (setq isqlm-input-saved nil)
  ;; Show fresh prompt
  (isqlm--emit-prompt))

(defun isqlm-show-databases ()
  "Execute SHOW DATABASES."
  (interactive)
  (isqlm--quick-sql "SHOW DATABASES;"))

(defun isqlm-show-tables ()
  "Execute SHOW TABLES."
  (interactive)
  (isqlm--quick-sql "SHOW TABLES;"))

(defun isqlm-describe-table (table)
  "Execute DESCRIBE TABLE."
  (interactive "sTable name: ")
  (isqlm--quick-sql (format "DESCRIBE `%s`;" table)))

(defun isqlm--quick-sql (sql &optional silent)
  "Execute SQL directly via the async path.
Unless SILENT is non-nil, display the SQL command before the result."
  (unless (isqlm--connected-p)
    (user-error "Not connected to MySQL"))
  (unless silent
    (isqlm--output (concat sql "\n")))
  (setq isqlm--async-busy t)
  (isqlm--async-execute-statements
   (isqlm--split-statements sql) (current-buffer)))

;; ============================================================
;; Send from external buffers (à la sql-send-string)
;; ============================================================

(defvar isqlm-buffer nil
  "The ISQLM buffer to send SQL to.
Set this to direct `isqlm-send-string', `isqlm-send-region', etc.
to a specific ISQLM session.  Can also be set buffer-locally.")

(defun isqlm--target-buffer ()
  "Return the ISQLM buffer to send SQL to.
Check `isqlm-buffer' (buffer-local), then fall back to any live
`*isqlm*' buffer."
  (or (and isqlm-buffer
           (get-buffer isqlm-buffer)
           (buffer-live-p (get-buffer isqlm-buffer))
           (get-buffer isqlm-buffer))
      (let ((buf (get-buffer "*isqlm*")))
        (and buf (buffer-live-p buf) buf))
      (user-error "No ISQLM buffer found.  Start one with M-x isqlm")))

(defun isqlm-send-string (str)
  "Send STR as SQL to the ISQLM process buffer and display the result.
The target buffer is determined by `isqlm-buffer' or defaults to `*isqlm*'.
If STR does not end with `;' or `\\G', a `;' is appended automatically."
  (interactive "sSQL: ")
  (let* ((s (string-trim str))
         (buf (isqlm--target-buffer)))
    (when (string= s "")
      (user-error "Empty SQL string"))
    ;; Auto-append terminator if missing
    (unless (or (string-suffix-p ";" s)
                (string-suffix-p "\\G" s))
      (setq s (concat s ";")))
    (with-current-buffer buf
      (unless (isqlm--connected-p)
        (user-error "ISQLM buffer %s is not connected" (buffer-name buf)))
      (isqlm--quick-sql s))
    ;; Display the ISQLM buffer
    (display-buffer buf)))

(defun isqlm-send-region (start end)
  "Send the region between START and END to the ISQLM process buffer."
  (interactive "r")
  (isqlm-send-string (buffer-substring-no-properties start end)))

(defun isqlm-send-paragraph ()
  "Send the current paragraph to the ISQLM process buffer."
  (interactive)
  (let ((start (save-excursion (backward-paragraph) (point)))
        (end   (save-excursion (forward-paragraph) (point))))
    (isqlm-send-string (buffer-substring-no-properties start end))))

(defun isqlm-send-buffer ()
  "Send the entire buffer to the ISQLM process buffer."
  (interactive)
  (isqlm-send-string (buffer-substring-no-properties (point-min) (point-max))))

;; ============================================================
;; Execute SQL and display in a separate buffer
;; ============================================================

(defun isqlm-execute (sql &optional buf-name)
  "Execute SQL and display the result in a separate buffer.
BUF-NAME defaults to \"*isqlm-output*\".  The buffer uses `special-mode'
so that `q' dismisses it.

For SELECT results, the output is formatted as a table (or vertical
if SQL ends with `\\G').  For DML, the affected-rows summary is shown.

Returns the result plist from `isqlm-execute-string', so callers can
further process the data or post-process the output buffer.

This function must be called from an ISQLM buffer (or with the
ISQLM buffer current) so that `isqlm-execute-string' can find
the connection."
  (interactive "sSQL: ")
  (let* ((result (isqlm-execute-string sql))
         (parsed (isqlm--strip-terminator sql))
         (mode (cdr parsed))
         (text (isqlm--format-result-string result mode))
         (buf (get-buffer-create (or buf-name "*isqlm-output*"))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min)))
      (special-mode))
    (display-buffer buf)
    result))

;; ============================================================
;; Major mode (eshell-style: derived from fundamental-mode)
;; ============================================================

(define-derived-mode isqlm-mode fundamental-mode "ISQLM"
  "Major mode for interactively executing MySQL SQL statements.
No external processes — buffer, markers, prompt, and I/O are
managed directly, in the style of Eshell.

\\<isqlm-mode-map>
\\[isqlm-send-input] sends current input for execution.
SQL statements must end with `;' or `\\\\G'.
\\[newline] (M-RET) inserts a literal newline for multi-line input.

\\[isqlm-connect] connects to a MySQL server.
\\[isqlm-disconnect] disconnects.
\\[isqlm-reconnect] reconnects with last parameters.

\\[isqlm-previous-input] / \\[isqlm-next-input] navigate history.
\\[isqlm-clear-buffer] clears the buffer.
\\[isqlm-show-databases] / \\[isqlm-show-tables] / \\[isqlm-describe-table] for quick info.

Type `\\help' at the prompt for built-in commands.

\\{isqlm-mode-map}"
  :group 'isqlm
  ;; Prompt
  (setq isqlm-prompt-internal (or isqlm-prompt "SQL> "))
  (setq isqlm-pending-input "")
  (setq mode-line-process '(" [disconnected]"))
  (setq truncate-lines nil)
  ;; Markers
  (setq isqlm-last-input-start  (point-min-marker))
  (setq isqlm-last-input-end    (point-min-marker))
  (setq isqlm-last-output-start (point-min-marker))
  (setq isqlm-last-output-end   (point-min-marker))
  ;; Font-lock (case-insensitive)
  (setq-local font-lock-defaults '(isqlm-font-lock-keywords nil t))
  ;; History
  (isqlm--history-init)
  ;; isearch history support (Eshell-style M-r)
  (add-hook 'isearch-mode-hook #'isqlm--history-isearch-setup nil t)
  ;; Kill buffer hook
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when isqlm-connection
                (condition-case nil (mysql-close isqlm-connection) (error nil)))
              (isqlm--history-save))
            nil t)
  ;; Save history on Emacs exit
  (let ((buf (current-buffer)))
    (add-hook 'kill-emacs-hook
              (lambda ()
                (when (buffer-live-p buf)
                  (with-current-buffer buf
                    (isqlm--history-save))))))
  ;; Welcome header
  (let ((inhibit-read-only t))
    (insert (substitute-command-keys
             "*** Welcome to ISQLM — Interactive SQL Mode for MySQL ***\n\
Type \\[describe-mode] for help.\n\
Use `\\=\\connect' or \\[isqlm-connect] to connect.\n\
SQL statements must end with `;' or `\\=\\G'.  Press RET to execute.\n\
Type `\\=\\help' for built-in commands.\n\
Query mode: async (non-blocking)\n\n"))
    (add-text-properties (point-min) (point)
                         '(read-only t rear-nonsticky t field output
                           inhibit-line-move-field-capture t))
    (set-marker isqlm-last-output-end (point)))
  ;; Emit initial prompt
  (isqlm--emit-prompt))

;; ============================================================
;; Entry point
;; ============================================================

;;;###autoload
(defun isqlm (&optional buf-name)
  "Start an interactive SQL session for MySQL.
Switches to buffer BUF-NAME (`*isqlm*' by default) or creates it."
  (interactive)
  (isqlm--ensure-module)
  (let* ((buf-name (or buf-name "*isqlm*"))
         (buf (get-buffer buf-name)))
    (unless (and buf (buffer-live-p buf))
      (setq buf (get-buffer-create buf-name))
      (with-current-buffer buf
        (isqlm-mode)))
    (setq isqlm-buffer buf)
    (pop-to-buffer-same-window buf)))

;;;###autoload
(defun isqlm-connect-and-run (&optional host user database port)
  "Start ISQLM and immediately connect."
  (interactive)
  (isqlm)
  (isqlm-connect host user database port))

;;;###autoload
(defun isqlm-sql-connect (connection)
  "Start ISQLM and connect using CONNECTION from `sql-connection-alist'.
When called interactively, prompt with completion for the connection name."
  (interactive
   (list
    (let ((names (and (boundp 'sql-connection-alist)
                      (mapcar #'car sql-connection-alist))))
      (unless names
        (user-error "sql-connection-alist is empty or not defined"))
      (completing-read "Connection: " names nil t))))
  (isqlm (format "*isqlm: <%s>*" connection))
  (unless (isqlm--connected-p)
    (isqlm/connect connection)
    (isqlm--emit-prompt)))

(provide 'isqlm)

;;; isqlm.el ends here
