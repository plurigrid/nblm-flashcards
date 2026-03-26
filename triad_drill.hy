#!/usr/bin/env hy
;; triad_drill.hy — Open-ended triadic quiz from DuckDB interaction data
;;
;; Picks random triads of people from DuckDB, asks open-ended questions
;; about their interaction patterns, then reveals ground truth from data.
;; The user types their answer; similarity is self-scored.
;;
;; Usage:
;;   hy triad_drill.hy                              # default: ies_beeper
;;   hy triad_drill.hy --db /path/to/other.duckdb   # custom DB
;;   hy triad_drill.hy --mu                          # review mu feedback
;;   hy triad_drill.hy --driller yourname            # attribute feedback
;;   hy triad_drill.hy --limit 10                    # 10 questions

(import json)
(import random)
(import sys)
(import os)
(import time)
(import pathlib [Path])
(import argparse)

;; try duckdb import
(try
  (import duckdb)
  (except [ImportError]
    (print "duckdb not installed. pip install duckdb")
    (sys.exit 1)))

;; ── paths ────────────────────────────────────────────────────────

(setv SCRIPT-DIR (Path __file__).parent.resolve)
(setv DEFAULT-DB (or (os.environ.get "TRIAD_DRILL_DB")
                     (str (Path "/Users/alice/worlds/i/ies_beeper.duckdb"))))
(setv MU-FILE (/ SCRIPT-DIR "flashcards" ".mu-triad-feedback.json"))

;; ── terminal helpers ─────────────────────────────────────────────

(defn clear [] (os.system (if (= os.name "nt") "cls" "clear")))
(defn dim [s] (+ "\033[2m" s "\033[0m"))
(defn bold [s] (+ "\033[1m" s "\033[0m"))
(defn green [s] (+ "\033[32m" s "\033[0m"))
(defn red [s] (+ "\033[31m" s "\033[0m"))
(defn yellow [s] (+ "\033[33m" s "\033[0m"))
(defn cyan [s] (+ "\033[36m" s "\033[0m"))
(defn magenta [s] (+ "\033[35m" s "\033[0m"))
(defn hrule [] (print (dim (+ "─" (* "─" 68) "─"))))

;; ── mu feedback ──────────────────────────────────────────────────

(defn load-mu [] (if (.exists (Path MU-FILE))
                   (do (with [f (open MU-FILE)] (json.load f))) []))

(defn save-mu-entry [question ground-truth user-answer reason driller]
  (setv entries (load-mu))
  (.append entries {"question" question "ground_truth" ground-truth
                    "user_answer" user-answer "mu_reason" reason
                    "driller" driller
                    "timestamp" (time.strftime "%Y-%m-%dT%H:%M:%SZ" (time.gmtime))})
  (with [f (open MU-FILE "w")] (json.dump entries f :indent 2)))

(defn show-mu-log []
  (setv entries (load-mu))
  (when (= (len entries) 0) (print "No mu feedback yet.") (return))
  (print (bold (+ "  MU (無) TRIAD FEEDBACK — " (str (len entries)) " entries")))
  (print)
  (for [[i e] (enumerate entries)]
    (print (+ "  " (magenta (+ "[" (str (+ i 1)) "]"))
              " " (dim (.get e "timestamp" ""))))
    (print (+ "    Q: " (get (.get e "question" "") (slice 0 80))))
    (print (+ "    Their answer: " (cyan (.get e "user_answer" ""))))
    (print (+ "    " (magenta "MU: ") (.get e "mu_reason" "")))
    (print)))

;; ── question generators ──────────────────────────────────────────

(defn q-closest-pair [triad]
  "Which two are closest (lowest Jaccard distance)?"
  (setv [a b c] [(get triad "a") (get triad "b") (get triad "c")])
  (setv d-ab (get triad "d_ab"))
  (setv d-ac (get triad "d_ac"))
  (setv d-bc (get triad "d_bc"))
  (setv min-d (min d-ab d-ac d-bc))
  (setv pair (cond (= min-d d-ab) (+ a " & " b)
                   (= min-d d-ac) (+ a " & " c)
                   True (+ b " & " c)))
  {"question" (+ "Among " (bold a) ", " (bold b) ", and " (bold c)
                 " — which two interact most similarly (closest Jaccard distance)?")
   "ground_truth" (+ pair " (distance: " (.format "{:.3f}" min-d) ")")
   "hint" (+ "Distances: " a "-" b "=" (.format "{:.3f}" d-ab)
             ", " a "-" c "=" (.format "{:.3f}" d-ac)
             ", " b "-" c "=" (.format "{:.3f}" d-bc))})

(defn q-ultrametric [triad]
  "Does this triad violate the ultrametric inequality?"
  (setv [a b c] [(get triad "a") (get triad "b") (get triad "c")])
  (setv violation (get triad "ultrametric_violation"))
  {"question" (+ "Triad: " (bold a) ", " (bold b) ", " (bold c)
                 "\nDoes this triad violate the ultrametric inequality? (yes/no, and why?)")
   "ground_truth" (+ (if violation "YES — violation" "NO — ultrametric holds")
                     ". d_max=" (.format "{:.3f}" (get triad "d_max"))
                     " on edge " (get triad "unique_max_edge"))
   "hint" "Ultrametric: d(x,z) <= max(d(x,y), d(y,z)) for all x,y,z"})

