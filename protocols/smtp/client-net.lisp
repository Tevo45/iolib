;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp -*-

;;   Copyright (C) 2007 Stelian Ionescu
;;
;;   This code is free software; you can redistribute it and/or
;;   modify it under the terms of the version 2.1 of
;;   the GNU Lesser General Public License as published by
;;   the Free Software Foundation, as clarified by the
;;   preamble found here:
;;       http://opensource.franz.com/preamble.html
;;
;;   This program is distributed in the hope that it will be useful,
;;   but WITHOUT ANY WARRANTY; without even the implied warranty of
;;   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;   GNU General Public License for more details.
;;
;;   You should have received a copy of the GNU Lesser General
;;   Public License along with this library; if not, write to the
;;   Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
;;   Boston, MA 02110-1301, USA

(in-package :net.smtp-client)

(defun make-smtp-socket (host port)
  (make-socket :address-family :internet :type :stream :connect :active
               :remote-host host :remote-port port
               :external-format '(:iso-8859-1 :line-terminator :dos)))

(defun write-to-smtp (socket command)
  (write-line command socket)
  (finish-output socket))

(defun format-socket (socket cmdstr &rest args)
  (write-to-smtp socket (apply #'format nil cmdstr args)))

(defun read-from-smtp (sock)
  (let* ((line (read-line sock))
         (response-code (parse-integer line :start 0 :junk-allowed t)))
    (if (= (char-code (elt line 3)) (char-code #\-))
        (read-from-smtp sock)
        (values response-code line))))
