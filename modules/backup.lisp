#|
 This file is a part of Colleen
 (c) 2013 TymoonNET/NexT http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package :org.tymoonnext.colleen)
(defpackage org.tymoonnext.colleen.mod.backup
  (:use :cl :colleen :events))
(in-package :org.tymoonnext.colleen.mod.backup)

(defparameter *config-dir* (merge-pathnames "config/" (asdf:system-source-directory :colleen)))

(define-module backup ()
    ((%interval :initform NIL :accessor interval)
     (%directory :initform NIL :accessor backup-directory)
     (%timer :initform NIL :accessor timer))
  (:documentation "Automatic periodic configuration backup module."))

(defmethod start ((backup backup))
  (setf (interval backup) (config-tree :backup :interval)
        (backup-directory backup) (parse-namestring (config-tree :backup :directory))
        (timer backup) (trivial-timers:make-timer #'backup :name "Backup-Thread"))
  (start-timer))

(defmethod stop ((backup backup))
  (trivial-timers:unschedule-timer (timer backup))
  (setf (config-tree :backup :interval) (interval backup)
        (config-tree :backup :directory) (namestring (backup-directory backup))
        (timer backup) NIL))

(defun backup ()
  (let* ((directory (backup-directory (get-module :backup)))
         (timestamp (local-time:format-timestring NIL (local-time:now) :format '((:year 4) #\. (:month 2) #\. (:day 2) #\Space (:hour 2) #\: (:min 2) #\: (:sec 2))))
         (target-dir (merge-pathnames (format NIL "~a/" timestamp) directory))
         (running-modules (remove-if-not #'active (remove :backup (alexandria:hash-table-keys *bot-modules*)))))
    (flet ((copy-fun (pathname)
             (let ((target-path (merge-pathnames (subseq (namestring pathname) (length (namestring *config-dir*))) target-dir)))
               (if (cl-fad:directory-pathname-p pathname)
                   (progn
                     (v:debug :backup "Ensuring directory ~a" target-path)
                     (ensure-directories-exist target-path))
                   (progn
                     (v:debug :backup "Copying file ~a" pathname)
                     (cl-fad:copy-file pathname target-path))))))
      (v:info :backup "Starting backup.")
      (v:debug :backup "Stopping all active modules...")
      (dolist (module running-modules)
        (handler-bind ((error #'(lambda (err)
                                  (v:error :backup "Error stopping module ~a: ~a" module err)
                                  (invoke-restart 'skip))))
          (stop-module module)))
      (v:debug :backup "Copying folder ~a to ~a..." (namestring *config-dir*) (namestring target-dir))
      (copy-fun *config-dir*)
      (cl-fad:walk-directory *config-dir* #'copy-fun :directories T)
      (v:debug :backup "Starting all previously active modules...")
      (dolist (module running-modules)
        (handler-bind ((error #'(lambda (err)
                                  (v:error :backup "Error starting module ~a: ~a" module err)
                                  (invoke-restart 'skip))))
          (start-module module)))
      (v:info :backup "Backup complete."))))

(defun restore (backup-name)
  (let* ((directory (backup-directory (get-module :backup)))
         (source-dir (merge-pathnames (format NIL "~a/" backup-name) directory))
         (running-modules (remove-if-not #'active (remove :backup (alexandria:hash-table-keys *bot-modules*)))))
    (assert (cl-fad:file-exists-p source-dir) () "Backup ~a does not exist!" backup-name)
    (flet ((copy-fun (pathname)
             (let ((target-path (merge-pathnames (subseq (namestring pathname) (length (namestring source-dir))) *config-dir*)))
               (if (cl-fad:directory-pathname-p pathname)
                   (progn
                     (v:debug :backup "Ensuring directory ~a" target-path)
                     (ensure-directories-exist target-path))
                   (progn
                     (v:debug :backup "Copying file ~a" pathname)
                     (cl-fad:copy-file pathname target-path))))))
      (v:info :backup "Starting restore.")
      (v:debug :backup "Stopping all active modules...")
      (dolist (module running-modules)
        (handler-bind ((error #'(lambda (err)
                                  (v:error :backup "Error stopping module ~a: ~a" module err)
                                  (invoke-restart 'skip))))
          (stop-module module)))
      (v:debug :backup "Deleting old config folder...")
      (cl-fad:delete-directory-and-files *config-dir* :if-does-not-exist :ignore)
      (v:debug :backup "Copying folder ~a to ~a..." (namestring source-dir) (namestring *config-dir*))
      (copy-fun source-dir)
      (cl-fad:walk-directory source-dir #'copy-fun :directories T)
      (v:debug :backup "Starting all previously active modules...")
      (dolist (module running-modules)
        (handler-bind ((error #'(lambda (err)
                                  (v:error :backup "Error starting module ~a: ~a" module err)
                                  (invoke-restart 'skip))))
          (start-module module)))
      (v:info :backup "Restore complete."))))

(defun start-timer ()
  (let ((backup (get-module :backup)))
    (when (and (timer backup) (interval backup))
      (when (trivial-timers:timer-scheduled-p (timer backup))
        (v:info :backup "Interrupting previously scheduled timer.")
        (trivial-timers:unschedule-timer (timer backup)))
      (v:info :backup "Starting backup timer... (Interval of ~d seconds)" (interval backup))
      (trivial-timers:schedule-timer (timer backup) 1 :repeat-interval (interval backup)))))

(defun last-backup ()
  (let ((backups (sort (remove-if-not #'cl-fad:directory-pathname-p (cl-fad:list-directory *config-dir*))
                       #'(lambda (a b) (string< (namestring a) (namestring b))))))
    (cdr (last (pathname-directory (cdr (last backups)))))))

(defun format-time-since (secs)
  (multiple-value-bind (s m h dd yy) (decode-universal-time secs)
    (setf yy (- yy 1) dd (- dd 1) h (- h 1))
    (format NIL "~@[~D years ~]~@[~D days ~]~@[~D hours ~]~@[~D minutes ~]~@[~D seconds~]"
            (unless (= yy 0) yy) (unless (= dd 0) dd) (unless (= h 0) h) (unless (= m 0) m) (unless (= s 0) s))))

(define-group backup :documentation "Set backup settings or perform backup actions.")

(define-command (backup interval) (&optional interval (metric "d")) (:authorization T :documentation "Change or view the backup interval.")
  (assert (find metric '("w" "d" "h" "m" "s") :test #'string-equal) () "Metric has to be one of (w  d h m s).")
  (when interval
    (setf (interval module)
          (cond ((string= metric "w") (* (parse-integer interval) 60 60 24 7))
                ((string= metric "d") (* (parse-integer interval) 60 60 24))
                ((string= metric "h") (* (parse-integer interval) 60 60))
                ((string= metric "m") (* (parse-integer interval) 60))
                ((string= metric "s") (parse-integer interval)))))
  (respond event "Current backup interval: ~a" (format-time-since (interval module))))

(define-command (backup last) () (:documentation "Show the date of the last performed backup.")
  (respond event "Last backup was: ~a" (last-backup)))

(define-command (backup now) () (:authorization T :documentation "Perform a backup now.")
  (respond event "Backing up now. All modules will be restarted in the process.")
  (backup)
  (respond event "Backup done."))

(define-command (backup restore) (&rest datestring) (:authorization T :documentation "Restore an existing backup.")
  (respond event "Restoring now. All modules will be restarted in the process.")
  (restore (if datestring (format NIL "~{~a~^ ~}" datestring) (last-backup)))
  (respond event "Restore complete."))
