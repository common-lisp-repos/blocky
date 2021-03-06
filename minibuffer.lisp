;;; minibuffer.lisp --- emacs-like minibuffer for blocky

;; Copyright (C) 2012, 2013  David O'Toole

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

;;; Modeline

(defun-memo modeline-position-string (x y)
    (:key #'identity :test 'equal :validator #'identity)
  (format nil "X:~S Y:~S" x y))

(defun-memo modeline-database-string (local global)
    (:key #'identity :test 'equal :validator #'identity)
  (format nil "~S/~S objects" local global))

(define-block-macro modeline
    (:super phrase
     :fields 
     ((orientation :initform :horizontal)
      (no-background :initform t)
      (spacing :initform 4))
     :inputs (:project-id (new 'label :read-only t)
	      :buffer-id (new 'label :read-only t)
	      :position (new 'label :read-only t)
	      :mode (new 'label :read-only t)
	      :objects (new 'label :read-only t))))

(define-method update modeline ()
  (mapc #'pin %inputs)
  (set-value %%project-id *project*)
  (set-value %%buffer-id (or (%buffer-name (current-buffer)) "nil"))
  (set-value %%objects (modeline-database-string (hash-table-count (%objects (current-buffer)))
						 (hash-table-count *database*)))
  (set-value %%position
	     (modeline-position-string
	      (%window-x (current-buffer))
	      (%window-y (current-buffer))))
  (set-value %%mode
	     (if (current-buffer)
		 (if (%paused (current-buffer))
		     "(paused)"
		     "(playing)")
		 "(empty)")))

;;; Custom data entry for Minibuffer. See also entry.lisp 

(define-block (minibuffer-prompt :super entry)
  (background :initform nil)
  output)

(defun debug-on-error ()
  (setf *debug-on-error* t))

(defun print-on-error ()
  (setf *debug-on-error* nil))

(define-method set-output minibuffer-prompt (output)
  (setf %output output))

(define-method can-pick minibuffer-prompt () nil)

(define-method pick minibuffer-prompt ()
  %parent)

(define-method enter minibuffer-prompt (&optional no-clear)
  (prompt%enter self))

(define-method evaluate-here minibuffer-prompt ()
  (prompt%enter self))

(define-method do-sexp minibuffer-prompt (sexp)
  (with-fields (output) self
    (assert output)
    (let ((container (get-parent output))
	  (result nil))
      (assert (blockyp container))
      ;; output messages too
      (let ((*message-function* 
	      #'(lambda (text)
		  (format t "~A" text)
		  (accept container (new 'label :line text)))))
	;; execute lisp expressions
	(setf result (eval (first sexp)))
	;; we didn't crash, at least. output the reusable sexp
	(accept container (new 'expression :line %last-line))
	;; do something with result
	(let ((new-block 
		(if result
		    (if (blockyp result)
			result
			(new 'expression :value result)))))
      	  ;; spit out result block, if any
      	  (when new-block 
      	    (accept container new-block)))))))

(define-method lose-focus minibuffer-prompt ()
  (cancel-editing self))

;; (define-method label-width minibuffer-prompt ()
;;   (dash 2 (font-text-width *default-prompt-string* *font*)))

(define-method do-after-evaluate minibuffer-prompt ()
  ;; print any error output
  (when (and %parent (stringp %error-output)
	     (plusp (length %error-output)))
    (accept %parent (new 'text %error-output))))

;;; The Minibuffer is a pop-up command program and Forth prompt. Only
;;; shows one line, like in Emacs.

(define-block (minibuffer :super phrase)
  (sidebar :initform nil)
  (temporary :initform t)
  (display-lines :initform 12))

(defparameter *minimum-minibuffer-width* 200)

(define-method initialize minibuffer ()
  (with-fields (image inputs) self
    (let ((prompt (new 'minibuffer-prompt))
	  (modeline (new 'modeline)))
      (initialize%super self)
      (set-output prompt prompt)
      (setf inputs (list modeline prompt))
      (set-parent prompt self)
      (set-parent modeline self)
      (setf %sidebar (new 'sidebar))
      (pin prompt)
      (pin modeline))))

(define-method layout minibuffer ()
  (layout %sidebar)
  (with-fields (height width parent inputs) self
    (setf height 0)
    (setf width 0)
    ;; update all child dimensions
    (dolist (element inputs)
      (layout element)
      (incf height (field-value :height element))
      (callf max width (dash 2 (field-value :width element))))
    ;; now compute proper positions and re-layout
    (let* ((x (+ (dash 1) (%window-x (current-buffer))))
	   (y0 (+ (%window-y (current-buffer))
		 *gl-screen-height*))
	   (y (- y0 height (dash 3))))
      (dolist (element inputs)
	(decf y0 (field-value :height element))
	(move-to element x y0)
	(layout element))
      (setf %y y)
      (setf %x x)
      ;;  a little extra room at the top and sides
      (incf height (dash 3)))))
      ;; ;; move to the right spot to keep the bottom on the bottom.
      ;; (setf y (- y0 (dash 1))))))

(define-method update minibuffer ()
  (update (first %inputs))
  (update (second %inputs)))

(define-method get-prompt minibuffer ()
  (second %inputs))

(defun minibuffer-prompt ()
  (when *minibuffer* (get-prompt *minibuffer*)))

(define-method enter minibuffer ()
  (enter (get-prompt self)))
 
(define-method evaluate minibuffer ()
  (evaluate (get-prompt self)))

(define-method focus minibuffer ()
  (let ((prompt (get-prompt self)))
    (set-read-only prompt nil)
    (grab-focus prompt)))

(defparameter *minibuffer-rows* 9)

(define-method accept minibuffer (input &optional prepend)
  (declare (ignore prepend))
  (with-fields (inputs) self
    (assert (not (null inputs))) ;; we always have a prompt
    (prog1 t
      (assert (valid-connection-p self input))
      ;; set parent if necessary 
      (adopt self input)
      (setf inputs 
	    (nconc (list (first inputs) 
			 (second inputs)
			 input)
		   (nthcdr 2 inputs)))
      ;; drop last item in scrollback
      (let ((len (length inputs)))
	(when (> len *minibuffer-rows*)
	  (dolist (item (subseq inputs *minibuffer-rows*))
	    (destroy item))
	  (setf inputs (subseq inputs 0 (1- len)))))
      ;; 
      (add-item %sidebar (duplicate-safely input)))))


(defparameter *minibuffer-background-color* "gray20")

(define-method draw minibuffer ()
  (with-fields (inputs x y height width) self
    (draw-box (window-x) y *gl-screen-width* height :color *minibuffer-background-color*)
    (mapc #'draw inputs)
    (draw %sidebar)))

(define-method hit minibuffer (x y)
  (or (hit %sidebar x y)
      (when (within-extents x y %x %y (+ %x %width) (+ %y %height))
	self)))


;;; minibuffer.lisp ends here