(defn q-odd-one-out [triad]
  "Who is the odd one out (farthest from the other two)?"
  (setv [a b c] [(get triad "a") (get triad "b") (get triad "c")])
  (setv d-ab (get triad "d_ab"))
  (setv d-ac (get triad "d_ac"))
  (setv d-bc (get triad "d_bc"))
  ;; the odd one out is opposite the shortest edge
  (setv min-d (min d-ab d-ac d-bc))
  (setv odd (cond (= min-d d-bc) a   ;; b-c closest, a is odd
                  (= min-d d-ac) b   ;; a-c closest, b is odd
                  True c))            ;; a-b closest, c is odd
  {"question" (+ "Among " (bold a) ", " (bold b) ", and " (bold c)
                 " — who is the odd one out? (least similar interaction pattern)")
   "ground_truth" (+ odd " (the other two share more interaction overlap)")
   "hint" (+ "Think about who talks to different people than the other two")})

(defn q-gf3-balance [triad gf3-row]
  "What is the GF(3) sum of this triad?"
  (setv [a b c] [(get triad "a") (get triad "b") (get triad "c")])
  (setv gf3-sum (get gf3-row "gf3_sum"))
  (setv labels (+ (get gf3-row "label_a") "/"
                  (get gf3-row "label_b") "/"
                  (get gf3-row "label_c")))
  {"question" (+ "Triad: " (bold a) " (" (get gf3-row "label_a") "), "
                 (bold b) " (" (get gf3-row "label_b") "), "
                 (bold c) " (" (get gf3-row "label_c") ")"
                 "\nIs this triad GF(3)-balanced (sum ≡ 0 mod 3)? What does that mean for their coordination?")
   "ground_truth" (+ "GF(3) sum = " (str gf3-sum)
                     (if (= (% gf3-sum 3) 0)
                       " — BALANCED (can form a valid WEV triplet)"
                       " — UNBALANCED (needs rebalancing for coordination)"))
   "hint" (+ "Trit labels: " labels ". Sum mod 3 = 0 means balanced.")})

(defn q-message-topic [msg-a msg-b msg-c names]
  "Given sample messages, who said what?"
  (setv msgs [(, (get names 0) msg-a) (, (get names 1) msg-b) (, (get names 2) msg-c)])
  (random.shuffle msgs)
  (setv [m1 m2 m3] msgs)
  {"question" (+ "Three people in IES chat: " (bold (get names 0)) ", "
                 (bold (get names 1)) ", " (bold (get names 2))
                 "\n\nWho said each?\n"
                 "  1. \"" (get m1 1) "\"\n"
                 "  2. \"" (get m2 1) "\"\n"
                 "  3. \"" (get m3 1) "\"")
   "ground_truth" (+ "1. " (get m1 0) "\n  2. " (get m2 0) "\n  3. " (get m3 0))
   "hint" "Think about each person's typical topics and communication style"})

;; ── data loading ─────────────────────────────────────────────────

