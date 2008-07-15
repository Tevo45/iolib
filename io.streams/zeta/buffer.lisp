;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; indent-tabs-mode: nil -*-
;;;
;;; --- Device buffers.
;;;

(in-package :io.zeta-streams)

;;;-----------------------------------------------------------------------------
;;; Classes
;;;-----------------------------------------------------------------------------

(defclass buffer (device)
  ((single-channel :initarg :single-channel :accessor single-channel-buffer-p)
   (input-buffer :initarg :input-buffer :accessor input-buffer-of)
   (output-buffer :initarg :output-buffer :accessor output-buffer-of)))


;;;-----------------------------------------------------------------------------
;;; Constructors
;;;-----------------------------------------------------------------------------

(defmethod initialize-instance :after ((buffer buffer) &key single-channel
                                       input-buffer-size output-buffer-size)
  (if (input-buffer-of buffer)
      (check-type (input-buffer-of buffer) iobuf)
      (setf (input-buffer-of buffer) (make-iobuf input-buffer-size)))
  (unless single-channel
    (if (output-buffer-of buffer)
        (check-type (output-buffer-of buffer) iobuf)
        (setf (output-buffer-of buffer) (make-iobuf output-buffer-size)))))


;;;-----------------------------------------------------------------------------
;;; Generic functions
;;;-----------------------------------------------------------------------------

(defgeneric buffer-clear-input (buffer))

(defgeneric buffer-clear-output (buffer))

(defgeneric buffer-flush-output (buffer &optional timeout))


;;;-----------------------------------------------------------------------------
;;; Buffered DEVICE-READ
;;;-----------------------------------------------------------------------------

(defmethod device-read ((device buffer) buffer start end &optional timeout)
  (when (= start end) (return-from device-read 0))
  (read-octets/buffered (input-handle-of device) buffer start end timeout))

(defun read-octets/buffered (buffer array start end timeout)
  (declare (type buffer buffer)
           (type iobuf-data-array array)
           (type iobuf-index start end)
           (type device-timeout timeout))
  (with-accessors ((input-handle input-handle-of)
                   (input-buffer input-buffer-of))
      buffer
    (cond
      ((iobuf-empty-p input-buffer)
       (let ((nbytes (fill-input-buffer input-handle input-buffer timeout)))
         (if (iobuf-empty-p input-buffer)
             (if (eql :eof nbytes) :eof 0)
             (iobuf->array input-buffer array start end))))
      (t
       (iobuf->array input-buffer array start end)))))

(defun fill-input-buffer (input-handle input-buffer timeout)
  (multiple-value-bind (data start end)
      (iobuf-next-empty-zone input-buffer)
    (device-read input-handle data start end timeout)))


;;;-----------------------------------------------------------------------------
;;; Buffered DEVICE-WRITE
;;;-----------------------------------------------------------------------------

(defmethod device-write ((device buffer) buffer start end &optional timeout)
  (when (= start end) (return-from device-write 0))
  (write-octets/buffered (output-handle-of device) buffer start end timeout))

(defun write-octets/buffered (buffer array start end timeout)
  (declare (type buffer buffer)
           (type iobuf-data-array array)
           (type iobuf-index start end)
           (type device-timeout timeout))
  (with-accessors ((output-handle output-handle-of)
                   (output-buffer output-buffer-of))
      buffer
    (array->iobuf output-buffer array start end)
    (when (iobuf-full-p output-buffer)
      (flush-output-buffer output-handle output-buffer timeout))))

(defun flush-output-buffer (output-handle output-buffer timeout)
  (multiple-value-bind (data start end)
      (iobuf-next-data-zone output-buffer)
    (device-write output-handle data start end timeout)))


;;;-----------------------------------------------------------------------------
;;; Buffer cleaning
;;;-----------------------------------------------------------------------------

(defmethod buffer-clear-input ((buffer buffer))
  (iobuf-reset (input-buffer-of buffer)))

(defmethod buffer-clear-output ((buffer buffer))
  (iobuf-reset (output-buffer-of buffer)))

(defmethod buffer-flush-output ((buffer buffer) &optional timeout)
  (with-accessors ((output-handle output-handle-of)
                   (output-buffer output-buffer-of))
      buffer
    (flush-output-buffer output-handle output-buffer timeout)
    (iobuf-available-octets output-buffer)))