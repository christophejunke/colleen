#|
  This file is a part of Colleen
  (c) 2013 TymoonNET/NexT http://tymoon.eu (shinmera@tymoon.eu)
  Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package :org.tymoonnext.colleen)
(defpackage org.tymoonnext.colleen.mod.markov
  (:use :cl :colleen :alexandria)
  (:shadowing-import-from :colleen :restart))
(in-package :org.tymoonnext.colleen.mod.markov)

(defvar *registry-file* (merge-pathnames "markov-registry.json" (merge-pathnames "config/" (asdf:system-source-directory :colleen))))

(define-module markov ()
  ((%probability :initarg :probability :initform 25 :accessor probability)
   (%ignored-users :initarg :ignored-users :initform () :accessor ignored-users)
   (%registry :initarg :registry :initform (make-hash-table :test 'equal) :accessor registry)))

(defmethod start ((markov markov))
  (if (config-tree :markov :probability)
      (setf (probability markov) (config-tree :markov :probability)))
  (if (config-tree :markov :ignored-users)
      (setf (ignored-users markov) (config-tree :markov :ignored-users)))
  (with-open-file (stream *registry-file* :if-does-not-exist NIL)
    (when stream
      (setf (registry markov) (yason:parse stream))))
  markov)

(defmethod stop ((markov markov))
  (setf (config-tree :markov :probability) (probability markov)
        (config-tree :markov :ignored-users) (ignored-users markov))
  (with-open-file (stream *registry-file* :direction :output :if-does-not-exist :create :if-exists :supersede)
    (cl-json:encode-json (registry markov) stream)))

(define-handler on-message markov (privmsg-event event)
  (when (char= (aref (channel event) 0) #\#)
    (unless (char= (aref (message event) 0) #\!)
      (learn markov (message event)))

    (when (< (random 100) (probability markov))
      (let ((wordlist (split-sequence:split-sequence #\Space (message event) :remove-empty-subseqs T)))
        (when (cdr wordlist)
          (let ((response (generate-string markov (first wordlist) (second wordlist))))
            (when (and response (not (string= (message event) response)))
              (respond event response))))))))

(define-group markov markov (:documentation "Interact with the markov chain."))

(define-command (%ignore ignore) markov (&rest nicks) (:authorization T :group 'markov :documentation "Add users to the ignore list.")
  (dolist (nick nicks)
    (pushnew nick (ignored-users markov) :test #'string-equal))
  (respond event "Users have been put on the ignore list."))

(define-command unignore markov (&rest nicks) (:authorization T :group 'markov :documentation "Remove users from the ignore list.")
  (setf (ignored-users markov) 
        (delete-if #'(lambda (nick) (find nick nicks :test #'string-equal)) (ignored-users markov)))
  (respond event "Users have been removed from the ignore list."))

(define-command list-ignored markov () (:authorization T :group 'markov :documentation "List all ignored users.")
  (respond event "Ignored users: ~:[None~;~:*~{~a~^, ~}~]" (ignored-users markov)))

(define-command (%probability probability) markov (&optional new-value) (:authorization T :group 'markov :documentation "Set or view the probability of invoking markov.")
  (when new-value
    (setf (probability markov) (parse-integer new-value :junk-allowed T)))
  (respond event "Probability: ~a" (probability markov)))

(define-command say markov (&optional arg1 arg2) (:group 'markov :documentation "Let the bot say something.")
  (let ((message (generate-string markov (or arg1 "!NONWORD!") (or arg2 "!NONWORD!"))))
    (if message
        (respond event message)
        (respond event (fstd-message event :markov-nothing)))))

(defmethod learn ((markov markov) message)
  (let ((wordlist (split-sequence:split-sequence #\Space message :remove-empty-subseqs T)))
    (when (cddr wordlist)
      (v:debug :markov "Learning from: ~a" message)
      (loop for word1 = "!NONWORD!" then word2
         for word2 = "!NONWORD!" then word3
         for k = (format NIL "~a ~a" word1 word2)
         for word3 in wordlist
         do (push word3 (gethash k (registry markov)))
         finally (push "!NONWORD!" (gethash k (registry markov)))))))

(defgeneric generate-string (markov &optional word1 word2))
(defmethod generate-string ((markov markov) &optional (word1 "!NONWORD!") (word2 "!NONWORD!"))
  (let* ((output (if (string= word1 "!NONWORD!") "" (format NIL "~a ~a" word1 word2))))
    (unless (string= word1 "!NONWORD!")
      (let ((wordlist (remove "!NONWORD!" (gethash output (registry markov)) :test #'string=)))
        (when wordlist
          (let ((word3 (random-elt wordlist)))
            (setf output (format NIL "~a ~a" output word3)
                  word1 word2
                  word2 word3)))))
    (loop for i from 0 below 50
       for wordlist = (gethash (format NIL "~a ~a" word1 word2) (registry markov))
       while wordlist
       for word3 = (random-elt wordlist)
       until (string= word3 "!NONWORD!")
       do (setf output (format NIL "~a ~a" output word3)
                word1 word2
                word2 word3))
    (setf output (string-trim '(#\Space #\Tab #\Return #\Linefeed) output))
    (v:trace :markov "Generated string: ~a" output)
    (if (> (length (split-sequence:split-sequence #\Space output)) 0) output)))