(in-package :python)

(defparameter *scope* nil "Current execution namespace")

#+(or)
(defun make-builtins-module ()
  
  ;; Fill a new namespace with all built-in names, and create a module
  ;; for it. Because there are no name conflicts, the order of filling
  ;; with functions and types doesn't matter.
  
  (let ((ns (make-namespace :name "builtins-namespace")))
    (do-external-symbols (s 'python-builtin-functions)
      (namespace-bind ns (symbol-name s) (symbol-function s)))
    (do-external-symbols (s 'python-builtin-types)
      (if (boundp s) ;; check needed, as some symbols are TODO
	  (namespace-bind ns (symbol-name s) (symbol-value s))))
    (loop for (key . val) in `((None . ,*None*)
			       (Ellipsis . ,*Ellipsis*)
			       (NotImpemented . ,*NotImplemented*)
			       (True . ,*True*)
			       (False . ,*False*))
	do (namespace-bind ns key val))
    (loop for (name . exc) in *python-exceptions*
	do (namespace-bind ns name exc))
    (make-module :name "__builtin__"
		 :namespace ns)))

(defparameter *__debug__* 1) ;; CPython readonly variable `__debug__' (see EVAL-ASSERT)

#+(or)(defparameter *sys.modules* (make-namespace) "Registry of all modules")

;;; Evaluation

(defun user-py-eval (ast &optional namespace)
  "Evaluate some Python code. This is the function to be called for ~
   evaluating user-supplied code in the form of an AST, and
   optionally a namespace."
  
  (let ((*scope* (or namespace 
		     (make-namespace :name "<new user-py-eval ns>"
				     :builtins t))))
    (namespace-bind *scope* '__name__ "__main__")
    (py-eval ast)))


(defvar *py-eval-handler-set* nil)

(defun py-eval (ast)
  "Evaluate AST. Assumes *scope* is set appropriately."

  ;; During evaluation of Python code, a some Lisp errors may
  ;; occur. Some of them are catched and converted to the
  ;; corresponding Python exception.
  (flet ((do-py-eval (ast)
	   (typecase ast
	     (python-object (return-from py-eval ast)) ;; already evaluated
	     (python-type (return-from py-eval ast))
	     (number (return-from py-eval ast)) ;; Lisp objects (for efficiency)
	     (string (return-from py-eval ast))
	     ((and symbol
	       (not (eql nil)))
	      (return-from py-eval ast)) ;; string designator
	     ((eql nil) (error "PY-EVAL of NIL")))
    
	   (when (eql ast (find-class 'python-type))
	     (return-from py-eval ast))

	   ;; This allows all kinds of Lisp values to be used directly in Python,
	   ;; e.g. using `clpy(...)'
	   (unless (listp ast)
	     (return-from py-eval ast))
	   
	   (case (car ast)
	     (inline-lisp (eval-inline-lisp (second ast)))
	     (file-input (apply #'eval-file-input (cdr ast)))
	     (testlist (apply #'eval-testlist (cdr ast)))
    
	     ;; special hook for inserting Lisp code directly in AST
	     ;; (implicit PROGN)
	     #+(or)(lisp (eval `(progn ,@(cdr ast))))
	   
	     ;; these bind names and create new scope:
	     (module (apply #'eval-module "mod_name_here" (cdr ast)))
	     (funcdef (apply #'eval-funcdef (cdr ast)))
	     (class (apply #'eval-classdef (cdr ast)))
      
	     (import (apply #'eval-import (cdr ast)))
	     (import-from (apply #'eval-import-from (cdr ast)))
		   
	     (assign-expr (apply #'eval-assign-expr (cdr ast)))
	     (del (eval-del (second ast)))

	     (try-except (apply #'eval-try-except (cdr ast)))
	     (raise (apply #'eval-raise (cdr ast)))
    
	     ;; expressions:
	     (identifier (eval-identifier (second ast)))
	     (string (make-py-string (cdr ast)))
	     (number (check-type (cdr ast) number)
		     (make-py-number (cdr ast)))
    
	     (list (apply #'eval-list (cdr ast)))
	     (tuple (make-tuple-from-list (mapcar #'py-eval (cdr ast))))
	     (dict (eval-dict (second ast)))
	     (string-conversion (apply #'eval-string-conv (cdr ast)))
    
	     (call (apply #'eval-call (cdr ast)))
    
	     (comparison (apply #'eval-comparison (cdr ast)))
	     (unary (apply #'eval-unary (cdr ast)))
	     (binary (apply #'eval-binary (cdr ast)))
    
	     (attributeref (apply #'eval-attributeref (cdr ast)))
	     (subscription (apply #'eval-subscription (cdr ast)))
    
	     ;;(simple-slice (apply #'eval-simple-slice (cdr ast)))
	     ;;(extended-slice (apply #'eval-extended-slice (cdr ast)))
	     (slice (eval-slice (cdr ast)))
    
	     (lambda (apply #'eval-lambda (cdr ast)))
    
	     (print (apply #'eval-print (cdr ast)))
	     (print>> (apply #'eval-print>> (cdr ast)))
    
	     (ellipsis *Ellipsis*)

	     ;; statements
	     (pass) ;; nothing
	     (suite (eval-suite (second ast)))
      
	     (for-in (apply #'eval-for-in (cdr ast)))
	     (while (apply #'eval-while (cdr ast)))
	     (break (eval-break))
	     (continue (eval-continue))
	     (if (apply #'eval-if (cdr ast)))
            
	     (return (eval-return (cadr ast)))
	     (assert (apply #'eval-assert (cdr ast)))
    
	     (t (error "uncatched in py-eval: ~S~%" ast)))))

    (if *py-eval-handler-set*
	
	(do-py-eval ast)

      (handler-bind 
	  ((division-by-zero (lambda (c) (declare (ignore c))
				     (py-raise 'ZeroDivisionError
					       "Division or modulo by zero"))))
	(let ((*py-eval-handler-set* t))
	  (do-py-eval ast))))))


(defun eval-inline-lisp (form)
  (eval form))

(defun eval-try-except (suite except-clauses else-clause)
  (handler-bind
      ((Exception (lambda (e)
		    (loop for ((class parameter) handler-form) in except-clauses
			do (when (or (null class)
				     (typep e (py-eval class)))
			     (when parameter
			       (assert (eq (first parameter) 'identifier))
			       (namespace-bind *scope* (second parameter) e))
			     (py-eval handler-form)
			     (return-from eval-try-except nil))))))
    (py-eval suite))
  (py-eval else-clause))


(defun eval-raise (exctype value traceback)
  ;; Complicated interpretation of parameters. See Python Reference Manual, par 6.9
  
  (setf exctype   (when exctype (py-eval exctype))
	value     (when value (py-eval value))
	traceback (when traceback (py-eval traceback)))
  
  (cond ((and traceback 
	      (not (eq traceback *None*)))
	 ;; "If a third object is present and not None, it must be a
	 ;; traceback object (see section 3.2), and it is substituted
	 ;; instead of the current location as the place where the
	 ;; exception occurred."
	 
	 (error "Traceback parameter to RAISE not supported (yet?)"))
	
	
	((null exctype)
	 ;; "If no expressions are present, raise re-raises the last
	 ;; expression that was active in the current scope. If no
	 ;; exception is active in the current scope, an exception is
	 ;; raised indicating this error." 
	 
	 (error "TODO: reraise previous exception"))


	((typep exctype 'class)

	 ;; "If the first object is a class, it becomes the type of
	 ;; the exception.
	 ;; 
	 ;; The second object is used to determine the exception
	 ;; value: If it is an instance of the class, the instance
	 ;; becomes the exception value. If the second object is a
	 ;; tuple, it is used as the argument list for the class
	 ;; constructor; if it is None, an empty argument list is
	 ;; used, and any other object is treated as a single argument
	 ;; to the constructor. The instance so created by calling the
	 ;; constructor is used as the exception value."
	 
	 ;; XXX  make-instance or __call__?
	 
	 (cond ((typep value exctype) (error exctype :args value))
	       
	       ((typep value 'py-tuple)  
		(error exctype (__call__ exctype (tuple->lisp-list value))))
	       
	       ((or (null value)
		    (eq value *None*)) (error (make-instance exctype)))
	       
	       (t (error (make-instance exctype :args value)))))

	(t
	 ;; "If the first object is an instance, the type of the
	 ;; exception is the class of the instance, the instance itself
	 ;; is the value, and the second object must be None."
  
	 (if (or (eq value *None*)
		 (null value))
	     (error (__class__ exctype) :var exctype)
	   (py-raise 'ValueError
		     "RAISE: when first arg is instance, second argument must be None or not supplied (got: ~A)"
		     value)))))

		
		    
(defun eval-assert (test expr)
  "Test whether assertion holds. Is only executed when __debug__ is true"
  (when (py-val->lisp-bool *__debug__*)
    (unless (py-val->lisp-bool (py-eval test))
      (py-raise 'AssertionError (py-eval expr)))))

(defun eval-del (exprlist)
  (assert (eq (car exprlist) 'exprlist))
  (dolist (place (second exprlist))
    (cond ((eq (car place) 'identifier)
	   (namespace-delete *scope* (second place)))
	  (t
	   (error "eval-del: can only do simple vars for now")))))

(defun eval-list (data)
  ;; either normal list or list comprehension
  (if (and (second data)
	   (listp (second data))
	   (listp (car (second data)))
	   (eq (car (car (second data))) 'list-for-in)) ;; hack
      
      ;; list compr.
      (let ((expr (car data))
	    (for-ifs (cadr data)))
	;;(format t "expr=~A~%for-ifs=~A~%" expr for-ifs)
	(eval-listcompr expr for-ifs))

    (make-py-list-from-list (map-into data #'py-eval data))))
    
(defun eval-testlist (items comma?)
  (unless (or items comma?)
    (py-raise 'SyntaxError
	      "Empty tuple is invalid -- use this instead: (,)"))
  (let ((make-tuple (or comma?
			(>= (length items) 2))))
    (if make-tuple
	(make-tuple-from-list (mapcar #'py-eval items))
      (py-eval (car items)))))
   
(defun eval-file-input (data)
  (cons :file-input (mapcar #'py-eval data)))

(defun eval-suite (stmts)
  "Return value of last stmt in suite"
  (mapc #'py-eval stmts))

(defun eval-identifier (name)
  "Look up the identifier in the active namespaces, and fall back to
   looking in the (module) object named '__builtins__."

  (or (namespace-lookup *scope* name) ;; traverses all enclosing scopes too
      
      (let ((bi (namespace-lookup *scope* '__builtins__)))
	(when bi
	  (namespace-lookup bi name)))
      
      (py-raise 'NameError
		"Name ~A is not defined" name)))

(defun eval-return (val)
  (throw 'function-block (if val 
			     (py-eval val)
			   *None*)))

(defun eval-dict (data)
  ;; eval keys and values in this order: key1, val1, key2, val2, ...
  (mapc (lambda (kv) (setf (car kv) (py-eval (car kv))
			   (cdr kv) (py-eval (cdr kv))))
	data)
  (make-dict data))



(defun eval-listcompr (expr list-for-ifs)
  (let ((acc ()))
    (labels ((process-for/ifs (for-ifs)
	       (let ((clause (car for-ifs)))
		 (cond ((null for-ifs)                 (collect-expr))
		       ((eq (car clause) 'list-for-in) (process-for for-ifs))
		       ((eq (car clause) 'list-if)     (process-if for-ifs)))))
	     
	     (collect-expr () (push (py-eval expr) acc))
	     
	     (process-for (for-ifs)
	       (destructuring-bind ((_list-for-in exprlist source) &rest rest)
		   for-ifs
		 (declare (ignore _list-for-in))
		 (let ((esource (py-eval source)))
		   (py-iterate ($dummy$ esource)
			       (eval-assign-expr-1 exprlist $dummy$)
			       (process-for/ifs rest)))))
	     
	     (process-if (for-ifs)
	       (destructuring-bind ((_list-if condition) &rest rest)
		   for-ifs
		 (declare (ignore _list-if))
		 (when (py-val->lisp-bool (py-eval condition))
		   (process-for/ifs rest)))))
      
      (process-for/ifs list-for-ifs)
      (make-py-list-from-list (nreverse acc)))))

  
#+(or)
(defun eval-string-conv (tuple)
  (declare (ignore tuple))
  (error 'todo))

(defun eval-attributeref (obj attr)
  (assert (eq (car attr) 'identifier))
  (let ((eobj (py-eval obj))
	(attr-name (second attr)))
    (multiple-value-bind (val found)
	(internal-get-attribute eobj attr-name)
      (if found
	  val
	(py-raise 'AttributeError
		  "Object ~A has not attribute ~A" eobj attr-name)))))

(defun eval-subscription (primary data)
  (destructuring-bind (item-list comma?)
      data
    (assert (consp item-list))
    (let* ((eprim (py-eval primary))
	   (item-list-2 (mapcar #'py-eval item-list))
	   (item (if (or comma?
			 (> (length item-list) 1))
		     (make-tuple-from-list (mapcar #'py-eval item-list-2))
		   (car item-list-2))))
      
      (multiple-value-bind (getitem found)
	  (internal-get-attribute eprim '__getitem__)
	(if found
	    (__call__ getitem (list item))
	  (py-raise 'TypeError
		    "No __getitem__ found (~A)" eprim)))
      #+(or)(__getitem__ eprim item))))

(defun eval-slice (data)
  (destructuring-bind (start stop &optional step)
      data
    (make-slice (if start (py-eval start) *None*)
		(if stop (py-eval stop) *None*)
		(if step (py-eval step) *None*))))




(defun eval-call (primary args)
  (let ((eprim (py-eval primary))) ;; XX check order of this eval
    (if (null args)
	
	(__call__ eprim () ())
      
      (let* ((*-arg (find '* args :key (lambda (x) (when (consp x)
						     (car x)))))
	     (**-arg (find '** args :key (lambda (x) (when (consp x)
						       (car x)))))
	     (temp-key-args (loop for a in args
				when (and (consp a)
					  (eq (car a) '=))
				collect a))
	     
	     (key-args (mapcar (lambda (a)
				 (destructuring-bind (= key val)
				     a
				   (declare (ignore =))
				   (assert (eq (car key) 'identifier) ()
				     "for key=val arg, supply simple varname as ~
                                      key (got: ~A)" a)
				   (cons (second key) val)))
			       temp-key-args))
	     
	     (pos-args (remove *-arg (remove **-arg
					     (let ((x args))
					       (dolist (a temp-key-args)
						 (setf x (delete a x)))
					       x)))))
	     
	(setf *-arg (second *-arg)  ;; remove leading stars in list
	      **-arg (second **-arg))
	
	#+(or)(format t "EVAL-CALL: pos: ~A  key: ~A  *: ~A  **: ~A~%" 
		      pos-args key-args *-arg **-arg)
	  
	(setf pos-args (mapcar #'py-eval pos-args)
	      pos-args (append pos-args (when *-arg
					  (slot-value (py-eval *-arg) 'list)))
	      key-args (loop for (k . v) in key-args
			   collect `(,k . ,(py-eval v)))
	      key-args (append key-args (when **-arg
					  (dict->alist (py-eval **-arg)))))
	;; **-arg can only contain already evaluated stuff, is the assumption
	#+(or)(format t "call: ~A~%" `(__call__ ,eprim ,pos-args ,key-args))
	(__call__ eprim pos-args key-args)))))


(defun eval-for-in (targets sources suite else-suite)
  (let ((esource (py-eval sources))
	(take-else t))
    (catch 'break
      (py-iterate ($dummy$ esource)
		  (setf take-else nil)
		  (eval-assign-expr-1 targets $dummy$)
		  (catch 'continue
		    (py-eval suite))))
    (when take-else
      (py-eval else-suite))))

(defun eval-continue ()
  (throw 'continue nil))

(defun eval-break ()
  (throw 'break nil))


;; a = b,c = [1,2]
;;  -> a = [1,2]
;;     b = 1, c = 2

(defun eval-assign-expr (items)
  (destructuring-bind (val &rest targets)
      (reverse items)
    (if targets

	;; real assignment statement
	(let ((eval (py-eval val)))
	  (dolist (tar targets)
	    (eval-assign-expr-1 tar eval)))
      
      ;; just variable reference
      (py-eval val))))
    

(defun eval-assign-expr-1 (targets evalue)
  "Assign EVALUE to TARGETS.
   Assumes EVALUE already evaluated."
  (assert (member (car targets) '(testlist exprlist) :test 'eq))
  (let* ((etargets (eval-assignment-targets (second targets)))
	 (num-targets (length etargets))
	 
	 ;; both testlist and exprlist have comma? as third list element
	 (comma? (third targets))
	 (target-is-list (or (> num-targets 1)
			     comma?)))
    
    ;; (format t "eval-ass-targets: ~S~%" etargets)
    (cond
     ((= num-targets 0)
      (error "no assignment targets?! ~W ~W" etargets evalue))
       
     ((and (= num-targets 1)
	   (not target-is-list))
      (eval-assign-one (car etargets) evalue))
       
     ((or (>= num-targets 2)
	  target-is-list)
      (let ((i 0)
	    (acc ()))
	(py-iterate (x evalue)
		    (incf i)
		    (when (> i num-targets)
		      (py-raise
		       'ValueError
		       "Too many values to unpack (needed exactly ~A values), ~@
                        got already one more than that." num-targets))
		    (push x acc))
	(when (< i num-targets)
	  (py-raise 'ValueError
		    "Too few values to unpack (needed exactly ~A values, ~
                     but got only ~A)."
		    num-targets i))
	  
	;; arriving here means we got exactly enough values.
	(setf acc (nreverse acc))
	(loop for val in acc
	    for tar in etargets
	    do (eval-assign-one tar val))))
     
     (t (error "shouldn't come here")))))
       
(defun eval-assign-one (target val)
  "TARGET is evaluated as far as possible, but it still contains ~@
   identifier, subscription, attributeref. VAL is the fully evaluated ~@
   value to be assigned."
  
  (cond ((eq (car target) 'identifier)
	 ;; (identifier name)
	 (namespace-bind *scope* (second target) val))
	
	((eq (car target) 'attributeref)
	 ;; (attributeref <primary> (identifier attr-name))
	 (destructuring-bind (primary (identifier attr-name))
	     (cdr target)
	   (declare (ignore identifier))
	   ;;(assert (eq (car attr-name) 'identifier))
	   (internal-set-attribute primary attr-name val)))
	
  	((eq (car target) 'subscription)
	 ;; (subscription <primary> <subs>)
	 (destructuring-bind (primary subs)
	     (cdr target)
	   
	   (multiple-value-bind (setitem found)
	       (internal-get-attribute primary '__setitem__)
	     (if found
		 (__call__ setitem (list subs val))
	       (py-raise 'TypeError "No __setitem__ found (~A)" primary)))
	   
	   #+(or) ;; not correct for UDC with method __setitem__
	   (__setitem__ primary subs val)))
	
	((or (numberp target) (stringp target))
	 (error "Literal target -- (should have been catched already in ~@
                 EVAL-ASSIGNMENT-TARGETS) A~" target))

	((eq (car target) 'testlist)
	 (destructuring-bind (item-list comma?)
	     (cdr target)
	   (let ((new-target (if (or comma?
				 (> (length item-list) 1))
			     `(list ,@item-list)
			   (car item-list))))
	     (eval-assign-one new-target val))))
	  
	((eq (car target) 'list)
	 ;; (list <A> <B> ...)
	 ;; List, tuple are both made `list' by EVAL-ASSIGNMENT-TARGETS.
	 ;; VAL must be iterable, otherwise py-iterate raises TypeError
	 (let* ((targets (cdr target))
		(num-targets (length targets))
		(i 0)
		(acc ()))
	   (py-iterate (x val)
		       (incf i)
		       (push x acc)
		       (when (> i num-targets)
			 (py-raise
			  'ValueError "Too many values to unpack (needed exactly ~A ~
                                       values, got already one more than that."
			  num-targets)))
	   (when (< i num-targets)
	     (py-raise 'ValueError
		       "Too few values to unpack (needed exactly ~A values, ~
                        but got only ~A)." num-targets i))
	   (setf acc (nreverse acc))
	   (loop for val in acc
	       for tar in targets
	       do (eval-assign-one tar val))))
	
	(t
	 (error "uncatched situation in EVAL-ASSIGN-ONE: ~@
                 target = ~A  val = ~A" target val))))


(defun eval-assignment-targets (targets)
  (labels ((do-eval (tg)
	     (when (atom tg)
	       (py-raise 'SyntaxError
			 "Cannot assign to a literal (got target: ~A)" tg))
	     (case (car tg)
	       ;; (IDENTIFIER a) : remains the same
	       (identifier tg)
	       
	       ;; (TUPLE A B) and (LIST A B) both go to (LIST <A> <B>)
	       ((tuple list) `(list ,@(mapcar #'do-eval (second tg))))
	       
	       ;; foo.x => (attributeref (identifier foo) (identifier x))
	       ;; 
	       ;; The primary is evaluated; the attribute identifier
	       ;; is just a name and can't be further evaluated.
	       (attributeref `(attributeref ,(py-eval (second tg))
					    ,(third tg)))
	       
	       ;; x[1,2,3]
	       ;; => (subscription (identifier x) ((1 2 3) nil))) nil)
	       ;;
	       ;; Both primary and expr-list are evaluated; result is
	       ;;  (subscription <object> <item-or-tuple>)
	       (subscription 
		(destructuring-bind (primary (subs comma?))
		    (cdr tg)
		  `(subscription ,(py-eval primary)
				 ,(let* ((esubs (mapcar #'py-eval subs))
					 (make-tuple (or (> (length subs) 1)
							 comma?)))
				    (if make-tuple
					(make-tuple-from-list esubs)
				      (car esubs))))))
	       
	       ;; todo: slices
	       (testlist
		`(list ,@(loop for x in (second tg)
			     collect (do-eval x))))
	       
	       (t
		(warn "EVAL-ASSIGNMENT-TARGETS: assuming ~A is an expression ~
                       to be evaluated." tg)
		(py-eval tg)))))
    
    (loop for tg in targets
	collect (do-eval tg)))) ;; local function: can't do direct mapcar

(defun eval-funcdef (fname params suite)
  "In the current namespace, FNAME becomes bound to a function object ~@
   with given formal parameters and function body."
  
  ;; Special-case: the function, when called, will return a
  ;; generator. If this is the case, treat it a bit special.
  ;; 
  ;; Note that 'yield' inside "exec" or "eval" is not allowed, so it
  ;; can be statically checked whether the function returns a
  ;; generator or not.
  
  (if (generator-ast-p suite)
      
      (let* ((params (multiple-value-list (parse-function-parameter-list params)))
	     (f (make-python-function-returning-generator params suite)))
	(namespace-bind *scope* fname f))
  
    (let* ((params (multiple-value-list (parse-function-parameter-list params)))
	   (f (make-user-defined-function 
	       :name fname
	       :ast suite
	       :namespace (make-namespace
			   :name (format nil "ns for function ~A" fname)
			   :inside *scope*)
	       :params params
	       :call-rewriter (apply #'make-call-rewriter params))))
	
      ;; Content of function is not evaluated yet; only when called.
      ;; Bind function name to function object in current namespace:
      (namespace-bind *scope* fname f)))
  *None*)

(defun eval-lambda (params expr)
  (let ((parsed-params (multiple-value-list (parse-function-parameter-list params))))
    (make-lambda-function
     :ast expr
     :namespace (make-namespace :name "lambda namespace"
				:inside *scope*)
     :params parsed-params
     :call-rewriter (apply #'make-call-rewriter parsed-params))))

(defun parse-function-parameter-list (params)
  "Returns POS-PARAMS, KW-PARAMS, *-PAR, **-PAR as multiple values"

  (destructuring-bind (pos-kw-params *-par **-par)
      params
    
    ;; Keyword arguments must come after positional arguments.
    ;; The grammar doesn't restrict that, so check it here.
    
    (let ((found-kw nil))
      (mapc (lambda (x)
	      (cond ((consp x)
		     (setf found-kw x))
		    ((and found-kw (symbolp x))
		     (py-raise 'SyntaxError
			       "Non-default argument '~A' follows default argument '~A'"
			       x (car found-kw)))
		    (t)))
	    pos-kw-params))
    
    (loop for x in pos-kw-params
	if (consp x) 
	collect (progn (setf (cdr x) (py-eval (cdr x)))
		       x)
	into kw-args
	     
	else collect x into pos-args
	finally (return (values pos-args kw-args *-par **-par)))))


(defun eval-classdef (cname inheritance suite)
  (unless inheritance
    (setf inheritance `(testlist () nil)))
  
  ;; The inheritance list will be evaluated, but MAKE-PYTHON-CLASS
  ;; expects a list of *names*, therefore after each of the items is
  ;; evaluated and has a class object as value, CLASS-NAME must be
  ;; called.
  
  (assert (eq (car inheritance) 'testlist))
  (let* ((ns (make-namespace :name (format nil "<ns for class ~A>" cname)
			     :inside *scope*))
	 
	 (supers (mapcar (lambda (x)
			   (let ((c (py-eval x)))
			     (if (typep c 'class)
				 (class-name c)
			       (py-raise 'TypeError
					 "Cannot have non-classes in ~
                                          superclass list (got: ~A)" c))))
			 (second inheritance)))
				       
	 (c (make-python-class :name cname
			       :module "ModuleName"
			       :supers supers
			       :namespace ns)))
    
    ;; In the current namespace, the name of the class that is defined
    ;; now becomes bound to the class object that results from
    ;; evaluating the classdef.
    (namespace-bind *scope* cname c)
    
    ;; Evaluate SUITE now, in the new namespace inside the class:
    ;; methods and class attributes are defined in it, plus there may
    ;; be other side effects.
    (when suite
      (let ((*scope* ns))
	(py-eval suite)))
    
    ;; Finally, return the class (purely for debuggin: classdef has no
    ;; return value, as it is a stmt, not an expr.
    c))


(defun read-file (filename)
  (with-open-file (stream filename :direction :input)
    (let ((res (make-array (or (file-length stream)
			       10000)
			   :element-type 'character
			   :fill-pointer 0
			   :adjustable t)))
      (let ((c (read-char stream nil nil)))
	(loop while c do
	      (vector-push-extend c res)
	      (setf c (read-char stream nil nil))))
      res)))

(defun make-module-object (module-name)
  (let* ((file-name (concatenate 'string (string module-name) ".py"))
	 (file-contents (read-file file-name)))
      
    ;; In CPython, when the toplevel of modules is executed, the
    ;; name of the module is not yet bound to the module object
      
    (let* ((module-ns (make-namespace
		       :name (format nil "namespace for module ~A" module-name)
		       :builtins t))
	   (module-ast (parse-python-string file-contents)))
	
      (let ((*scope* module-ns))
	(declare (special *scope*))
	(namespace-bind module-ns '__name__ module-name)
	(namespace-bind module-ns '__file__ file-name)
	(py-eval module-ast))
	
      ;; Now bind module name to the object in the enclosing namespace
      (make-module :name (string file-name)
		   :namespace module-ns))))


(defun eval-import (items)
  ;; TODO: use sys.path
  (flet ((get-module-object (mod-name) ;; -> #<MODULE>, EXISTED-ALREADY-P
	   (let ((mod (namespace-lookup *sys.modules* mod-name)))
	     (declare (special *sys.modules*))
	     (if mod
		 (values mod t)
	       (let ((m (make-module-object mod-name)))
		 (namespace-bind *sys.modules* mod-name m)
		 (values m nil)))))
	 
	 (normalize-item (x)
	   (if (symbolp x) `(as ,x ,x) x))
	       
	 (normalize-list (list)
	   (loop for x in list
	       if (symbolp x) collect `(as ,x ,x)
	       else collect x)))
    
    (dolist (item (normalize-list items))
      (assert (listp item))
       
      (ecase (car item)
	  	  
	(from  ;; "from a import b, c as c2" -> '(from a (b (as c c2)))
	 (destructuring-bind (mod-name attributes)
	     (cdr item)
	   (let ((mo (get-module-object mod-name)))
	     
	     (if (eq attributes '*) ;; "from a import *"
		 
		 (multiple-value-bind (all found)
		     (internal-get-attribute mo '__all__)
		   (if found
		       
		       (py-iterate (attr all)
				   (multiple-value-bind (val found)
				       (internal-get-attribute mo attr)
				     (unless found
				       (py-raise 'AttributeError
						 "Module ~A has no attribute ~A (mentioned in __all__)"
						 mo attr))
				     (namespace-bind *scope* attr val)))
		     
		     ;; no __all__ method:
		     ;; iterate over all names in the module dict that don't start with underscore
		     (loop for (name . val) in (dict->alist (module-dict mo))
			 when (char/= (aref 0 (string name)) #\_) 
			 do (namespace-bind *scope* name val))))

	       (dolist (attr (normalize-list attributes))
		 (assert (eq (car attr) 'as))
		 (destructuring-bind (real-name new-name)
		     (cdr attr)
		   (multiple-value-bind (val found)
		       (internal-get-attribute mo real-name)
		     (if found
			 (namespace-bind *scope* new-name val)
		       (py-raise 'ImportError "Module ~A has no attribute: ~S" mod-name attr)))))))))
	  
	(as  ;; "import c as c2" -> '(as c c2)
	 (destructuring-bind (real-name new-name)
	     (cdr item)
	   (let ((mo (get-module-object real-name)))
	     (namespace-bind *scope* new-name mo))))))))
	
	
(defun eval-if (clauses else-suite)
  (loop for (expr suite) in clauses
      when (py-val->lisp-bool (py-eval expr))
      do (py-eval suite)
	 (return)
      finally
	(when else-suite
	  (py-eval else-suite))))

(defun eval-while (test suite else-suite)
  (let ((taken nil))
    (catch 'break
      (loop
	  while (py-val->lisp-bool (py-eval test))
	  do (catch 'continue
	       (py-eval suite)
	       (setf taken t))))
    (unless taken
      (py-eval else-suite))))

(defun eval-comparison (operator left right)
  "Does comparison, returns Python boolean"
  (let ((comp-fun (cdr (assoc operator *math-binary-cmp-assoc*))))
    (assert comp-fun () "No comparison function corresponding to ~
                         comparison operator ~A?! ~A" operator *math-binary-cmp-assoc*)
    (lisp-val->py-bool (funcall comp-fun (py-eval left) (py-eval right)))))

(defun eval-unary (operator val)
  (declare (special *math-unary-op-assoc*))
  (let ((func (cdr (assoc operator *math-unary-op-assoc*))))
    (unless func
      (error "No function for unary operator ~A?! ~A" operator *math-unary-op-assoc*))
    (funcall func (py-eval val))))

(defun eval-binary (operator left right)
  (declare (special *math-binary-op-assoc*)) ;; defined in mathops.cl
  (let ((func (cdr (assoc operator *math-binary-op-assoc*))))
    (assert func () "Operator ~A has no corresponding py-~A function?! ~A"
	    operator operator *math-binary-op-assoc*)
    (funcall func (py-eval left) (py-eval right))))

(defun eval-tuple (&rest content)
  (let ((c (mapcar #'py-eval content)))
    (make-tuple-from-list c)))

(defun get-slice (obj start end &optional (step nil))
  (declare (ignore obj start end step))
  'todo)


;; XXX print todo: lookup sys.stdout instead of blindly using `t' as
;; stdout stream.

(defun eval-print (objs comma?)
  "Print OBJS to STDOUT; trailing comma means no newline at the end."
  (eval-print-stream t objs comma?))

(defun eval-print>> (stream objs comma?)
  "Print OBJS to STREAM ~@
   If STREAM is None, then use STDOUT.
   Trailing comma means no newline at the end."
  (eval-print-stream (if (eq stream *None*) t stream)
		     objs
		     comma?))

(defun eval-print-stream (stream objs comma?)
  "The Python PRINT statement (a rough approximation)"
  
  (dolist (x objs)
    (let* ((ex (py-eval x))
	   (str (call-attribute-via-class ex '__str__)))
      (format stream "~A " str)))
  
  (unless comma?
    (terpri)))