(defn load-triads [db-path limit]
  "Load random triads with GF(3) assignments and sample messages."
  (setv con (duckdb.connect db-path :read_only True))
  (setv triads (.fetchall (.execute con
    "SELECT t.*, g.trit_a, g.trit_b, g.trit_c, g.gf3_sum,
            g.label_a, g.label_b, g.label_c
     FROM all_triads t
     LEFT JOIN triad_gf3_assignment g ON t.a=g.a AND t.b=g.b AND t.c=g.c
     ORDER BY RANDOM()
     LIMIT ?"
    [limit])))
  (setv cols [c.name for c in (. (.execute con
    "SELECT t.*, g.trit_a, g.trit_b, g.trit_c, g.gf3_sum,
            g.label_a, g.label_b, g.label_c
     FROM all_triads t
     LEFT JOIN triad_gf3_assignment g ON t.a=g.a AND t.b=g.b AND t.c=g.c
     LIMIT 1") description)])

  ;; convert to list of dicts
  (setv result [])
  (for [row triads]
    (setv d {})
    (for [[i col] (enumerate cols)]
      (setv (get d col) (get row i)))
    (.append result d))

  ;; also load sample messages per person for q-message-topic
  (setv msg-cache {})
  (setv people (set))
  (for [t result]
    (.add people (get t "a"))
    (.add people (get t "b"))
    (.add people (get t "c")))
  (for [p people]
    (try
      (setv msgs (.fetchall (.execute con
        "SELECT text FROM ies_messages WHERE sender_name = ? AND text IS NOT NULL AND length(text) > 20 AND length(text) < 200 ORDER BY RANDOM() LIMIT 5" [p])))
      (setv (get msg-cache p) (lfor m msgs (get m 0)))
      (except [e Exception]
        (setv (get msg-cache p) []))))

  (.close con)
  (, result msg-cache))

;; ── main drill session ───────────────────────────────────────────

(defn run-session [triads msg-cache driller]
  (setv total (len triads))
  (setv correct 0)
  (setv mu-count 0)
  (setv start-time (time.time))
  (setv generators [q-closest-pair q-ultrametric q-odd-one-out])

  (for [[i triad] (enumerate triads)]
    (clear)
    (setv num (+ i 1))

    ;; pick question type
    (setv gen (random.choice generators))

    ;; special: if all three have messages, sometimes do attribution
    (setv names [(get triad "a") (get triad "b") (get triad "c")])
    (setv has-msgs (all (gfor n names (>= (len (.get msg-cache n [])) 1))))
    (when (and has-msgs (< (random.random) 0.3))
      (setv gen None))

    (if (is gen None)
      ;; message attribution question
      (do
        (setv qa (q-message-topic
                   (random.choice (get msg-cache (get names 0)))
                   (random.choice (get msg-cache (get names 1)))
                   (random.choice (get msg-cache (get names 2)))
                   names)))
      ;; structural question
      (do
        (setv qa (if (= gen q-gf3-balance)
                   (q-gf3-balance triad triad)
                   (gen triad)))))

    ;; header
    (print (bold (+ "  TRIAD QUIZ " (str num) "/" (str total))))
    (print (+ "  " (dim (+ "correct: " (str correct) "/" (str i)
                 (if (> mu-count 0) (+ "  mu: " (str mu-count)) "")))))
    (hrule)
    (print)

    ;; question
    (print (+ "  " (.get qa "question" "?")))
    (print)
    (print (dim (+ "  Hint: " (.get qa "hint" ""))))
    (print)

    ;; open-ended input
    (print (bold "  Your answer (type freely, or [m] mu, [q] quit):"))
    (setv answer (.strip (input "  > ")))

    (when (in (.lower answer) ["q" "quit"])
      (break))

    (when (in (.lower answer) ["m" "mu" "wu"])
      (print)
      (print (magenta "  MU (無) — Why is this question wrong/unanswerable?"))
      (setv reason (.strip (input "  > ")))
      (when (> (len reason) 0)
        (save-mu-entry (.get qa "question" "") (.get qa "ground_truth" "")
                       answer reason driller)
        (+= mu-count 1))
      (input (dim "  [Enter] next"))
      (continue))

    ;; reveal ground truth
    (print)
    (hrule)
    (print)
    (print (green "  GROUND TRUTH:"))
    (print (+ "  " (green (.get qa "ground_truth" "?"))))
    (print)
    (hrule)
    (print)

    ;; self-score + mu option
    (print (+ "  " (green "[y]") " I was right   "
              (red "[n]") " I was wrong   "
              (magenta "[m]") " mu (無)   "
              (dim "[q] quit")))
    (setv resp (.strip (.lower (input "  > "))))

    (cond
      (in resp ["q" "quit"]) (break)
      (in resp ["m" "mu" "wu"])
        (do
          (print (magenta "  MU (無) — Why is the ground truth wrong?"))
          (setv reason (.strip (input "  > ")))
          (when (> (len reason) 0)
            (save-mu-entry (.get qa "question" "") (.get qa "ground_truth" "")
                           answer reason driller)
            (+= mu-count 1))
          (input (dim "  [Enter] next")))
      (in resp ["y" "yes" ""])
        (+= correct 1)
      True None))

  ;; summary
  (setv elapsed (- (time.time) start-time))
  (setv seen (min (+ i 1) total))
  (clear)
  (print)
  (print (bold "  ══ TRIAD QUIZ COMPLETE ══"))
  (print)
  (print (+ "  Questions: " (str seen) "/" (str total)))
  (print (+ "  Correct:   " (green (str correct))))
  (print (+ "  Mu (無):   " (magenta (str mu-count))))
  (when (> (- seen mu-count) 0)
    (print (+ "  Accuracy:  " (.format "{:.1f}%" (* (/ correct (max 1 (- seen mu-count))) 100)))))
  (print (+ "  Time:      " (.format "{:.0f}" (/ elapsed 60)) "m "
            (.format "{:.0f}" (% elapsed 60)) "s"))
  (print))

;; ── CLI ──────────────────────────────────────────────────────────

(defn main []
  (setv p (argparse.ArgumentParser :description "Open-ended triadic quiz from DuckDB"))
  (.add-argument p "--db" :default DEFAULT-DB :help "Path to DuckDB with all_triads table")
  (.add-argument p "--limit" :type int :default 20 :help "Number of questions")
  (.add-argument p "--driller" :default (or (os.environ.get "USER") "anon"))
  (.add-argument p "--mu" :action "store_true" :help "Review mu feedback log")
  (setv args (.parse-args p))

  (when args.mu
    (show-mu-log)
    (sys.exit 0))

  (print (dim (+ "Loading triads from " args.db "...")))
  (setv [triads msg-cache] (load-triads args.db (* args.limit 2)))

  (when (= (len triads) 0)
    (print "No triads found in database.")
    (sys.exit 1))

  ;; trim to limit
  (when (> (len triads) args.limit)
    (setv triads (cut triads 0 args.limit)))

  (run-session triads msg-cache args.driller))

(main)
