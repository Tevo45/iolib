;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; indent-tabs-mode: nil -*-
;;;
;;; --- Device buffers.
;;;

(in-package :io.zeta-streams)

;;;-----------------------------------------------------------------------------
;;; Buffer Classes and Types
;;;-----------------------------------------------------------------------------

(defclass buffer (device)
  ((single-channel-p :initarg :single-channel :accessor single-channel-buffer-p)
   (last-io-op :initform nil :accessor last-io-op-of)
   (input-buffer :initarg :input-buffer :accessor input-buffer-of)
   (output-buffer :initarg :output-buffer :accessor output-buffer-of)
   (synchronized :initarg :synchronized :reader buffer-synchronized-p))
  (:default-initargs :input-buffer nil
                     :output-buffer nil
                     :synchronized nil))


;;;-----------------------------------------------------------------------------
;;; Buffer Constructors
;;;-----------------------------------------------------------------------------

(defmethod initialize-instance :after ((buffer buffer) &key
                                       (single-channel nil single-channel-provided)
                                       input-buffer-size output-buffer-size)
  (with-accessors ((single-channel-p single-channel-buffer-p)
                   (input-handle input-handle-of)
                   (input-buffer input-buffer-of)
                   (output-buffer output-buffer-of))
      buffer
    (unless single-channel-provided
      (setf single-channel-p (typep input-handle 'single-channel-device)))
    (if input-buffer
        (check-type input-buffer iobuf)
        (setf input-buffer (make-iobuf input-buffer-size)))
    (if single-channel
        (setf output-buffer input-buffer)
        (cond
          (output-buffer
           (check-type output-buffer iobuf)
           (assert (not (eq input-buffer output-buffer))))
          (t (setf output-buffer (make-iobuf output-buffer-size)))))))


;;;-----------------------------------------------------------------------------
;;; Buffer Generic Functions
;;;-----------------------------------------------------------------------------

(defgeneric buffer-clear-input (buffer))

(defgeneric buffer-clear-output (buffer))

(defgeneric buffer-flush-output (buffer &optional timeout))


;;;-----------------------------------------------------------------------------
;;; Buffer DEVICE-CLOSE
;;;-----------------------------------------------------------------------------

(defmethod device-close ((buffer buffer) &optional abort)
  (with-accessors ((input-buffer input-buffer-of)
                   (output-buffer output-buffer-of))
      buffer
    (cond
      ((single-channel-buffer-p buffer)
       (if (buffer-synchronized-p buffer)
           (bt:with-lock-held (output-buffer)
             (close-single-channel-buffer buffer abort))
           (close-single-channel-buffer buffer abort)))
      (t
       (if (buffer-synchronized-p buffer)
           (bt:with-lock-held (input-buffer)
             (bt:with-lock-held (output-buffer)
               (close-dual-channel-buffer buffer abort)))
           (close-dual-channel-buffer buffer abort)))))
  (values buffer))

(defun close-single-channel-buffer (buffer abort)
  (unless abort
    (flush-output-buffer (output-handle-of buffer)
                         (output-buffer-of buffer)
                         0))
  (device-close (output-handle-of buffer)))

(defun close-dual-channel-buffer (buffer abort)
  (unless abort
    (flush-output-buffer (output-handle-of buffer)
                         (output-buffer-of buffer)
                         0))
  (device-close (input-handle-of buffer))
  (device-close (output-handle-of buffer)))

;;;-----------------------------------------------------------------------------
;;; Buffer DEVICE-READ
;;;-----------------------------------------------------------------------------

(defmethod device-read ((device buffer) buffer start end &optional timeout)
  (when (= start end) (return-from device-read 0))
  (cond
    ((buffer-synchronized-p device)
     (flet ((%read-octets ()
              (bt:with-lock-held ((iobuf-lock (input-buffer-of device)))
                (read-octets/buffered device buffer start end 0))))
       (let ((nbytes (%read-octets)))
         (cond
           ((and (not (eql timeout 0))
                 (eql nbytes 0))
            (wait-for-input (input-handle-of device) timeout)
            (%read-octets))
           (t nbytes)))))
    (t
     (read-octets/buffered device buffer start end timeout))))

(defun read-octets/buffered (device vector start end timeout)
  (declare (type buffer device)
           (type ub8-simple-vector vector)
           (type iobuf-index start end)
           (type device-timeout timeout))
  (with-accessors ((input-handle input-handle-of)
                   (input-buffer input-buffer-of)
                   (output-handle output-handle-of)
                   (output-buffer output-buffer-of))
      device
    ;; If the previous operation was a write, try to flush the output buffer.
    ;; If the buffer couldn't be flushed entirely, signal an error
    (synchronize-input device output-handle output-buffer)
    (cond
      ((iobuf-empty-p input-buffer)
       (let ((nbytes
              (fill-input-buffer device input-handle input-buffer timeout)))
         (if (iobuf-empty-p input-buffer)
             (if (eql :eof nbytes) :eof 0)
             (iobuf->vector input-buffer vector start end))))
      (t
       (iobuf->vector input-buffer vector start end)))))

(defun synchronize-input (device output-handle output-buffer)
  (when (and (single-channel-buffer-p device)
             (eql :write (last-io-op-of device)))
    (if (plusp (flush-output-buffer output-handle output-buffer 0))
        (error "Could not flush the entire write buffer !")
        (iobuf-reset output-buffer))))

(defun fill-input-buffer (device input-handle input-buffer timeout)
  (multiple-value-bind (data start end)
      (iobuf-next-empty-zone input-buffer)
    (let ((nbytes
           (device-read input-handle data start end timeout)))
      (setf (iobuf-end input-buffer) (+ start nbytes))
      (setf (last-io-op-of device) :read)
      (values nbytes))))

(defun flush-input-buffer (input-buffer)
  (prog1
      (iobuf-available-octets input-buffer)
    (iobuf-reset input-buffer)))


;;;-----------------------------------------------------------------------------
;;; Buffer DEVICE-WRITE
;;;-----------------------------------------------------------------------------

(defmethod device-write ((device buffer) buffer start end &optional timeout)
  (when (= start end) (return-from device-write 0))
  (cond
    ((buffer-synchronized-p device)
     (flet ((%write-octets ()
              (bt:with-lock-held ((iobuf-lock (output-buffer-of device)))
                (write-octets/buffered device buffer start end 0))))
       (let ((nbytes (%write-octets)))
         (cond
           ((and (not (eql timeout 0))
                 (eql nbytes 0))
            (wait-for-output (output-handle-of device) timeout)
            (%write-octets))
           (t nbytes)))))
    (t
     (write-octets/buffered device buffer start end timeout))))

(defun write-octets/buffered (device vector start end timeout)
  (declare (type buffer device)
           (type ub8-simple-vector vector)
           (type iobuf-index start end)
           (type device-timeout timeout))
  (with-accessors ((output-handle output-handle-of)
                   (output-buffer output-buffer-of))
      device
    ;; If the previous operation was a read, flush the read buffer
    ;; and reposition the file offset accordingly
    (synchronize-output device)
    (prog1
        (vector->iobuf output-buffer vector start end)
      (setf (last-io-op-of device) :write)
      (when (iobuf-full-p output-buffer)
        (flush-output-buffer output-handle output-buffer timeout)))))

(defun synchronize-output (device)
  (when (and (single-channel-buffer-p device)
             (eql :read (last-io-op-of device)))
    (let ((nbytes (flush-input-buffer (input-buffer-of device))))
      (unless (zerop nbytes)
        (setf (device-position device :from :current) (- nbytes))))))

(defun flush-output-buffer (output-handle output-buffer timeout)
  (multiple-value-bind (data start end)
      (iobuf-next-data-zone output-buffer)
    (let ((nbytes
           (device-write output-handle data start end timeout)))
      (setf (iobuf-start output-buffer) (+ start nbytes))))
  (iobuf-available-octets output-buffer))


;;;-----------------------------------------------------------------------------
;;; Buffer DEVICE-POSITION
;;;-----------------------------------------------------------------------------

(defmethod device-position ((device buffer))
  (if (buffer-synchronized-p device)
      (bt:with-lock-held ((input-buffer-of device))
        (get-device-position device))
      (get-device-position device)))

(defun get-device-position (buffer)
  (when-let ((single-channel-p (single-channel-buffer-p buffer))
             (handle-position
              (device-position (input-handle-of buffer))))
    (ecase (last-io-op-of buffer)
      (:read
       (- handle-position (iobuf-available-octets (input-buffer-of buffer))))
      (:write
       (+ handle-position (iobuf-available-octets (input-buffer-of buffer)))))))

(defmethod (setf device-position) (position (device buffer) &key (from :start))
  (setf (device-position device :from from) position))


;;;-----------------------------------------------------------------------------
;;; Buffer cleaning
;;;-----------------------------------------------------------------------------

(defmethod buffer-clear-input ((buffer buffer))
  (with-accessors ((input-buffer input-buffer-of))
      buffer
    (if (buffer-synchronized-p buffer)
        (bt:with-lock-held (input-buffer)
          (iobuf-reset input-buffer))
        (iobuf-reset input-buffer))))

(defmethod buffer-clear-output ((buffer buffer))
  (with-accessors ((output-buffer output-buffer-of))
      buffer
    (if (buffer-synchronized-p buffer)
        (bt:with-lock-held (output-buffer)
          (iobuf-reset output-buffer))
        (iobuf-reset output-buffer))))

(defmethod buffer-flush-output ((buffer buffer) &optional timeout)
  (with-accessors ((output-handle output-handle-of)
                   (output-buffer output-buffer-of))
      buffer
    (if (buffer-synchronized-p buffer)
        (bt:with-lock-held (output-buffer)
          (flush-output-buffer output-handle output-buffer timeout))
        (flush-output-buffer output-handle output-buffer timeout))))
