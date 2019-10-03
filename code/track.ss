;;;; Main track tooling

;;; Config

;; output config.json from code/config.ss
(define (make-config)
  (let ((config.json "config.json"))
    (when (file-exists? config.json)
      (delete-file config.json))
    (with-output-to-file config.json
      (lambda ()
        (json-write (process-config) 'pretty)))))

;; Top level helper for make-config
(define (process-config)
  (map (lambda (x)
         (if (not (eq? (car x) 'exercises))
             x
             (cons 'exercises
                   (exercises->snake-case
                    (remp (lambda (exercise)
                            (memq 'wip (map car exercise)))
                          (cdr x))))))
       track-config))

;; Check problem's entry in config for uuid and existence
(define (check-config-for problem)
  (format #t "checking config for ~a~%" problem)
  (let ((exercisms (lookup 'exercises track-config)))
    (cond ((find (lambda (exercism)
		   (eq? problem (lookup 'slug exercism)))
		 exercisms)
	   =>
	   (lambda (config)
	     (unless (assoc 'uuid config)
	       (error 'check-config-for
		      "please set uuid"
		      problem))))
	  (else (error 'check-config-for
		       "please add problem to config/config.ss"
		       problem)))))

;;; UUID

;; wrapper to read uuid generated by configlet from scheme
(define (configlet-uuid)
  (let ((from-to-pid (process "./bin/configlet uuid")))
    (let ((fresh-uuid (read (car from-to-pid))))
      (close-port (car from-to-pid))
      (close-port (cadr from-to-pid))
      (symbol->string fresh-uuid))))

;;; Problem Specifications

;; fetch the files in the given problem's directory
(define (get-problem-specification problem)
  (let* ((problem-dir (format "../problem-specifications/exercises/~a" problem))
         (spec (directory-list problem-dir)))
    (map (lambda (file)
           (format "~a/~a" problem-dir file))
         spec)))

;; fetches the README.md file for a given problem
;; nb: likely be replaced by sxml configuration
(define (write-problem-description problem)
  (let ((file (find (lambda (spec)
                      (string=? "md" (path-extension spec)))
                    (get-problem-specification problem)))
        (dir (format "code/exercises/~a" problem)))
    (unless file
      (error 'get-problem-description "couldn't find description" problem))
    (system (format "mkdir -p ~a && cp ~a ~a/README.md"
                    dir file dir))))

;; reads the test specification for a given problem
(define (get-test-specification problem)
  (let ((test-suite-file (find (lambda (spec)
                                 (string=? "json" (path-extension spec)))
                               (get-problem-specification problem))))
    (unless test-suite-file
      (error 'get-test-specification "couldn't find test suite for" problem))
    (with-input-from-file test-suite-file json-read)))

;; list all the problems in the problem-specifications directory
(define (get-problem-list)
  (map string->symbol
       (directory-list "../problem-specifications/exercises")))

;;; Test suite

;; read the code/test.ss file as s-expressions
(define *test-definitions*
  (with-input-from-file "code/test.ss" read-all))

;;; Problem Implementations

(define (load-problem problem)
  (load (format "code/exercises/~a/test.ss" problem)))

;; table to hold problem implementations
(define *problem-table*
  (make-hash-table))

;; log a problem and its implementation to the problem table. The
;; implementation is specified as an association list with tests, and
;; file paths to the problem skeleton and the problem example
;; solution.
(define (put-problem! problem implementation)
  (for-each (lambda (aspect)
              (unless (assoc aspect implementation)
                (error 'put-test! "problem does not implement" problem aspect)))
            ;; test is an sexpression. skeleton and solution are file paths
            '(test skeleton solution))
  (hashtable-set! *problem-table* problem implementation))

;; look up the problem in the problem table.
(define (get-problem problem)
  (let ((implementation (hashtable-ref *problem-table* problem #f)))
    (or implementation
	(begin
	  (load-problem problem)
	  (let ((implementation (hashtable-ref *problem-table* problem #f)))
	    (unless implementation
	      (error 'get-problem "no implementation" problem))
	    implementation)))))

;;; Stubbing, Building, and Testing problems

;; Read the problem-specifications directory and generate a stub
;; implementation. TODO. when the problem is not there, generate a
;; stub anyway without the readme.
(define (stub-exercism problem)
  (format #t "setting up ~a~%" problem)
  (let* ((dir (format "code/exercises/~a" problem))
	 (implementation (format "~a/test.ss" dir))
         ;; todo, add "properties" found in spec to stub skeleton and solution
         (skeleton (format "~a/~a.scm" dir problem))
         (solution (format "~a/example.scm" dir))
         ;; see code/exercises/anagram/anagram.ss for more information
         (stub-implementation
          `(,@'((define (parse-test test)
                  `(lambda ()
                     (test-success (lookup 'description test)
                                   equal?
                                   problem
                                   (lookup 'input test)
                                   (lookup 'expected test))))
                (define (spec->tests spec)
                  `(,@*test-definitions*
                    (define (test . args)
		      (apply run-test-suite
			     (list ,@(map parse-test (lookup 'cases spec)))
			     args)))))
	    (put-problem! ',problem
			  ;; fixme, quoted expression for test not working
			  `((test . ,(spec->tests
				      (get-test-specification ',problem)))
			    (skeleton . ,,(path-last skeleton))
			    (solution . ,,(path-last solution))))))
	 (stub-solution `((import (rnrs (6)))
			  (load "test.scm")
			  (define (,problem)
			    'implement-me!))))
    (when (file-exists? implementation)
      (error 'setup-exercism "implementation already exists" problem))
    (system (format "mkdir -p ~a" dir))
    ;;    (format #t "~~ getting description~%")
    ;;    (write-problem-description problem)
    (format #t "~~ writing stub implementation~%")
    (write-expression-to-file stub-implementation implementation)
    (format #t "~~ writing stub solution~%")
    (write-expression-to-file stub-solution skeleton)
    (format #t "~~ writing stub skeleton~%")
    (write-expression-to-file stub-solution solution)))

;; write the problem as specified in code/exercises/problem/* to
;; _build/exercises/problem/*. This is a temporary location to first
;; test the problem before writing to exercises/problem/*.
(define (build-exercism problem)
  (let ((implementation (get-problem problem)))
    (let* ((dir (format "_build/exercises/~a" problem))
	   (src (format "code/exercises/~a" problem))
	   (test.scm (format "~a/test.scm" dir))
	   (skeleton.scm (format "~a/~a" src (lookup 'skeleton implementation)))
	   (solution.scm (format "~a/~a" src (lookup 'solution implementation))))
      (format #t "writing _build/exercises/~a~%" problem)
      (system
       (format "mkdir -p ~a && cp ~a ~a && cp ~a ~a && cp ~a ~a/Makefile"
	       dir skeleton.scm dir solution.scm dir "code/stub-makefile" dir))
      (hint-exercism problem)
      (write-expression-to-file (lookup 'test implementation) test.scm))))

;; If hint field is specified, include .meta/hints.md in exercise
;; directory.
(define (hint-exercism problem)
  (cond ((assoc 'hints.md (get-problem problem)) =>
	 (lambda (hint)
	   (let* ((target (format "_build/exercises/~a/.meta/hints.md" problem))
		  (meta-dir (path-parent target)))
	     (unless (file-exists? meta-dir)
	       (mkdir (path-parent target)))
	     (when (file-exists? target)
	       (delete-file target))
	     (with-output-to-file target
	       (lambda ()
		 (put-md (cdr hint)))))))))

;; test the problem output in _build/exercises/problem/*
(define (verify-exercism problem)
  (let ((dir (format "_build/exercises/~a" problem))
        (implementation (get-problem problem)))
    (check-config-for problem)
    (let ((x (system (format "cd ~a && make" dir))))
      (unless (zero? x)
	(error 'verify-exercism "example solution incorrect" problem)))
    'done))

(define (include-exercism problem)
  (format #t "including exercises/~a~%" problem)
  (system (format "rm -rf exercises/~a && cp -r _build/exercises/~a exercises/~a && rm exercises/~a/Makefile"
		  problem problem problem problem))
  'done)

;; build all implementations in the problem table
(define (build-implementations)
  (for-each build-exercism implementations))

;; test all builds specified as implemented
(define (verify-implementations)
  (for-each verify-exercism implementations))

(define (make-exercism problem)
  (build-exercism problem)
  (verify-exercism problem)
  (include-exercism problem))

