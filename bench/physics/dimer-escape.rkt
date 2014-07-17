#lang racket
(require casio/test)

;  Escape dynamics of a Bose-Hubbard dimer out of a trap 
; D. Maksimov and A. Kolovsky
; Phys. Rev. A 89, 063612 (2014), https://links.aps.org/doi/10.1103/PhysRevA.89.063612,

(casio-bench (J K U)
  "Maksimov and Kolovsky, Equation (3)"
  (* -2 J (cos (/ K 2)) (sqrt (+ 1 (sqr (/ U (* 2 J (cos (/ K 2)))))))))

(casio-bench (J l K U)
  "Maksimov and Kolovsky, Equation (4)"
  (+ (* J (- (exp l) (exp (- l))) (cos (/ K 2))) U))

(casio-bench (K m n M l)
  "Maksimov and Kolovsky, Equation (32)"
  (* (cos (- (/ (* K (+ m n)) 2) M))
     (exp (- (- (sqr (- (/ (+ m n) 2) M))) (- l (abs (- m n)))))))