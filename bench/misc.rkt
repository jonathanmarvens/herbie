#lang racket
(require casio/test)

(casio-test (x eps)
  "NMSE Section 6.1 mentioned"
  (/ (- (* (+ 1 (/ 1 eps)) (exp (- (* (- 1 eps) x))))
        (* (- (/ 1 eps) 1) (exp (- (* (+ 1 eps) x)))))
     2))

;; NMSE Section 6.1
(casio-test (a b)
  "NMSE Section 6.1 mentioned"
  (* (/ pi 2) (/ 1 (- (sqr b) (sqr a))) (- (/ 1 a) (/ 1 b))))
