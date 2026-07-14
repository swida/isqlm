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
           (isqlm-for-bindings nil)
           (isqlm-history-ring (make-ring 64))
           (isqlm-history-index nil)
           (isqlm-input-saved nil)
           (isqlm-connection nil)
           (isqlm-connection-info nil)
           (isqlm-last-query nil)
           (isqlm-last-result nil)
           (isqlm-delimiter ";")
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

(ert-deftest isqlm-test-for-find-matching-brace ()
  "Test brace matching for \\for value/body source parsing."
  ;; simple
  (should (= (isqlm--for-find-matching-brace "{abc}" 0) 4))
  ;; nested
  (should (= (isqlm--for-find-matching-brace "{a{b}c}" 0) 6))
  ;; braces inside single-quoted string are ignored
  (should (= (isqlm--for-find-matching-brace "{sel '}' x}" 0) 10))
  ;; braces inside backticks ignored
  (should (= (isqlm--for-find-matching-brace "{`a}b` c}" 0) 8))
  ;; unterminated
  (should (null (isqlm--for-find-matching-brace "{abc" 0))))

(ert-deftest isqlm-test-for-loop-var-expansion ()
  "Loop-bound vars resolve via `isqlm-for-bindings' and expand raw in SQL.
Also verifies that constant names like `t' can be used as loop vars."
  (isqlm-test-with-buffer
    (setf (alist-get 't isqlm-for-bindings) "sqlsmith_test_t1")
    ;; :t in SQL expands raw (no quoting), even for the constant `t'
    (should (equal (isqlm--expand-sql-variables "analyze table :t")
                   "analyze table sqlsmith_test_t1"))
    ;; ::t also raw
    (should (equal (isqlm--expand-sql-variables "analyze table ::t")
                   "analyze table sqlsmith_test_t1"))
    ;; :t as a command argument expands to the raw value
    (should (equal (isqlm--expand-arg ":t") "sqlsmith_test_t1"))))

