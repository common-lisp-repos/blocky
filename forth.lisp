;;; forth.lisp --- forth-style concatenative word language for Blocky

;; Copyright (C) 2013  David O'Toole

;; Author: David O'Toole <dto@ioforms.org>
;; Keywords: 

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

(in-package :blocky)

(defvar *words* nil)
(defvar *stack* nil)
(defvar *program* nil)

(defun pushf (x) (push x *stack*))
(defun popf () (pop *stack*))
(defun next-word () (when *program* (first *program*)))
(defun grab-next-word () (pop *program*))

(defun end-marker-p (word) 
  (and (symbolp word)
       (string= "END" (symbol-name word))))

(defun grab-until-end ()
  (let (words word)
    (block grabbing
      (loop while *program* do 
	(setf word (grab-next-word))
	(if (end-marker-p word)
	    (return-from grabbing)
	    (push word words))))
    (nreverse words)))

(defun initialize-words ()
  ;; words are symbols so we use 'eq
  (setf *words* (make-hash-table :test 'eq)))

(initialize-words)

(defstruct word name body properties arguments)

(defun word-definition (word)
  (gethash word *words*))

(defun set-word-definition (name definition)
  (assert (not (null name)))
  (assert (symbolp name)) 
  (setf (gethash name *words*) definition))

(defmacro define-word (name arguments &body body)
  "Define a primitive word called NAME with Lisp code.
The BODY-forms execute later when the word NAME is executed.
The ARGUMENTS (if any) are auto-pulled from the stack by the 
interpreter."
  `(set-word-definition 
    ',name
    (make-word :name ',name
	       :arguments ',arguments
	       :body #'(lambda ,arguments ,@body))))

(defun define-program-word (name program)
  "Define a word as a sequence of words."
  (set-word-definition 
   name
   (make-word :name name
	      ;; forth definitions are stored as lists
	      :body program)))

;; defining words in source

(define-word end () nil)

(define-word define ()
  (destructuring-bind (name &rest definition) 
      (grab-until-end)
    (define-program-word name definition)))

(defun forget-word (word)
  (let ((definition (word-definition word)))
    (when (consp (word-body definition))
      (remhash word *words*))))

(define-word forget (word)
  (forget-word word))

(defun forget-all-words ()
  (loop for word being the hash-keys of *words*
	do (forget-word word)))

;;; The interpreter

(defun execute-word (word)
  (if (typep word '(or cons string number character keyword))
      ;; it's a literal. push it
      (pushf word)
      ;; otherwise try looking it up.
      (let ((definition (word-definition word)))
	(if (null definition)
	    (error "Cannot execute unknown word: ~A" word)
	    ;; found a definition. execute the body.
	    (let ((body (word-body definition)))
	      (etypecase body
		;; it's a forth definition. execute it.
		(cons
		 (let ((*program* body))
		   (loop while *program*
			 do (execute-word (pop *program*)))))
		;; it's a function word (i.e. a primitive)
		(function
		 ;; grab arguments (if any) and invoke primitive function
		 (let (arguments)
		   (dotimes (n (length (word-arguments definition)))
		     (push (popf) arguments))
		   (apply body (nreverse arguments))))))))))
  
(defun execute (program)
    (let ((*program* program))
      (loop while *program* 
	    do (execute-word (grab-next-word)))))

(defun program-from-string (string)
  (with-input-from-string (stream string)
    (loop for sexp = (read stream nil)
	  while sexp collect sexp)))

(defun execute-string (string)
  (execute (program-from-string string)))

(define-word evalf (body)
  (execute body)
  (popf))

(defmacro forth (&rest words)
  `(execute ',words))

;;; Control flow

(define-word not (boolean)
  (pushf (if boolean nil t)))

(define-word if (boolean then else)
  (execute (if boolean then else)))

(define-word every? (expressions)
  (pushf (every #'evalf expressions)))

(define-word notany? (expressions)
  (pushf (notany #'evalf expressions)))

(define-word some? (expressions)
  (pushf (some #'evalf expressions)))

(define-word each (elements body)
  (dolist (element elements)
    (pushf element)
    (execute body)))

(define-word map (elements body)
  (pushf (mapcar #'evalf elements)))

(define-word filter (elements body)
  (pushf (remove-if-not #'evalf elements)))

;;; Accessing fields. See also `define-block'.

(define-word @ (field)
  (pushf (field-value field *self*)))

(define-word ! (field)
  (setf (field-value field *self*) (popf)))

;;; Object-orientation

(define-word new () (pushf (new (popf))))
(define-word self () (pushf *self*))
(define-word this () (setf *self* (popf)))

;; articles quote the next word.
;; examples:
;;    "a block"
;;    "a robot"
;;    "with (1 2 3)"

(define-word a () (pushf (grab-next-word)))
(define-word an () (pushf (grab-next-word)))
(define-word the () (pushf (grab-next-word)))
(define-word with () (pushf (grab-next-word)))
(define-word to () (pushf (grab-next-word)))

(defun drop-article ()
  (grab-next-word))

;; the copula "is" defines new objects from old.
;; examples: 
;;     "a robot is a block"
;;     "a robot with (health bullets inventory) is a block"
;;     "an enemy is a robot"

(define-word is (name)
  (drop-article)
  (let* ((super (grab-next-word))
	 (fields (when (consp (first *stack*))
		   (popf))))
    (eval `(define-block (,name :super ,super) ,@fields))))

;; invoking a Blocky method without any arguments.

(define-word send (method)
  (send (make-keyword method) *self*))

;; invoking a Forth method stored in the object.

(define-word call (method object)
  (execute (field-value (make-keyword method) object)))

;; telling an object to invoke one of its methods

(define-word tell (program object)
  (let ((*self* object))
    (execute program)))

;; the "to...do...end" idiom defines behavior for verbs.
;; examples: 
;;    "to fire a robot with (direction) do ... end"
;;    "to destroy an enemy do ... end"

(define-word do ()
  ;; ignore argument list for now
  (when (consp (first *stack*))
    (popf))
  (let* ((super (popf))
	 (method (popf))
	 (body (grab-until-end)))
    ;; define a self-verb shortcut 
    (execute `(define ,method the ,method self call end))
    ;; install the forth definition in the prototype
    (setf (field-value (make-keyword method)
		       (find-object super))
	  body)))

;;; further operations

(define-word zero? (number) (pushf (zerop number)))
(define-word even? (number) (pushf (evenp number)))
(define-word odd? (number) (pushf (oddp number)))
(define-word plus? (number) (pushf (plusp number)))
(define-word minus? (number) (pushf (minusp number)))

(define-word incr (field) 
  (assert (keywordp field))
  (pushf (incf (field-value field *self*))))

(define-word decr (field) 
  (assert (keywordp field))
  (pushf (decf (field-value field *self*))))

(define-word + (a b)
  (pushf (+ (execute a) (execute b))))

(define-word start () (start *self*))
(define-word stop () (stop *self*))
(define-word insert () (add-object *buffer* *self*))
(define-word delete () (remove-*self*-maybe *buffer* *self*))
(define-word destroy () (destroy *self*))
(define-word display (image) (change-image *self* image))
(define-word show () (show *self*))
(define-word hide () (hide *self*))
(define-word visible? () (pushf (visiblep self)))
(define-word play (sound) (play-sound *self* sound))
(define-word music (music) (play-music *self* music))

(define-word goto (x y) (move-to *self* x y))

(define-word move (heading distance) 
  (move *self* heading distance))

(define-word forward () (pushf (field-value :heading *self*)))
(define-word backward () (pushf (- (* 2 pi) (field-value :heading *self*))))

(define-word toward (thing) 
  (pushf (heading-to-thing *self* thing))
  (pushf (distance-to-thing *self* thing)))
	 
(define-word left (deg) (pushf (- (radian-angle deg))))
(define-word right (deg) (pushf (radian-angle deg)))

(define-word aim (heading)
  (setf (field-value :heading *self*)
	heading))

(forth define here :x @ :y @)

(define-word center () 
  (multiple-value-bind (x y)
      (center-point *self*)
    (pushf x) 
    (pushf y)))

(define-word leftward () 
  (multiple-value-bind (x y)
      (left-of *self*)
    (pushf x) 
    (pushf y)))

(define-word rightward () 
  (multiple-value-bind (x y)
      (right-of *self*)
    (pushf x) 
    (pushf y)))

(define-word above () 
  (multiple-value-bind (x y)
      (above *self*)
    (pushf x) 
    (pushf y)))

(define-word below () 
  (multiple-value-bind (x y)
      (below *self*)
    (pushf x) 
    (pushf y)))

(define-word scale (x y)
  (scale *self* x y))

(define-word colliding? (thing)
  (pushf (colliding-with *self* thing)))


;;; define forget end not if each map filter reduce get set a an the
;;; is with to send call tell is do zero? even? odd? plus? minus?
;;; new self this timer incr decr task

;;; start stop initialize destroy remove duplicate tag tag? here there
;;; it me untag contains? drop drop-at event update move forward left
;;; right backward show hide menu draw image draw resize center play
;;; collide colliding? head distance frames seconds later damage enter
;;; exit pop !heading !tags !parent !x !y !z !blend !opacity !width
;;; !height !depth !image path find

;;; resource choose random pressed? released? button key modifier
;;; control? alt? shift? report hook pointer-x pointer-y pointer
;;; joystick analog right-stick left-stick axis pressure heading
;;; right-stick? left-stick? joystick? !frame-rate ticks dt !dt
;;; blending filtering viewport window-x window-y window-z qwerty
;;; azerty qwertz dvorak save load project file font text lisp image
;;; music sample quad texture line box circle rectangle disc quit
;;; reset visit buffer open close 

;;; buffer new name switch modified? window follow glide scale pause
;;; unpause select unselect selection all none cut copy paste move
;;; future present now insert delete trim clipboard here there at-pointer 

;; example:  "explode1.png" draw ("explode2.png" draw) 0.1 seconds later
;;   (destroy) enemy tell 


;; '
;; (progn 
;;   (forget-all-words)
;;   (setf *stack* nil)
;;   (define-word foo () (format t " foo ") (push 3 *stack*))
;;   (define-word bar () (format t " bar ") (push 5 *stack*))
;;   (define-word baz (a b) (format t " baz ") (push (+ a b) *stack*))
;;   (define-word yell () (format t "WOOHOO!!"))
;;   (execute-string "foo bar baz")
;;   (execute-string "define quux foo bar baz")
;;   (execute-string "quux")
;;   (execute '(quux 100 baz))
;;   (forth quux 100 baz)
;;   (forth a robot is a block)
;;   (forth to fire a robot do quux 200 baz yell end)
;;   (forth a robot new)
;;   (forth a robot new this fire))
  
;;; forth.lisp ends here
