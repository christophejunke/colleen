#|
  This file is a part of Colleen
  (c) 2013 TymoonNET/NexT http://tymoon.eu (shinmera@tymoon.eu)
  Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package :org.tymoonnext.colleen)

(defclass module ()
  ((%active :initform NIL :accessor active :allocation :class)
   (%handlers :initform (make-hash-table :test 'equal) :reader handlers :allocation :class)
   (%commands :initform (make-hash-table :test 'equal) :reader commands :allocation :class)
   (%groups :initform (make-hash-table :test 'equal) :reader groups :allocation :class)
   (%threads :initform (make-hash-table :test 'equalp) :accessor threads))
  (:documentation "Base module class."))

(defmethod active ((null null)) NIL)
(defmethod active ((module-name symbol))
  (active (get-module module-name)))
(defmethod active ((module-name string))
  (active (get-module module-name)))

(defmethod print-object ((module module) stream)
  (format stream "<[~a]>" (class-name (class-of module))))

(defclass command ()
  ((%name :initform (error "Name required.") :initarg :name :accessor name)
   (%args :initform () :initarg :arguments :accessor cmd-args)
   (%func :initform (error "Function required.") :initarg :function :accessor cmd-fun)
   (%docu :initform NIL :initarg :documentation :accessor docu))
  (:documentation "Class for module commands."))

(defgeneric start (module)
  (:documentation "Start the module and activate it for use.")
  (:method :around ((module module))
    (call-next-method)
    (setf (active module) T)
    module)

  (:method ((module module))))

(defgeneric stop (module)
  (:documentation "Stop the module and clean everything up.")
  (:method :around ((module module))
    (setf (active module) NIL)
    (loop for uid being the hash-keys of (threads module)
          for thread being the hash-values of (threads module)
          do (if (thread-alive-p thread)
                 (interrupt-thread thread #'(lambda () (error 'module-stop)))
                 (remhash uid (threads module))))
    (call-next-method)
    module)

  (:method ((module module))))

(defgeneric add-group (module group)
  (:documentation "Register a new group in the module.")
  (:method ((module module) group)
    (let ((group (string-downcase group)))
      (unless (gethash group (groups module))
        (setf (gethash group (groups module)) (make-hash-table :test 'equal))))))

(defgeneric add-group-command (module group command args method &optional documentation)
  (:documentation "Add a new command to a group in the module.")
  (:method ((module module) group command args method &optional documentation)
    (let ((command (string-downcase command))
          (group (string-downcase group)))
      (assert (not (null (gethash group (groups module)))))
      (setf (gethash command (gethash group (groups module)))
            (make-instance 'command :name command :arguments args :function method :documentation documentation)))))

(defgeneric add-command (module command args method &optional documentation)
  (:documentation "Add a new command to the module.")
  (:method ((module module) command args method &optional documentation)
    (let ((command (string-downcase command)))
      (setf (gethash command (commands module))
            (make-instance 'command :name command :arguments args :function method :documentation documentation)))))

(defgeneric add-handler (module eventtype method)
  (:documentation "Add a new event handler to the module.")
  (:method ((module module) eventtype method)
    (setf (gethash (string-downcase eventtype) (handlers module)) method)))

(defmacro with-module-thread (module &body thread-body)
  (let ((uidgens (gensym "UUID"))
        (modgens (gensym "MODULE"))
        (modnamegens (gensym "MODULE-NAME")))
    `(let* ((,uidgens (princ-to-string (uuid:make-v4-uuid)))
            (,modgens ,module)
            (,modnamegens (name ,modgens)))
       (setf (gethash ,uidgens (threads ,modgens))
             (make-thread #'(lambda ()
                              (handler-case
                                  ,@thread-body
                                (module-stop (err)
                                  (declare (ignore err))
                                  (v:debug ,modnamegens "Received module-stop condition, leaving thread ~a." ,uidgens))
                                (error (err)
                                  (v:severe ,modnamegens "Unexpected error at thread-level: ~a" err)
                                  (when *debugger*
                                    (invoke-debugger err))))
                              (v:trace ,modnamegens "Ending thread ~a." ,uidgens)
                              (remhash ,uidgens (threads ,modgens)))
                          :initial-bindings `((*current-server* . ,*current-server*)
                                              (*servers* . ,*servers*))))
       ,uidgens)))

(defgeneric dispatch (module event &key &allow-other-keys)
  (:documentation "Handle a new event and distribute it to the registered handler functions.")
  (:method ((module T) (event event) &key ignore-errors)
    (loop for module being the hash-values of *bot-modules*
          if (active module)
            do (when (if ignore-errors 
                         (ignore-errors (dispatch module event)) 
                         (dispatch module event))
                 (return-from dispatch))))

  (:method ((module module) (event event) &key)
    (let ((handler (gethash (string-downcase (class-name (class-of event))) (handlers module))))
      (when handler
        (v:trace (name module) "Dispatching: ~a" event)
        (with-module-thread module
          (funcall handler module event))
        NIL)))

  (:method ((module module) (event command-event) &key)
    (let ((handler (gethash (command event) (commands module))))
      (when handler
        (v:trace (name module) "Dispatching: ~a" event)
        (with-module-thread module
          (handler-bind
              ((error #'(lambda (err)
                          (v:warn (find-symbol (string-upcase (class-name (class-of module))) :KEYWORD) "Unhandled condition: ~a" err)
                          (respond event "Unhandled condition: ~a" err)
                          (when *debugger*
                            (invoke-debugger err)))))
            (handler-case
                (funcall (cmd-fun handler) module event)
              (not-authorized (err)
                (v:warn (name *current-server*) "User ~a attempted to execute ~a, but is not authorized!" (nick (event err)) (command (event err)))
                (respond (event err) (fstd-message (event err) :not-authorized)))
              (invalid-arguments (err)
                (v:warn (name *current-server*) "Invalid arguments to ~a, expected ~a" (command err) (argslist err))
                (respond event "Invalid arguments. Expected: ~a" (argslist err))))))
        T))))

(defgeneric get-command (module commandname)
  (:documentation "Get the command instance associated with the command name.")
  (:method ((module module) commandname)
    (gethash (string-downcase commandname) (commands module))))

(defgeneric get-group (module group-symbol)
  (:documentation "Return the hash-map defining the group.")
  (:method ((module module) group)
    (gethash (string-downcase group) (groups module))))

(defgeneric get-group-command (module group-symbol commandname)
  (:documentation "Return the function symbol to the group-command.")
  (:method ((module module) group commandname)
    (let ((group (get-group module group)))
      (when group (gethash commandname group)))))

(defgeneric get-module (module-name)
  (:documentation "Return a module by its name.")
  (:method ((module-name string))
    (let ((symbol (find-symbol (string-upcase module-name) :KEYWORD)))
      (when symbol
        (get-module symbol))))

  (:method ((module-name symbol))
    (unless (keywordp module-name)
      (get-module (symbol-name module-name)))
    (gethash module-name *bot-modules*)))

(defmethod name ((module module))
  (find-symbol (format NIL "~a" (class-name (class-of module))) :KEYWORD))

(defun package-symbol (package)
  "Returns the symbol of a package."
  (let ((name (package-name package)))
    (or (find-symbol name "KEYWORD")
        (intern name "KEYWORD"))))

(defun get-current-module (&optional (package *package*))
  "Returns the module of the current package context."
  (get (package-symbol package) :module))

(defun display-help (module group event)
  "Responds with help about a specific command or the entire group."
  (if (cmd-args event)
      (let ((group-command (get-group-command module group (first (cmd-args event)))))
        (when group-command
          (respond event "~a" (docu group-command))
          (respond event "USAGE: ~a ~a ~{~a~^ ~}" group (name group-command) (cmd-args group-command))))
      (progn
        (respond event (docu (get-command module group)))
        (respond event "Commands: ~{~a ~}" (hash-table-keys (get-group module group))))))

(defmacro define-module (name direct-superclasses direct-slots &body options)
  "Define a new module class. See DEFCLASS."
  (let ((instancesym (gensym "INSTANCE"))
        (definedsym (gensym "DEFINED")))
    `(progn 
       (defclass ,name (module ,@direct-superclasses)
         ((%active :initform NIL :reader active :allocation :class)
          (%handlers :initform (make-hash-table :test 'equal) :reader handlers :allocation :class)
          (%commands :initform (make-hash-table :test 'equal) :reader commands :allocation :class)
          (%groups :initform (make-hash-table :test 'equal) :reader groups :allocation :class)
          ,@direct-slots)
         ,@options)
       (let ((,instancesym (make-instance ',name))
             (,definedsym (gethash ,(intern (string-upcase name) "KEYWORD") *bot-modules*)))
         (when (active ,definedsym)
           (v:warn :colleen "Redefining started module ~a. Performing automatic stop and start." ,definedsym)
           (stop ,definedsym))
         (setf (get (package-symbol *package*) :module) ,instancesym
               (gethash ,(intern (string-upcase name) "KEYWORD") *bot-modules*) ,instancesym)
         (when (active ,definedsym) (start ,instancesym)))))) 

(defmacro define-group (name &key (module `(get-current-module)) documentation)
  "Define a new command group for a module.
NAME designates the command name as a symbol.
MODULE binds the group to this module, defaults to the current package-context module.
DOCUMENTATION is an optional string giving some information about the command group."
  (let ((documentation (if documentation (format NIL "~a (Group)" documentation) "(Group)")))
    (destructuring-bind (method &optional (command method)) (if (listp name) name (list name))
      (setf command (string-downcase command))
      `(progn
         (add-group ,module ,command)
         (add-command 
          ,module ,command '(&rest rest) 
          #'(lambda (module event)
              (let* ((subcmd (or (first (cmd-args event)) "help"))
                     (command (gethash subcmd (gethash ,command (groups module)))))
                (if command
                    (progn
                      (setf (command event) (format NIL ,(format NIL "~a ~~a" command) subcmd))
                      (setf (cmd-args event) (cdr (cmd-args event)))
                      (funcall (cmd-fun command) module event))
                    (progn
                      (v:debug :colleen "~a No method found for ~a!" module subcmd)
                      (respond event (fstd-message event :no-command))))))
          ,documentation)
         (define-command (,command help) (&rest args) (:documentation "Display command information." :module ,module :modulevar module)
           (declare (ignore args))
           (display-help module ',command event))))))

(defmacro define-command (name (&rest args) (&key authorization documentation (eventvar 'event) (module `(get-current-module)) (modulevar 'module)) &body body)
  "Define a new command for a module.
NAME is either the direct command name or a list of form (GROUP NAME).
ARGS is a lambda-list org arguments expected for the command. Note that &key will not work.
AUTHORIZATION, when not-NIL states that this command can only be used by users on the authenticated list. See AUTH-P.
DOCUMENTATION is an optional string giving some information about the command.
EVENTVAR is the symbol that the event variable is bound to in the body. Defaults to EVENT.
MODULE binds the command to this module, defaulting to the current package-context module.
MODULEVAR is the symbol that the module variable is bound to in the body. Defaults to MODULE."
  (destructuring-bind (group &optional (name group n-s-p)) (if (listp name) name (list name))
    (unless n-s-p (setf group NIL))
    (let ((methodgens (gensym "METHOD"))
          (errgens (gensym "ERROR")))
      `(let ((,methodgens
               (lambda (,modulevar ,eventvar)
                 (declare (ignorable ,modulevar))
                 ,(when authorization
                    `(unless (auth-p (nick ,eventvar))
                       (error 'not-authorized :event ,eventvar)))
                 (handler-case
                     (destructuring-bind (,@args) (cmd-args ,eventvar)
                       ,@body)
                   ((or #+sbcl sb-kernel::arg-count-error 
                        #+sbcl sb-kernel::defmacro-lambda-list-broken-key-list-error
                        #+cmucl LISP::DEFMACRO-LL-ARG-COUNT-ERROR
                        #+cmucl LISP::DEFMACRO-LL-BROKEN-KEY-LIST-ERROR
                        #+abcl program-error
                        #+ccl CCL::SIMPLE-PROGRAM-ERROR
                        end-of-file) (,errgens)
                     (declare (ignore ,errgens))
                     (error 'invalid-arguments :command ',name :argslist ',args))))))
         ,(if group
              `(add-group-command ,module ',group ',name ',args ,methodgens ,documentation)
              `(add-command ,module ',name ',args ,methodgens ,documentation))))))

(defmacro define-handler (event-type (&key (module `(get-current-module)) (modulevar 'module)) &body body)
  "Define a new event handler for a module.
EVENT-TYPE designates the event-class that should be handled or a list of the form (EVENT-TYPE EVENTVAR).
MODULE binds the handler to this module, defaulting to the current package-context module.
MODULEVAR is the symbol that the module variable is bound to in the body. Defaults to MODULE."
  (destructuring-bind (event-type &optional (eventvar event-type)) (if (listp event-type) event-type (list event-type))
    `(add-handler 
      ,module ',event-type
      (lambda (,modulevar ,eventvar)
        (declare (ignorable ,modulevar))
        ,@body))))

(defun start-module (&rest module-names)
  "Start up one or more modules. Each module name should be a symbol or string."
  (dolist (module-name module-names)
    (unless (keywordp module-name) (setf module-name (find-symbol (string-upcase module-name) "KEYWORD")))
    (with-simple-restart (skip "Skip starting the module.")
      (let ((module (get-module module-name)))
        (assert (not (null module)) () "Module ~a not found!" module-name)
        (with-simple-restart (force "Force starting the module.")
          (assert (not (active module)) () "Module ~a already started!" module-name))
        (v:info module-name "Starting...")
        (loop until (with-simple-restart (retry "Retry starting the module.")
                      (start module)))
        module))))

(defun stop-module (&rest module-names)
  "Stop one or more modules. Each module name should be a symbol or string."
  (dolist (module-name module-names)
    (unless (keywordp module-name) (setf module-name (find-symbol (string-upcase module-name) "KEYWORD")))
    (with-simple-restart (skip "Skip stopping the module.")
      (let ((module (get-module module-name)))
        (assert (not (null module)) () "Module ~a not found!" module-name)
        (with-simple-restart (force "Force stopping the module.")
          (assert (not (not (active module))) () "Module ~a already stopped!" module-name))
        (v:info module-name "Stopping...")
        (loop until (with-simple-restart (retry "Retry stopping the module.")
                      (stop module)))
        module))))
