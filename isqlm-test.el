;;; isqlm-test.el --- Unit tests for isqlm  -*- lexical-binding: t -*-

;;; Commentary:
;; Run with: emacs -batch -l isqlm.el -l isqlm-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'isqlm)

;; ============================================================
;; Helper: create an isqlm buffer for testing (no mysql module needed)
;; ============================================================

(defmacro isqlm-test-with-buffer (&rest body)
  "Execute BODY in a temporary isqlm-mode buffer.
Sets up markers and variables without requiring mysql-el module."
  `(with-temp-buffer
     (let ((isqlm-prompt-internal "SQL> ")
           (isqlm-prompt-continue "  -> ")
           (isqlm-pending-input "")
           (isqlm-cond-stack nil)
           (isqlm-for-stack nil)
           (isqlm-history-ring (make-ring 64))
           (isqlm-history-index nil)
           (isqlm-input-saved nil)
           (isqlm-connection nil)
           (isqlm-connection-info nil)
           (isqlm-last-query nil)
           (isqlm-last-result nil)
           (isqlm-last-input-start (point-min-marker))
           (isqlm-last-input-end (point-min-marker))
           (isqlm-last-output-start (point-min-marker))
           (isqlm-last-output-end (point-min-marker)))
       ,@body)))

(defmacro isqlm-test-with-dynvars (bindings &rest body)
  "Bind dynamic variables for testing, clean up afterward.
BINDINGS is ((sym val) ...).  Uses `set' so `boundp'/`symbol-value' work."
  (declare (indent 1))
  (let ((syms (mapcar #'car bindings)))
    `(progn
       ,@(mapcar (lambda (b) `(set ',(car b) ,(cadr b))) bindings)
       (unwind-protect
           (progn ,@body)
         ,@(mapcar (lambda (s) `(makunbound ',s)) syms)))))

;; ============================================================
;; SQL Parsing
;; ============================================================

(ert-deftest isqlm-test-sql-complete-p ()
  "Test SQL completeness detection."
  (should (isqlm--sql-complete-p "SELECT 1;"))
  (should (isqlm--sql-complete-p "SELECT 1\\G"))
  (should (isqlm--sql-complete-p "SELECT 1\\gset"))
  (should (isqlm--sql-complete-p "SELECT 1\\gset prefix"))
  (should (isqlm--sql-complete-p "SELECT 1;\\gset p"))
  (should (isqlm--sql-complete-p ""))
  (should-not (isqlm--sql-complete-p "SELECT 1"))
  (should-not (isqlm--sql-complete-p "SELECT * FROM")))

(ert-deftest isqlm-test-strip-terminator ()
  "Test SQL terminator stripping."
  (should (equal (isqlm--strip-terminator "SELECT 1;")
                 '("SELECT 1" . nil)))
  (should (equal (isqlm--strip-terminator "SELECT 1\\G")
                 '("SELECT 1" . t)))
  (let ((result (isqlm--strip-terminator "SELECT 1\\gset")))
    (should (equal (car result) "SELECT 1"))
    (should (equal (cadr (cdr result)) "")))
  (let ((result (isqlm--strip-terminator "SELECT 1\\gset prefix")))
    (should (equal (car result) "SELECT 1"))
    (should (equal (cadr (cdr result)) "prefix")))
  (let ((result (isqlm--strip-terminator "SELECT 1;\\gset p")))
    (should (equal (car result) "SELECT 1"))
    (should (equal (cadr (cdr result)) "p"))))

(ert-deftest isqlm-test-split-statements ()
  "Test multi-statement splitting."
  (should (equal (isqlm--split-statements "SELECT 1;")
                 '("SELECT 1;")))
  (should (equal (isqlm--split-statements "SELECT 1; SELECT 2;")
                 '("SELECT 1;" "SELECT 2;")))
  ;; Don't split inside strings
  (should (equal (isqlm--split-statements "SELECT 'a;b';")
                 '("SELECT 'a;b';")))
  ;; \G as terminator
  (should (equal (isqlm--split-statements "SELECT 1\\G")
                 '("SELECT 1\\G")))
  ;; \gset should not be split as \G
  (should (equal (length (isqlm--split-statements "SELECT 1\\gset p"))
                 1))
  ;; ;\gset should be one statement
  (should (equal (length (isqlm--split-statements "SELECT 1;\\gset p"))
                 1)))

;; ============================================================
;; Conditional Flow - Truthy/Falsy
;; ============================================================

(ert-deftest isqlm-test-cond-falsy-value-p ()
  "Test falsy value detection."
  (should (isqlm--cond-falsy-value-p nil))
  (should (isqlm--cond-falsy-value-p 0))
  (should (isqlm--cond-falsy-value-p 0.0))
  (should (isqlm--cond-falsy-value-p ""))
  (should (isqlm--cond-falsy-value-p "0"))
  (should (isqlm--cond-falsy-value-p "false"))
  (should (isqlm--cond-falsy-value-p "FALSE"))
  (should (isqlm--cond-falsy-value-p "no"))
  (should (isqlm--cond-falsy-value-p "nil"))
  (should (isqlm--cond-falsy-value-p "off"))
  (should-not (isqlm--cond-falsy-value-p 1))
  (should-not (isqlm--cond-falsy-value-p "hello"))
  (should-not (isqlm--cond-falsy-value-p "yes"))
  (should-not (isqlm--cond-falsy-value-p t)))

(ert-deftest isqlm-test-cond-truthy-p-literal ()
  "Test truthy check with literal values."
  (should (isqlm--cond-truthy-p "yes"))
  (should (isqlm--cond-truthy-p "true"))
  (should (isqlm--cond-truthy-p "1"))
  (should (isqlm--cond-truthy-p "hello"))
  (should-not (isqlm--cond-truthy-p "0"))
  (should-not (isqlm--cond-truthy-p "false"))
  (should-not (isqlm--cond-truthy-p "no"))
  (should-not (isqlm--cond-truthy-p "nil"))
  (should-not (isqlm--cond-truthy-p "off"))
  (should-not (isqlm--cond-truthy-p ""))
  (should-not (isqlm--cond-truthy-p nil)))

(ert-deftest isqlm-test-cond-truthy-p-variable ()
  "Test truthy check with :varname references."
  (isqlm-test-with-dynvars ((isqlm-test-var-truthy 42)
                            (isqlm-test-var-zero 0)
                            (isqlm-test-var-nil nil)
                            (isqlm-test-var-str "hello"))
    (should (isqlm--cond-truthy-p ":isqlm-test-var-truthy"))
    (should (isqlm--cond-truthy-p ":isqlm-test-var-str"))
    (should-not (isqlm--cond-truthy-p ":isqlm-test-var-zero"))
    (should-not (isqlm--cond-truthy-p ":isqlm-test-var-nil"))))

(ert-deftest isqlm-test-cond-truthy-p-elisp ()
  "Test truthy check with Elisp expressions."
  (should (isqlm--cond-truthy-p "(> 3 1)"))
  (should-not (isqlm--cond-truthy-p "(> 1 3)"))
  (should (isqlm--cond-truthy-p "(string= \"a\" \"a\")"))
  (should-not (isqlm--cond-truthy-p "(string= \"a\" \"b\")")))

(ert-deftest isqlm-test-cond-truthy-p-elisp-with-varref ()
  "Test truthy check with :varname inside Elisp expressions.
This is the bug that caused \\if to not work in scripts."
  (isqlm-test-with-dynvars ((isqlm-test-val 30))
    (should-not (isqlm--cond-truthy-p "(> :isqlm-test-val 100)"))
    (should (isqlm--cond-truthy-p "(> :isqlm-test-val 10)")))
  (isqlm-test-with-dynvars ((isqlm-test-val 200))
    (should (isqlm--cond-truthy-p "(> :isqlm-test-val 100)"))))

;; ============================================================
;; Conditional Flow - Stack Operations
;; ============================================================

(ert-deftest isqlm-test-if-else-endif ()
  "Test basic \\if / \\else / \\endif stack operations."
  (isqlm-test-with-buffer
   ;; Initially active
   (should (isqlm--cond-active-p))
   ;; \if true
   (isqlm/if "yes")
   (should (isqlm--cond-active-p))
   (isqlm/endif)
   (should (isqlm--cond-active-p))
   ;; \if false, \else
   (isqlm/if "0")
   (should-not (isqlm--cond-active-p))
   (isqlm/else)
   (should (isqlm--cond-active-p))
   (isqlm/endif)
   (should (isqlm--cond-active-p))))

(ert-deftest isqlm-test-if-elif ()
  "Test \\if / \\elif chain — only first true branch is active."
  (isqlm-test-with-buffer
   (isqlm/if "0")
   (should-not (isqlm--cond-active-p))
   (isqlm/elif "yes")
   (should (isqlm--cond-active-p))
   (isqlm/elif "yes")
   ;; Second true elif should NOT be active (first already satisfied)
   (should-not (isqlm--cond-active-p))
   (isqlm/endif)))

(ert-deftest isqlm-test-nested-if ()
  "Test nested \\if blocks."
  (isqlm-test-with-buffer
   (isqlm/if "yes")
   (should (isqlm--cond-active-p))
   (isqlm/if "0")
   (should-not (isqlm--cond-active-p))
   (isqlm/endif)
   ;; Back to outer (active)
   (should (isqlm--cond-active-p))
   (isqlm/endif)))

;; ============================================================
;; Conditional Flow in Scripts (the bug scenario)
;; ============================================================

(ert-deftest isqlm-test-script-if-else ()
  "Test that \\if/\\else/\\endif works correctly in isqlm--execute-script.
This is a regression test for the bug where \\if was ignored in scripts."
  (isqlm-test-with-buffer
   (let (output)
     ;; Capture output
     (cl-letf (((symbol-function 'isqlm--output)
                (lambda (s) (push s output)))
               ((symbol-function 'isqlm--output-info)
                (lambda (s) (push s output)))
               ((symbol-function 'isqlm--output-error)
                (lambda (s) (push (concat "ERR:" s) output))))
       ;; Script: \if true branch — use \setq which calls (set) internally
       (setq output nil)
       (isqlm--execute-script
        (concat "\\setq isqlm-test-x 1\n"
                "\\if :isqlm-test-x\n"
                "\\echo yes-branch\n"
                "\\else\n"
                "\\echo no-branch\n"
                "\\endif\n"))
       (let ((text (mapconcat #'identity (nreverse output) "")))
         (should (string-match-p "yes-branch" text))
         (should-not (string-match-p "no-branch" text)))

       ;; Script: \if false branch → \else
       (setq output nil)
       (isqlm--execute-script
        (concat "\\setq isqlm-test-x 0\n"
                "\\if :isqlm-test-x\n"
                "\\echo yes-branch\n"
                "\\else\n"
                "\\echo no-branch\n"
                "\\endif\n"))
       (let ((text (mapconcat #'identity (nreverse output) "")))
         (should-not (string-match-p "yes-branch" text))
         (should (string-match-p "no-branch" text))))
     (makunbound 'isqlm-test-x))))

(ert-deftest isqlm-test-script-if-elisp-varref ()
  "Test \\if with Elisp expression containing :varname in scripts.
Regression test: :varname was not expanded before eval."
  (isqlm-test-with-buffer
   (let (output)
     (cl-letf (((symbol-function 'isqlm--output)
                (lambda (s) (push s output)))
               ((symbol-function 'isqlm--output-info)
                (lambda (s) (push s output)))
               ((symbol-function 'isqlm--output-error)
                (lambda (s) (push (concat "ERR:" s) output))))
       (set (intern "pa") 30)
       (setq output nil)
       (isqlm--execute-script
        (concat "\\if (> :pa 100)\n"
                "\\echo greater\n"
                "\\else\n"
                "\\echo lesser\n"
                "\\endif\n"))
       (let ((text (mapconcat #'identity (nreverse output) "")))
         (should (string-match-p "lesser" text))
         (should-not (string-match-p "greater" text)))

       ;; Now with pa > 100
       (set (intern "pa") 200)
       (setq output nil)
       (isqlm--execute-script
        (concat "\\if (> :pa 100)\n"
                "\\echo greater\n"
                "\\else\n"
                "\\echo lesser\n"
                "\\endif\n"))
       (let ((text (mapconcat #'identity (nreverse output) "")))
         (should (string-match-p "greater" text))
         (should-not (string-match-p "lesser" text))))
     (makunbound 'pa))))

;; ============================================================
;; Command Parsing
;; ============================================================

(ert-deftest isqlm-test-parse-command-line ()
  "Test command line parsing with quoted strings."
  (should (equal (isqlm--parse-command-line "\\echo hello")
                 '("\\echo" "hello")))
  (should (equal (isqlm--parse-command-line "\\echo \"hello world\"")
                 '("\\echo" "hello world")))
  (should (equal (isqlm--parse-command-line "\\connect host user pass db 3306")
                 '("\\connect" "host" "user" "pass" "db" "3306")))
  (should (equal (isqlm--parse-command-line "\\setq myvar \"hello world\"")
                 '("\\setq" "myvar" "hello world"))))

;; ============================================================
;; Variable Expansion
;; ============================================================

(ert-deftest isqlm-test-expand-arg ()
  "Test argument expansion with :varname and numeric coercion."
  (isqlm-test-with-dynvars ((isqlm-test-var "hello"))
    (should (equal (isqlm--expand-arg ":isqlm-test-var") "hello")))
  (should (equal (isqlm--expand-arg "42") 42))
  (should (equal (isqlm--expand-arg "3.14") 3.14))
  (should (equal (isqlm--expand-arg "hello") "hello")))

(ert-deftest isqlm-test-expand-sql-variables ()
  "Test SQL variable expansion with :var and ::var."
  (isqlm-test-with-dynvars ((isqlm-test-name "O'Brien")
                            (isqlm-test-id 42)
                            (isqlm-test-tbl "users"))
    ;; :var → quoted
    (should (equal (isqlm--expand-sql-variables "WHERE name = :isqlm-test-name")
                   "WHERE name = 'O''Brien'"))
    ;; :var → number literal
    (should (equal (isqlm--expand-sql-variables "WHERE id = :isqlm-test-id")
                   "WHERE id = 42"))
    ;; ::var → raw (unquoted)
    (should (equal (isqlm--expand-sql-variables "FROM ::isqlm-test-tbl")
                   "FROM users"))
    ;; Inside single quotes — no expansion
    (should (equal (isqlm--expand-sql-variables "SELECT ':isqlm-test-name'")
                   "SELECT ':isqlm-test-name'")))
  ;; nil → NULL
  (isqlm-test-with-dynvars ((isqlm-test-null nil))
    (should (equal (isqlm--expand-sql-variables "SET x = :isqlm-test-null")
                   "SET x = NULL"))))

(ert-deftest isqlm-test-expand-expr-variables ()
  "Test :varname expansion inside Elisp expression strings."
  (isqlm-test-with-dynvars ((isqlm-test-val 30))
    (should (equal (isqlm--expand-expr-variables "(> :isqlm-test-val 100)")
                   "(> 30 100)"))
    (should (equal (isqlm--expand-expr-variables "(+ :isqlm-test-val 10)")
                   "(+ 30 10)")))
  (isqlm-test-with-dynvars ((isqlm-test-str "hello"))
    (should (equal (isqlm--expand-expr-variables "(string= :isqlm-test-str \"world\")")
                   "(string= \"hello\" \"world\")"))))

;; ============================================================
;; Command Aliases
;; ============================================================

(ert-deftest isqlm-test-command-aliases ()
  "Test that aliases resolve correctly."
  (should (equal (cdr (assoc "?" isqlm-command-aliases)) "help"))
  (should (equal (cdr (assoc "h" isqlm-command-aliases)) "help"))
  (should (equal (cdr (assoc "q" isqlm-command-aliases)) "quit"))
  (should (equal (cdr (assoc "u" isqlm-command-aliases)) "use"))
  (should (equal (cdr (assoc "." isqlm-command-aliases)) "i")))

;; ============================================================
;; Conditional Flow Command Detection
;; ============================================================

(ert-deftest isqlm-test-cond-flow-command-p ()
  "Test conditional flow command detection."
  (should (isqlm--cond-flow-command-p "\\if yes"))
  (should (isqlm--cond-flow-command-p "\\elif :var"))
  (should (isqlm--cond-flow-command-p "\\else"))
  (should (isqlm--cond-flow-command-p "\\endif"))
  (should-not (isqlm--cond-flow-command-p "\\echo hello"))
  (should-not (isqlm--cond-flow-command-p "SELECT 1;"))
  (should-not (isqlm--cond-flow-command-p "\\connect")))

;; ============================================================
;; Display Width
;; ============================================================

(ert-deftest isqlm-test-display-width ()
  "Test display width calculation for multi-line strings."
  (should (= (isqlm--display-width "hello") 5))
  (should (= (isqlm--display-width "hello\nworld!") 6))
  (should (= (isqlm--display-width "a\nbb\nccc") 3))
  (should (= (isqlm--display-width "") 0)))

;; ============================================================
;; Error Message Extraction
;; ============================================================

(ert-deftest isqlm-test-error-message ()
  "Test error message extraction from different error formats."
  ;; mysql-el style: (error . "plain string")
  (should (equal (isqlm--error-message '(error . "connection failed"))
                 "connection failed"))
  ;; Standard Emacs style: (error "format" args...)
  (should (equal (isqlm--error-message '(error "got %d errors" 3))
                 "got 3 errors"))
  ;; Single format string
  (should (equal (isqlm--error-message '(error "simple error"))
                 "simple error")))

;;; isqlm-test.el ends here
