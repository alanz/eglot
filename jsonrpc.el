;;; jsonrpc.el --- JSON-RPC library                  -*- lexical-binding: t; -*-

;; Copyright (C) 2018 Free Software Foundation, Inc.

;; Author: João Távora <joaotavora@gmail.com>
;; Maintainer: João Távora <joaotavora@gmail.com>
;; URL: https://github.com/joaotavora/eglot
;; Keywords: processes, languages, extensions

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Originally extracted from eglot.el (Emacs LSP client)
;;
;; This library implements the JSONRPC 2.0 specification as described
;; in http://www.jsonrpc.org/.  As the name suggests, JSONRPC is a
;; generic Remote Procedure Call protocol designed around JSON
;; objects.
;;
;; Quoting from the spec: "[JSONRPC] is transport agnostic in that the
;; concepts can be used within the same process, over sockets, over
;; http, or in many various message passing environments."
;;
;; To approach this agnosticism, jsonrpc.el uses objects derived from
;; a base `jsonrpc-connection' class, which is "abstract" or "virtual"
;; (in modern OO parlance) and represents the connection to the remote
;; JSON endpoint.  Equally abstract operations such as sending and
;; receiving are modelled as generic functions, so JSONRPC
;; applications operating over arbitrary transport infrastructures can
;; specify a subclass of `jsonrpc-connection' and write specific
;; methods for it.
;;
;; The `jsonrpc-connection' constructor is the most generic entry
;; point for these uses.  However, for convenience, jsonrpc.el comes
;; built-in with `jsonrpc-process-connection' class for talking to
;; local subprocesses (through stdin/stdout) and TCP hosts using
;; sockets.  This uses some basic HTTP-style enveloping headers for
;; JSON objects sent over the wire.  For an example of an application
;; using this transport scheme on top of JSONRPC, see for example the
;; Language Server Protocol
;; (https://microsoft.github.io/language-server-protocol/specification).
;;
;; Whatever the method used to obtain a `jsonrpc-connection', it is
;; given to `jsonrpc-notify', `jsonrpc-request' and
;; `jsonrpc-async-request' as a way of contacting the connected remote
;; endpoint.
;;
;; For handling remotely initiated contacts, `jsonrpc-connection'
;; objects hold dispatcher functions that the application should pass
;; to object's constructor if it is interested in those messages.
;;
;; The JSON objects are passed to the dispatcher after being read by
;; `jsonrpc--json-read', which may use either the longstanding json.el
;; library or a newer and faster json.c library if it is available.
;;
;; JSON objects are exchanged as plists: plists are handed to the
;; dispatcher functions and, likewise, plists should be given to
;; `jsonrpc-notify', `jsonrpc-request' and `jsonrpc-async-request'.
;;
;; To facilitate handling plists, this library make liberal use of
;; cl-lib.el and suggests (but doesn't force) its clients to do the
;; same.  A macro `jsonrpc-lambda' can be used to create a lambda for
;; destructuring a JSON-object like in this example:
;;
;;  (jsonrpc-async-request
;;   myproc :frobnicate `(:foo "trix")
;;   :success-fn (jsonrpc-lambda (&key bar baz &allow-other-keys)
;;                 (message "Server replied back %s and %s!"
;;                          bar baz))
;;   :error-fn (jsonrpc-lambda (&key code message _data)
;;               (message "Sadly, server reports %s: %s"
;;                        code message)))
;;
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'eieio)
(require 'subr-x)
(require 'warnings)
(require 'pcase)
(require 'ert) ; to escape a `condition-case-unless-debug'
(require 'array) ; xor

(defvar jsonrpc-find-connection-functions nil
  "Special hook to find an active JSON-RPC connection.")

(defun jsonrpc-current-connection ()
  "The current logical JSON-RPC connection."
  (run-hook-with-args-until-success 'jsonrpc-find-connection-functions))

(defun jsonrpc-current-connection-or-lose ()
  "Return the current JSON-RPC connection or error."
  (or (jsonrpc-current-connection)
      (jsonrpc-error "No current JSON-RPC connection")))

(define-error 'jsonrpc-error "jsonrpc-error")

(defun jsonrpc-error (format &rest args)
  "Error out with FORMAT and ARGS.
If invoked inside a dispatcher function, this function is suitable
for replying to the remote endpoint with a -32603 error code and
FORMAT as the message."
  (signal 'error
          (list (apply #'format-message (concat "[jsonrpc] " format) args))))

(defun jsonrpc-message (format &rest args)
  "Message out with FORMAT with ARGS."
  (message "[jsonrpc] %s" (apply #'format format args)))

(defun jsonrpc--debug (server format &rest args)
  "Debug message for SERVER with FORMAT and ARGS."
  (jsonrpc-log-event
   server (if (stringp format)`(:message ,(format format args)) format)))

(defun jsonrpc-warn (format &rest args)
  "Warning message with FORMAT and ARGS."
  (apply #'jsonrpc-message (concat "(warning) " format) args)
  (let ((warning-minimum-level :error))
    (display-warning 'jsonrpc
                     (apply #'format format args)
                     :warning)))

;;;###autoload
(defclass jsonrpc-connection ()
  ((name
    :accessor jsonrpc-name
    :initarg :name
    :documentation "A name for the connection")
   (-request-dispatcher
    :accessor jsonrpc--request-dispatcher
    :initform #'ignore
    :initarg :request-dispatcher
    :documentation "Dispatcher for remotely invoked requests.")
   (-notification-dispatcher
    :accessor jsonrpc--notification-dispatcher
    :initform #'ignore
    :initarg :notification-dispatcher
    :documentation "Dispatcher for remotely invoked notifications.")
   (status
    :initform `(:unknown nil) :accessor jsonrpc-status
    :documentation "Status (WHAT SERIOUS-P) as declared by the server.")
   (-request-continuations
    :initform (make-hash-table)
    :accessor jsonrpc--request-continuations
    :documentation "A hash table of request ID to continuation lambdas.")
   (-events-buffer
    :accessor jsonrpc--events-buffer
    :documentation "A buffer pretty-printing the JSON-RPC RPC events")
   (-deferred-actions
    :initform (make-hash-table :test #'equal)
    :accessor jsonrpc--deferred-actions
    :documentation "Map (DEFERRED BUF) to (FN TIMER ID).  FN is\
a saved DEFERRED `async-request' from BUF, to be sent not later\
than TIMER as ID.")
   (-next-request-id
    :initform 0
    :accessor jsonrpc--next-request-id
    :documentation "Next number used for a request"))
  :documentation "Base class representing a JSONRPC connection.
The following initargs are accepted:

:NAME (mandatory), a string naming the connection

:REQUEST-DISPATCHER (optional), a function of three
arguments (CONN METHOD PARAMS) for handling JSONRPC requests.
CONN is a `jsonrpc-connection' object, method is a symbol, and
PARAMS is a plist representing a JSON object.  The function is
expected to call `jsonrpc-reply' or signal an error of type
`jsonrpc-error'.

:NOTIFICATION-DISPATCHER (optional), a function of three
arguments (CONN METHOD PARAMS) for handling JSONRPC
notifications.  CONN, METHOD and PARAMS are the same as in
:REQUEST-DISPATCHER.")

;;;###autoload
(defclass jsonrpc-process-connection (jsonrpc-connection)
  ((-process
    :initarg :process :accessor jsonrpc--process
    :documentation "Process object wrapped by the this connection.")
   (-expected-bytes
    :accessor jsonrpc--expected-bytes
    :documentation "How many bytes declared by server")
   (-on-shutdown
    :accessor jsonrpc--on-shutdown
    :initform #'ignore
    :initarg :on-shutdown
    :documentation "Function run when the process dies."))
  :documentation "A JSONRPC connection over an Emacs process.
The following initargs are accepted:

:PROCESS (mandatory), a live running Emacs process object or a
function of no arguments producing one such object.  The process
represents either a pipe connection to locally running process or
a stream connection to a network host.  The remote endpoint is
expected to understand JSONRPC messages with basic HTTP-style
enveloping headers such as \"Content-Length:\".

:ON-SHUTDOWN (optional), a function of one argument, the
connection object, called when the process dies .")

(cl-defmethod initialize-instance ((conn jsonrpc-process-connection) slots)
  (cl-call-next-method)
  (let* ((proc (plist-get slots :process))
         (proc (if (functionp proc) (funcall proc) proc))
         (buffer (get-buffer-create (format "*%s output*" (process-name proc))))
         (stderr (get-buffer-create (format "*%s stderr*" (process-name proc)))))
    (setf (jsonrpc--process conn) proc)
    (set-process-buffer proc buffer)
    (process-put proc 'jsonrpc-stderr stderr)
    (set-process-filter proc #'jsonrpc--process-filter)
    (set-process-sentinel proc #'jsonrpc--process-sentinel)
    (with-current-buffer (process-buffer proc)
      (set-marker (process-mark proc) (point-min))
      (let ((inhibit-read-only t)) (erase-buffer) (read-only-mode t) proc))
    (process-put proc 'jsonrpc-connection conn)))

(defmacro jsonrpc-obj (&rest what)
  "Make WHAT a suitable argument for `json-encode'."
  (declare (debug (&rest form)))
  ;; FIXME: maybe later actually do something, for now this just fixes
  ;; the indenting of literal plists, i.e. is basically `list'
  `(list ,@what))

(defun jsonrpc--json-read ()
  "Read JSON object in buffer, move point to end of buffer."
  ;; TODO: I guess we can make these macros if/when jsonrpc.el
  ;; goes into Emacs core.
  (cond ((fboundp 'json-parse-buffer) (json-parse-buffer
                                       :object-type 'plist
                                       :null-object nil
                                       :false-object :json-false))
        (t                            (let ((json-object-type 'plist))
                                        (json-read)))))

(defun jsonrpc--json-encode (object)
  "Encode OBJECT into a JSON string."
  (cond ((fboundp 'json-serialize) (json-serialize
                                    object
                                    :false-object :json-false
                                    :null-object nil))
        (t                         (let ((json-false :json-false)
                                         (json-null nil))
                                     (json-encode object)))))

(defun jsonrpc--process-sentinel (proc change)
  "Called when PROC undergoes CHANGE."
  (let ((connection (process-get proc 'jsonrpc-connection)))
    (jsonrpc--debug connection `(:message "Connection state changed" :change ,change))
    (when (not (process-live-p proc))
      (with-current-buffer (jsonrpc-events-buffer connection)
        (let ((inhibit-read-only t))
          (insert "\n----------b---y---e---b---y---e----------\n")))
      ;; Cancel outstanding timers
      (maphash (lambda (_id triplet)
                 (pcase-let ((`(,_success ,_error ,timeout) triplet))
                   (when timeout (cancel-timer timeout))))
               (jsonrpc--request-continuations connection))
      (unwind-protect
          ;; Call all outstanding error handlers
          (maphash (lambda (_id triplet)
                     (pcase-let ((`(,_success ,error ,_timeout) triplet))
                       (funcall error `(:code -1 :message "Server died"))))
                   (jsonrpc--request-continuations connection))
        (jsonrpc-message "Server exited with status %s" (process-exit-status proc))
        (delete-process proc)
        (funcall (jsonrpc--on-shutdown connection) connection)))))

(defun jsonrpc--process-filter (proc string)
  "Called when new data STRING has arrived for PROC."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let* ((inhibit-read-only t)
             (connection (process-get proc 'jsonrpc-connection))
             (expected-bytes (jsonrpc--expected-bytes connection)))
        ;; Insert the text, advancing the process marker.
        ;;
        (save-excursion
          (goto-char (process-mark proc))
          (insert string)
          (set-marker (process-mark proc) (point)))
        ;; Loop (more than one message might have arrived)
        ;;
        (unwind-protect
            (let (done)
              (while (not done)
                (cond
                 ((not expected-bytes)
                  ;; Starting a new message
                  ;;
                  (setq expected-bytes
                        (and (search-forward-regexp
                              "\\(?:.*: .*\r\n\\)*Content-Length: \
*\\([[:digit:]]+\\)\r\n\\(?:.*: .*\r\n\\)*\r\n"
                              (+ (point) 100)
                              t)
                             (string-to-number (match-string 1))))
                  (unless expected-bytes
                    (setq done :waiting-for-new-message)))
                 (t
                  ;; Attempt to complete a message body
                  ;;
                  (let ((available-bytes (- (position-bytes (process-mark proc))
                                            (position-bytes (point)))))
                    (cond
                     ((>= available-bytes
                          expected-bytes)
                      (let* ((message-end (byte-to-position
                                           (+ (position-bytes (point))
                                              expected-bytes))))
                        (unwind-protect
                            (save-restriction
                              (narrow-to-region (point) message-end)
                              (let* ((json-message
                                      (condition-case-unless-debug oops
                                          (jsonrpc--json-read)
                                        (error
                                         (jsonrpc-warn "Invalid JSON: %s %s"
                                                       (cdr oops) (buffer-string))
                                         nil))))
                                (when json-message
                                  ;; Process content in another
                                  ;; buffer, shielding proc buffer from
                                  ;; tamper
                                  (with-temp-buffer
                                    (jsonrpc--connection-receive connection
                                                                 json-message)))))
                          (goto-char message-end)
                          (delete-region (point-min) (point))
                          (setq expected-bytes nil))))
                     (t
                      ;; Message is still incomplete
                      ;;
                      (setq done :waiting-for-more-bytes-in-this-message))))))))
          ;; Saved parsing state for next visit to this filter
          ;;
          (setf (jsonrpc--expected-bytes connection) expected-bytes))))))

(defun jsonrpc-events-buffer (connection &optional interactive)
  "Display events buffer for current JSONRPC connection CONNECTION.
INTERACTIVE is t if called interactively."
  (interactive (list (jsonrpc-current-connection-or-lose) t))
  (let* ((probe (jsonrpc--events-buffer connection))
         (buffer (or (and (buffer-live-p probe)
                          probe)
                     (let ((buffer (get-buffer-create
                                    (format "*%s events*"
                                            (jsonrpc-name connection)))))
                       (with-current-buffer buffer
                         (buffer-disable-undo)
                         (read-only-mode t)
                         (setf (jsonrpc--events-buffer connection) buffer))
                       buffer))))
    (when interactive (display-buffer buffer))
    buffer))

(defun jsonrpc-stderr-buffer (connection)
  "Pop to stderr of CONNECTION, if it exists, else error."
  (interactive (list (jsonrpc-current-connection-or-lose)))
  (if-let ((b (process-get (jsonrpc--process connection) 'jsonrpc-stderr)))
      (pop-to-buffer b) (user-error "[eglot] No stderr buffer!")))

(defun jsonrpc-log-event (connection message &optional type)
  "Log an jsonrpc-related event.
CONNECTION is the current connection.  MESSAGE is a JSON-like
plist.  TYPE is a symbol saying if this is a client or server
originated."
  (with-current-buffer (jsonrpc-events-buffer connection)
    (cl-destructuring-bind (&key method id error &allow-other-keys) message
      (let* ((inhibit-read-only t)
             (subtype (cond ((and method id)       'request)
                            (method                'notification)
                            (id                    'reply)
                            (t                     'message)))
             (type
              (concat (format "%s" (or type 'internal))
                      (if type
                          (format "-%s" subtype)))))
        (goto-char (point-max))
        (let ((msg (format "%s%s%s %s:\n%s\n"
                           type
                           (if id (format " (id:%s)" id) "")
                           (if error " ERROR" "")
                           (current-time-string)
                           (pp-to-string message))))
          (when error
            (setq msg (propertize msg 'face 'error)))
          (insert-before-markers msg))))))

(defvar jsonrpc--unanswered-request-id)

(defun jsonrpc--connection-receive (connection message)
  "Connection MESSAGE from CONNECTION."
  (cl-destructuring-bind
      (&key method id error params result _jsonrpc)
      message
    (pcase-let* ((continuations)
                 (lisp-err)
                 (jsonrpc--unanswered-request-id id))
      (jsonrpc-log-event connection message 'server)
      (when error (setf (jsonrpc-status connection) `(,error t)))
      (cond (method
             (let ((debug-on-error
                    (and debug-on-error
                         (not (ert-running-test)))))
               (condition-case-unless-debug oops
                   (funcall (if id
                                (jsonrpc--request-dispatcher connection)
                              (jsonrpc--notification-dispatcher connection))
                            connection (intern method) params)
                 (error
                  (setq lisp-err oops))))
             (unless (or (not jsonrpc--unanswered-request-id)
                         (not lisp-err))
               (jsonrpc-reply
                connection
                :error (jsonrpc-obj
                        :code (or (alist-get 'jsonrpc-error-code (cdr lisp-err))
                                  -32603)
                        :message (or (alist-get 'jsonrpc-error-message
                                                (cdr lisp-err))
                                     "Internal error")))))
            ((setq continuations
                   (and id (gethash id (jsonrpc--request-continuations connection))))
             (let ((timer (nth 2 continuations)))
               (when timer (cancel-timer timer)))
             (remhash id (jsonrpc--request-continuations connection))
             (if error (funcall (nth 1 continuations) error)
               (funcall (nth 0 continuations) result)))
            (id
             (jsonrpc-warn "No continuation for id %s" id)))
      (jsonrpc--call-deferred connection))))

(cl-defmethod jsonrpc-connection-send ((connection jsonrpc-process-connection)
                                       &rest args
                                       &key
                                       id
                                       method
                                       params
                                       result
                                       error)
  "Send MESSAGE, a JSON object, to CONNECTION."
  (let* ((method
          (cond ((keywordp method)
                 (substring (symbol-name method) 1))
                ((and method (symbolp method)) (symbol-name method))
                (t method)))
         (message `(:jsonrpc "2.0"
                             ,@(when method `(:method ,method))
                             ,@(when id     `(:id     ,id))
                             ,@(when params `(:params ,params))
                             ,@(when result `(:result ,result))
                             ,@(when error  `(:error  ,error))))
         (json (jsonrpc--json-encode message)))
    (process-send-string (jsonrpc--process connection)
                         (format "Content-Length: %d\r\n\r\n%s"
                                 (string-bytes json)
                                 json))
    (jsonrpc-log-event connection message 'client)))

(defun jsonrpc-forget-pending-continuations (connection)
  "Stop waiting for responses from the current JSONRPC CONNECTION."
  (interactive (list (jsonrpc-current-connection-or-lose)))
  (clrhash (jsonrpc--request-continuations connection)))

(defun jsonrpc-clear-status (connection)
  "Clear most recent error message from CONNECTION."
  (interactive (list (jsonrpc-current-connection-or-lose)))
  (setf (jsonrpc-status connection) nil))

(defun jsonrpc--call-deferred (connection)
  "Call CONNECTION's deferred actions, who may again defer themselves."
  (when-let ((actions (hash-table-values (jsonrpc--deferred-actions connection))))
    (jsonrpc--debug connection `(:maybe-run-deferred ,(mapcar #'caddr actions)))
    (mapc #'funcall (mapcar #'car actions))))

(cl-defgeneric jsonrpc-connection-ready-p (connection what) ;; API
  "Tell if CONNECTION is ready for WHAT in current buffer.
If it isn't, a deferrable `jsonrpc-async-request' will be
deferred to the future.  By default, all connections are ready
for sending requests immediately."
  (:method (_s _what) t)) ; by default all connections are ready

(cl-defmacro jsonrpc-lambda (cl-lambda-list &body body)
  (declare (indent 1) (debug (sexp &rest form)))
  (let ((e (gensym "jsonrpc-lambda-elem")))
    `(lambda (,e) (apply (cl-function (lambda ,cl-lambda-list ,@body)) ,e))))

(defconst jrpc-default-request-timeout 10
  "Time in seconds before timing out a JSONRPC request.")

(cl-defun jsonrpc-async-request (connection
                                 method
                                 params
                                 &rest args
                                 &key _success-fn _error-fn
                                 _timeout-fn
                                 _timeout _deferred)
  "Make a request to CONNECTION, expecting a reply, return immediately.
The JSONRPC request is formed by METHOD, a symbol, and PARAMS a
JSON object.

The caller can expect SUCCESS-FN or ERROR-FN to be called with a
JSONRPC `:result' or `:error' object, respectively.  If this
doesn't happen after TIMEOUT seconds (defaults to
`jsonrpc-request-timeout'), the caller can expect TIMEOUT-FN to be
called with no arguments. The default values of SUCCESS-FN,
ERROR-FN and TIMEOUT-FN simply log the events into
`jsonrpc-events-buffer'.

If DEFERRED is non-nil, maybe defer the request to a future time
when the server is thought to be ready according to
`jsonrpc-connection-ready-p' (which see).  The request might
never be sent at all, in case it is overridden in the meantime by
a new request with identical DEFERRED and for the same buffer.
However, in that situation, the original timeout is kept.

Returns nil."
  (apply #'jsonrpc--async-request-1 connection method params args)
  nil)

(cl-defun jsonrpc--async-request-1 (connection
                                    method
                                    params
                                    &rest args
                                    &key success-fn error-fn timeout-fn
                                    (timeout jrpc-default-request-timeout)
                                    (deferred nil))
  "Does actual work for `jsonrpc-async-request'.

Return a list (ID TIMER). ID is the new request's ID, or nil if
the request was deferred. TIMER is a timer object set (or nil, if
TIMEOUT is nil)."
  (pcase-let* ((buf (current-buffer)) (point (point))
               (`(,_ ,timer ,old-id)
                (and deferred (gethash (list deferred buf)
                                       (jsonrpc--deferred-actions connection))))
               (id (or old-id (cl-incf (jsonrpc--next-request-id connection))))
               (make-timer
                (lambda ( )
                  (when timeout
                    (run-with-timer
                     timeout nil
                     (lambda ()
                       (remhash id (jsonrpc--request-continuations connection))
                       (remhash (list deferred buf)
                                (jsonrpc--deferred-actions connection))
                       (if timeout-fn (funcall timeout-fn)
                         (jsonrpc--debug
                          connection `(:timed-out ,method :id ,id
                                                  :params ,params)))))))))
    (when deferred
      (if (jsonrpc-connection-ready-p connection deferred)
          ;; Server is ready, we jump below and send it immediately.
          (remhash (list deferred buf) (jsonrpc--deferred-actions connection))
        ;; Otherwise, save in `eglot--deferred-actions' and exit non-locally
        (unless old-id
          (jsonrpc--debug connection `(:deferring ,method :id ,id :params
                                                  ,params)))
        (puthash (list deferred buf)
                 (list (lambda ()
                         (when (buffer-live-p buf)
                           (with-current-buffer buf
                             (save-excursion (goto-char point)
                                             (apply #'jsonrpc-async-request
                                                    connection
                                                    method params args)))))
                       (or timer (setq timer (funcall make-timer))) id)
                 (jsonrpc--deferred-actions connection))
        (cl-return-from jsonrpc--async-request-1 (list id timer))))
    ;; Really send it
    ;;
    (jsonrpc-connection-send connection
                             :id id
                             :method method
                             :params params)
    (puthash id
             (list (or success-fn
                       (jsonrpc-lambda (&rest _ignored)
                         (jsonrpc--debug
                          connection (jsonrpc-obj :message "success ignored" :id id))))
                   (or error-fn
                       (jsonrpc-lambda (&key code message &allow-other-keys)
                         (setf (jsonrpc-status connection) `(,message t))
                         (jsonrpc--debug
                          connection (jsonrpc-obj :message "error ignored, status set"
                                                  :id id :error code))))
                   (setq timer (funcall make-timer)))
             (jsonrpc--request-continuations connection))
    (list id timer)))

(cl-defun jsonrpc-request (connection method params &key deferred timeout)
  "Make a request to CONNECTION, wait for a reply.
Like `jsonrpc-async-request' for CONNECTION, METHOD and PARAMS, but
synchronous, i.e. doesn't exit until anything
interesting (success, error or timeout) happens.  Furthermore,
only exit locally (and return the JSONRPC result object) if the
request is successful, otherwise exit non-locally with an error.

DEFERRED is passed to `jsonrpc-async-request', which see."
  (let* ((tag (cl-gensym "jsonrpc-request-catch-tag")) id-and-timer
         (retval
          (unwind-protect ; protect against user-quit, for example
              (catch tag
                (setq
                 id-and-timer
                 (jsonrpc--async-request-1
                  connection method params
                  :success-fn (lambda (result) (throw tag `(done ,result)))
                  :error-fn
                  (jsonrpc-lambda
                      (&key code message data)
                    (throw tag `(error (jsonrpc-error-code . ,code)
                                       (jsonrpc-error-message . ,message)
                                       (jsonrpc-error-data . ,data))))
                  :timeout-fn
                  (lambda ()
                    (throw tag '(error (jsonrpc-error-message . "Timed out"))))
                  :deferred deferred
                  :timeout timeout))
                (while t (accept-process-output nil 30)))
            (pcase-let* ((`(,id ,timer) id-and-timer))
              (remhash id (jsonrpc--request-continuations connection))
              (remhash (list deferred (current-buffer))
                       (jsonrpc--deferred-actions connection))
              (when timer (cancel-timer timer))))))
    (when (eq 'error (car retval))
      (signal 'jsonrpc-error
              (cons
               (format "request id=%s failed:" (car id-and-timer))
               (cdr retval))))
    (cadr retval)))

(cl-defun jsonrpc-notify (connection method params)
  "Notify CONNECTION of something, don't expect a reply.e"
  (jsonrpc-connection-send connection
                           :method method
                           :params params))

(cl-defun jsonrpc-reply (connection &key (result nil result-supplied-p) error)
  "Reply to CONNECTION's request ID with RESULT or ERROR."
  (unless (xor result-supplied-p error)
    (jsonrpc-error "Can't pass both RESULT and ERROR!"))
  (jsonrpc-connection-send
   connection
   :id jsonrpc--unanswered-request-id
   :result result
   :error error)
  (setq jsonrpc--unanswered-request-id nil))

(provide 'jsonrpc)
;;; jsonrpc.el ends here