(ert-deftest isqlm-test-for-parse-values ()
  "Test parsing of the value source and body-spec in \\for."
  (isqlm-test-with-buffer
    ;; literal values, inline body
    (let ((r (isqlm--for-parse-values "a b c { select :x; }")))
      (should (equal (car r) '("a" "b" "c")))
      (should (equal (cdr r) "{ select :x; }")))
    ;; elisp source
    (let ((r (isqlm--for-parse-values "(list 1 2 3) { select :x; }")))
      (should (equal (car r) '("1" "2" "3")))
      (should (equal (cdr r) "{ select :x; }")))
    ;; {SQL} source — stub isqlm-execute-string
    (cl-letf (((symbol-function 'isqlm-execute-string)
               (lambda (sql)
                 (should (equal sql
                                "select table_name from information_schema.tables"))
                 '(:type select :columns ("table_name")
                         :rows (("t1") ("t2"))))))
      (let ((r (isqlm--for-parse-values
                "{select table_name from information_schema.tables;} { analyze table :t; }")))
        (should (equal (car r) '("t1" "t2")))
        (should (equal (cdr r) "{ analyze table :t; }"))))))

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
                 "simple error"))
  ;; mysql-error signal: (mysql-error ERRNO SQLSTATE ERRMSG)
  (should (equal (isqlm--error-message '(mysql-error 1690 "22003" "BIGINT value is out of range"))
                 "ERROR 1690 (22003): BIGINT value is out of range"))
  (should (equal (isqlm--error-message '(mysql-error 2003 "HY000" "Can't connect to MySQL server"))
                 "ERROR 2003 (HY000): Can't connect to MySQL server"))
  ;; mysql-error-p predicate
  (should (isqlm--mysql-error-p '(mysql-error 1690 "22003" "msg")))
  (should-not (isqlm--mysql-error-p '(error . "msg")))
  ;; Accessors
  (let ((err '(mysql-error 1690 "22003" "BIGINT overflow")))
    (should (= (isqlm--mysql-error-errno err) 1690))
    (should (equal (isqlm--mysql-error-sqlstate err) "22003"))
    (should (equal (isqlm--mysql-error-errmsg err) "BIGINT overflow"))))

;; ============================================================
;; Delimiter
;; ============================================================

(ert-deftest isqlm-test-delimiter-directive-p ()
  "Test DELIMITER directive recognition."
  ;; Basic
  (should (equal (isqlm--delimiter-directive-p "DELIMITER //") "//"))
  (should (equal (isqlm--delimiter-directive-p "delimiter //") "//"))
  (should (equal (isqlm--delimiter-directive-p "Delimiter $$") "$$"))
  ;; Reset
  (should (equal (isqlm--delimiter-directive-p "DELIMITER ;") ";"))
  (should (equal (isqlm--delimiter-directive-p "DELIMITER") ";"))
  ;; Not a DELIMITER directive
  (should-not (isqlm--delimiter-directive-p "SELECT 1;"))
  (should-not (isqlm--delimiter-directive-p "DELIMITER_X"))
  (should-not (isqlm--delimiter-directive-p "CREATE TABLE delimiter_log (id INT);")))

(ert-deftest isqlm-test-sql-complete-custom-delimiter ()
  "Test isqlm--sql-complete-p with custom delimiter."
  (let ((isqlm-delimiter "//"))
    ;; Complete with custom delimiter
    (should (isqlm--sql-complete-p "END //"))
    (should (isqlm--sql-complete-p "SELECT 1//"))
    ;; Not complete with ;
    (should-not (isqlm--sql-complete-p "SELECT 1;"))
    ;; Not complete without delimiter
    (should-not (isqlm--sql-complete-p "BEGIN"))
    ;; Empty is always complete
    (should (isqlm--sql-complete-p ""))))

(ert-deftest isqlm-test-split-statements-custom-delimiter ()
  "Test statement splitting with custom delimiter."
  (let ((isqlm-delimiter "//"))
    ;; Single statement
    (should (equal (isqlm--split-statements "SELECT 1//")
                   '("SELECT 1//")))
    ;; Multiple statements
    (should (equal (isqlm--split-statements "SELECT 1// SELECT 2//")
                   '("SELECT 1//" "SELECT 2//")))
    ;; Semicolons inside body are NOT split points
    (should (equal (length (isqlm--split-statements
                            "CREATE PROCEDURE p1()\nBEGIN\n  SELECT 1;\nEND //"))
                   1))
    ;; Don't split inside strings
    (should (equal (length (isqlm--split-statements
                            "SELECT '//'; SELECT 2//"))
                   ;; With custom delimiter, ; is NOT a split point;
                   ;; '//' inside quotes is skipped; trailing // is the
                   ;; only delimiter, so it's one statement
                   1))))

(ert-deftest isqlm-test-strip-terminator-custom-delimiter ()
  "Test isqlm--strip-terminator with custom delimiter."
  (let ((isqlm-delimiter "//"))
    (should (equal (isqlm--strip-terminator "END //")
                   '("END" . nil)))
    (should (equal (isqlm--strip-terminator "SELECT 1//")
                   '("SELECT 1" . nil)))))

;; ============================================================
;; Generate DDL/DML
;; ============================================================

(ert-deftest isqlm-test-genddl-extract-tables-from-sql ()
  "Test table name extraction from SQL text."
  ;; Simple single table
  (should (equal (isqlm--genddl-extract-tables-from-sql "SELECT * FROM t1")
                 '("t1")))
  ;; Table with alias (AS)
  (should (equal (isqlm--genddl-extract-tables-from-sql "SELECT * FROM users AS u")
                 '("users")))
  ;; Table with implicit alias
  (should (equal (isqlm--genddl-extract-tables-from-sql "SELECT * FROM users u")
                 '("users")))
  ;; Multiple tables via JOIN
  (let ((tables (isqlm--genddl-extract-tables-from-sql
                 "SELECT * FROM t1 a JOIN t2 b ON a.id = b.t1_id")))
    (should (= (length tables) 2))
    (should (member "t1" tables))
    (should (member "t2" tables)))
  ;; Comma-separated FROM list
  (let ((tables (isqlm--genddl-extract-tables-from-sql
                 "SELECT * FROM t1, t2, t3 WHERE t1.id = t2.id")))
    (should (= (length tables) 3))
    (should (member "t1" tables))
    (should (member "t2" tables))
    (should (member "t3" tables)))
  ;; Backtick-quoted table
  (should (equal (isqlm--genddl-extract-tables-from-sql "SELECT * FROM `my_table`")
                 '("my_table")))
  ;; Schema-qualified table
  (should (equal (isqlm--genddl-extract-tables-from-sql "SELECT * FROM mydb.users u")
                 '("users")))
  ;; Subquery should not produce false table names
  (should (equal (isqlm--genddl-extract-tables-from-sql
                 "SELECT * FROM (SELECT * FROM t1) sub JOIN t2 ON sub.id = t2.id")
                 '("t1" "t2")))
  ;; UPDATE statement
  (should (equal (isqlm--genddl-extract-tables-from-sql "UPDATE orders SET status = 1")
                 '("orders")))
  ;; INSERT INTO
  (should (equal (isqlm--genddl-extract-tables-from-sql "INSERT INTO logs VALUES (1, 'x')")
                 '("logs")))
  ;; LEFT JOIN, RIGHT JOIN
  (let ((tables (isqlm--genddl-extract-tables-from-sql
                 "SELECT * FROM t1 LEFT JOIN t2 ON t1.a = t2.a RIGHT JOIN t3 ON t2.b = t3.b")))
    (should (= (length tables) 3))
    (should (member "t1" tables))
    (should (member "t2" tables))
    (should (member "t3" tables)))
  ;; Deduplication
  (should (equal (isqlm--genddl-extract-tables-from-sql
                 "SELECT * FROM t1 JOIN t1 ON t1.a = t1.b")
                 '("t1"))))

(ert-deftest isqlm-test-genddl-parse-columns-from-ddl ()
  "Test parsing columns from a real CREATE TABLE DDL."
  (let* ((ddl "CREATE TABLE `t3` (\n  `a` int DEFAULT NULL,\n  `b` int DEFAULT NULL,\n  `c` int DEFAULT NULL,\n  KEY `a` (`a`,`b`)\n) ENGINE=InnoDB")
         (cols (isqlm--genddl-parse-columns-from-ddl ddl)))
    (should (= (length cols) 3))
    (should (equal (car (nth 0 cols)) "a"))
    (should (equal (cdr (nth 0 cols)) "int"))
    (should (equal (car (nth 1 cols)) "b"))
    (should (equal (car (nth 2 cols)) "c"))))

(ert-deftest isqlm-test-genddl-format-value ()
  "Test value formatting respects column types."
  ;; int columns: no quotes
  (should (equal (isqlm--genddl-format-value "42" "int") "42"))
  (should (equal (isqlm--genddl-format-value "0" "bigint") "0"))
  (should (equal (isqlm--genddl-format-value "3.14" "decimal(10,2)") "3.14"))
  ;; string columns: quoted
  (should (equal (isqlm--genddl-format-value "hello" "varchar(255)") "'hello'"))
  (should (equal (isqlm--genddl-format-value "it's" "varchar(255)") "'it''s'"))
  ;; NULL
  (should (equal (isqlm--genddl-format-value nil "int") "NULL"))
  (should (equal (isqlm--genddl-format-value nil "varchar(50)") "NULL")))

;; ============================================================
;; Placement tests
;; ============================================================

(ert-deftest isqlm-test-placement-parse-target ()
  "Test parsing of placement target strings."
  ;; Single name → current db + table
  (let ((isqlm-connection-info '(:database "mydb")))
    (should (equal (isqlm--placement-parse-target "t1")
                   '(:db "mydb" :table "t1" :partition nil))))
  ;; db.table
  (let ((isqlm-connection-info '(:database "mydb")))
    (should (equal (isqlm--placement-parse-target "test.t1")
                   '(:db "test" :table "t1" :partition nil))))
  ;; db.table.partition
  (let ((isqlm-connection-info '(:database "mydb")))
    (should (equal (isqlm--placement-parse-target "test.t1.p0")
                   '(:db "test" :table "t1" :partition "p0"))))
  ;; table.partition (partition starts with p + digit)
  (let ((isqlm-connection-info '(:database "mydb")))
    (should (equal (isqlm--placement-parse-target "t1.p3")
                   '(:db "mydb" :table "t1" :partition "p3")))))

(ert-deftest isqlm-test-placement-resolve-node ()
  "Test node resolution from hints."
  (let ((nodes '("node-1-002" "node-1-003" "node-1-001")))
    ;; Exact match
    (should (equal (isqlm--placement-resolve-node "node-1-002" nodes)
                   "node-1-002"))
    ;; Case-insensitive
    (should (equal (isqlm--placement-resolve-node "Node-1-003" nodes)
                   "node-1-003"))
    ;; Index-based
    (should (equal (isqlm--placement-resolve-node "0" nodes) "node-1-002"))
    (should (equal (isqlm--placement-resolve-node "2" nodes) "node-1-001"))
    ;; Suffix match (non-numeric to avoid index priority)
    (should (equal (isqlm--placement-resolve-node "1-002" nodes) "node-1-002"))
    ;; Error on unknown
    (should-error (isqlm--placement-resolve-node "unknown" nodes))))

;;; isqlm-test.el ends here
