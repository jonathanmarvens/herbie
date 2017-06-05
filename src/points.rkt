#lang racket

(require math/flonum)
(require math/bigfloat)
(require "float.rkt" "common.rkt" "programs.rkt" "config.rkt" "errors.rkt" "range-analysis.rkt")

(provide *pcontext* in-pcontext mk-pcontext pcontext?
         prepare-points prepare-points-period make-exacts
         errors errors-score sorted-context-list sort-context-on-expr
         random-subsample)

(module+ test
  (require rackunit))

(define (sample-bounded lo hi #:left-closed? [left-closed? #t] #:right-closed? [right-closed? #t])
  (define lo* (exact->inexact lo))
  (define hi* (exact->inexact hi))
  (cond
   [(> lo* hi*) #f]
   [(= lo* hi*)
    (if (and left-closed? right-closed?) lo* #f)]
   [(< lo* hi*)
    (define ordinal (- (flonum->ordinal hi*) (flonum->ordinal lo*)))
    (define num-bits (ceiling (/ (log ordinal) (log 2))))
    (define random-num (random-exp (inexact->exact num-bits)))
    (if (or (and (not left-closed?) (equal? 0 random-num))
            (and (not right-closed?) (equal? ordinal random-num))
            (> random-num ordinal))
      ;; Happens with p < .5 so will not loop forever
      (sample-bounded lo hi #:left-closed? left-closed? #:right-closed? right-closed?)
      (ordinal->flonum (+ (flonum->ordinal lo*) random-num)))]))

(module+ test
  (check-true (<= 1.0 (sample-bounded 1 2) 2.0))
  (let ([a (sample-bounded 1 2 #:left-closed? #f)])
    (check-true (< 1 a))
    (check-true (<= a 2)))
  (check-false (sample-bounded 1 1.0 #:left-closed? #f) "Empty interval due to left openness")
  (check-false (sample-bounded 1 1.0 #:right-closed? #f) "Empty interval due to right openness")
  (check-false (sample-bounded 1 1.0 #:left-closed? #f #:right-closed? #f)
               "Empty interval due to both-openness")
  (check-false (sample-bounded 2.0 1.0) "Interval bounds flipped"))

(define *pcontext* (make-parameter #f))

(struct pcontext (points exacts))

(define (in-pcontext context)
  (in-parallel (in-vector (pcontext-points context)) (in-vector (pcontext-exacts context))))

(define (mk-pcontext points exacts)
  (pcontext (if (list? points)
		(begin (assert (not (null? points)))
		       (list->vector points))
		(begin (assert (not (= 0 (vector-length points))))
		       points))
	    (if (list? exacts)
		(begin (assert (not (null? exacts)))
		       (list->vector exacts))
		(begin (assert (not (= 0 (vector-length exacts))))
		       exacts))))

(define (random-subsample pcontext n)
  (let*-values ([(old-points) (pcontext-points pcontext)]
                [(old-exacts) (pcontext-exacts pcontext)]
                [(points exacts)
                 (for/lists (points exacts)
		     ([i (in-range n)])
		   (let ([idx (random (vector-length old-points))])
		     (values (vector-ref old-points idx)
			     (vector-ref old-exacts idx))))])
    (mk-pcontext points exacts)))

(define (sorted-context-list context vidx)
  (let ([p&e (sort (for/list ([(pt ex) (in-pcontext context)]) (cons pt ex))
		   < #:key (compose (curryr list-ref vidx) car))])
    (list (map car p&e) (map cdr p&e))))

(define (sort-context-on-expr context expr variables)
  (let ([p&e (sort (for/list ([(pt ex) (in-pcontext context)]) (cons pt ex))
		   < #:key (λ (p&e)
			     (let* ([expr-prog `(λ ,variables ,expr)]
				    [float-val ((eval-prog expr-prog mode:fl) (car p&e))])
			       (if (ordinary-float? float-val) float-val
				   ((eval-prog expr-prog mode:bf) (car p&e))))))])
    (list (map car p&e) (map cdr p&e))))

(define (make-period-points num periods)
  (let ([points-per-dim (floor (exp (/ (log num) (length periods))))])
    (apply cartesian-product
	   (map (λ (prd)
		  (let ([bucket-width (/ prd points-per-dim)])
		    (for/list ([i (range points-per-dim)])
		      (+ (* i bucket-width) (* bucket-width (random))))))
		periods))))

(define (select-every skip l)
  (let loop ([l l] [count skip])
    (cond
     [(null? l) '()]
     [(= count 0)
      (cons (car l) (loop (cdr l) skip))]
     [else
      (loop (cdr l) (- count 1))])))

(define (make-exacts* prog pts precondition)
  (let ([f (eval-prog prog mode:bf)] [n (length pts)]
        [pre (eval-prog `(λ ,(program-variables prog) ,precondition) mode:bf)])
    (let loop ([prec (- (bf-precision) (*precision-step*))]
               [prev #f])
      (bf-precision prec)
      (let ([curr (map f pts)] [good? (map pre pts)])
        (if (and prev (andmap (λ (good? old new) (or (not good?) (=-or-nan? old new))) good? prev curr))
            (map (λ (good? x) (if good? x +nan.0)) good? curr)
            (loop (+ prec (*precision-step*)) curr))))))

(define (make-exacts prog pts precondition)
  (define n (length pts))
  (let loop ([n* 16]) ; 16 is arbitrary; *num-points* should be n* times a power of 2
    (cond
     [(>= n* n)
      (make-exacts* prog pts precondition)]
     [else
      (make-exacts* prog (select-every (round (/ n n*)) pts) precondition)
      (loop (* n* 2))])))

(define (filter-points pts exacts)
  "Take only the points for which the exact value is normal, and the point is normal"
  (reap (sow)
    (for ([pt pts] [exact exacts])
      (when (and (ordinary-float? exact) (andmap ordinary-float? pt))
        (sow pt)))))

(define (filter-exacts pts exacts)
  "Take only the exacts for which the exact value is normal, and the point is normal"
  (reap (sow)
    (for ([pt pts] [exact exacts])
      (when (and (ordinary-float? exact) (andmap ordinary-float? pt))
	(sow exact)))))

; These definitions in place, we finally generate the points.

(define (prepare-points prog precondition)
  "Given a program, return two lists:
   a list of input points (each a list of flonums)
   and a list of exact values for those points (each a flonum)"

  (define range-table (condition->range-table precondition))

  (define samplers
    (for/list ([var (program-variables prog)])
      (match (range-table-ref range-table var)
        [#f
         (raise-herbie-error "No valid values of variable ~a" var #:url "faq.html#no-valid-values")]
        [(interval lo hi lo? hi?)
         (let* ([analyze (λ (expr) (eval-prog `(λ ,(program-variables prog) ,expr) mode:bf))]
                [lo* (analyze lo)]
                [hi* (analyze hi)])
           (λ (pt) (sample-bounded (lo* pt) (hi* pt) #:left-closed? lo? #:right-closed? hi?)))])))

  ;; Generate a single point, maintaining an environment of variables
  ;; that already have values. Thus, later samplers can have ranges
  ;; that depend on earlier values.
  (define (gen-point)
    (let-values
        ([(env _)
          (for/fold ([env '()] [dummies (map (λ (_) +nan.0) (program-variables prog))])
                    ([var (program-variables prog)]
                     [sampler samplers])
            (let ([val (sampler (append env dummies))])
              (values (append env (list val)) (cdr dummies))))])
      env))


  ; First, we generate points;
  (let loop ([pts '()] [exs '()] [num-loops 0])
    (cond [(> num-loops 200)
           (raise-herbie-error "Cannot sample enough valid points." #:url "faq.html#sample-valid-points")]
          [(>= (length pts) (*num-points*))
           (mk-pcontext (take pts (*num-points*)) (take exs (*num-points*)))]
          [#t
           (let* ([num (- (*num-points*) (length pts))]
                  [pts1 (filter (λ (l) (andmap (λ (x) (not (eq? x #f))) l))
                                (for/list ([n (in-range num)])
                                  (gen-point)))]
                  [exs1 (make-exacts prog pts1 precondition)]
                                        ;; Then, we remove the points for which the answers
                                        ;; are not representable
                 [pts* (filter-points pts1 exs1)]
                 [exs* (filter-exacts pts1 exs1)])
            (loop (append pts* pts) (append exs* exs) (+ 1 num-loops)))])))

(define (prepare-points-period prog periods)
  (let* ([pts (make-period-points (*num-points*) periods)]
         [exacts (make-exacts prog pts #t)]
	 [pts* (filter-points pts exacts)]
	 [exacts* (filter-exacts pts exacts)])
    (mk-pcontext pts* exacts*)))

(define (errors prog pcontext)
  (let ([fn (eval-prog prog mode:fl)]
	[max-ulps (expt 2 (*bit-width*))])
    (for/list ([(point exact) (in-pcontext pcontext)])
      (let ([out (fn point)])
	(add1
	 (if (real? out)
	     (abs (ulp-difference out exact))
	     max-ulps))))))

(define (errors-score e)
  (let-values ([(reals unreals) (partition ordinary-float? e)])
    (if ((flag 'reduce 'avg-error) #f #t)
        (apply max (map ulps->bits reals))
        (/ (+ (apply + (map ulps->bits reals))
              (* (*bit-width*) (length unreals)))
           (length e)))))
