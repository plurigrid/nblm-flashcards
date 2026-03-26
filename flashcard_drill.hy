#!/usr/bin/env hy
;; flashcard_drill.hy — Terminal flashcard reviewer with spaced repetition
;;
;; Usage:
;;   hy flashcard_drill.hy                        # all cards, shuffled
;;   hy flashcard_drill.hy --repo bmorphism/TIDE  # filter by repo
;;   hy flashcard_drill.hy --missed               # retry missed from last session

(import json)
(import random)
(import sys)
(import os)
(import time)
(import pathlib [Path])
(import argparse)

(setv CARDS-DIR (Path "/Users/alice/worlds/n/nblm-flashcards/flashcards"))
(setv STATE-FILE (/ CARDS-DIR ".drill-state.json"))

;; ── terminal helpers ──────────────────────────────────────────

(defn clear []
  (os.system (if (= os.name "nt") "cls" "clear")))

(defn dim [s] (+ "\033[2m" s "\033[0m"))
(defn bold [s] (+ "\033[1m" s "\033[0m"))
(defn green [s] (+ "\033[32m" s "\033[0m"))
(defn red [s] (+ "\033[31m" s "\033[0m"))
(defn yellow [s] (+ "\033[33m" s "\033[0m"))
(defn cyan [s] (+ "\033[36m" s "\033[0m"))
(defn magenta [s] (+ "\033[35m" s "\033[0m"))

(defn hrule []
  (print (dim (+ "─" (* "─" 68) "─"))))

;; ── state persistence ─────────────────────────────────────────

(defn load-state []
  (if (.exists STATE-FILE)
    (do
      (with [f (open STATE-FILE)] (json.load f)))
    {"missed" [] "seen" 0 "correct" 0 "streak" 0 "best-streak" 0}))

(defn save-state [state]
  (with [f (open STATE-FILE "w")]
    (json.dump state f :indent 2)))

;; ── main ──────────────────────────────────────────────────────

(defn parse-args []
  (setv p (argparse.ArgumentParser :description "Terminal flashcard drill"))
  (.add-argument p "--file" :default (str (/ CARDS-DIR "flashcards.json")))
  (.add-argument p "--repo" :default None :help "Filter by repo (substring match)")
  (.add-argument p "--missed" :action "store_true" :help "Retry missed cards from last session")
  (.add-argument p "--quiz" :action "store_true" :help "Use quiz.json instead")
  (.add-argument p "--limit" :type int :default 0 :help "Max cards per session (0=all)")
  (.add-argument p "--sequential" :action "store_true" :help "Don't shuffle")
  (.parse-args p))

(defn run-flashcard-session [cards]
  (setv total (len cards))
  (setv correct 0)
  (setv missed [])
  (setv streak 0)
  (setv best-streak 0)
  (setv start-time (time.time))

  (for [[i card] (enumerate cards)]
    (clear)
    (setv num (+ i 1))
    (setv repo (.get card "repo" ""))
    (setv q (.get card "q" "?"))
    (setv a (.get card "a" "?"))
    (setv diff (.get card "difficulty" ""))

    ;; header
    (print (bold (+ "  FLASHCARD " (str num) "/" (str total))))
    (when repo
      (print (+ "  " (cyan repo)
               (if diff (+ "  " (dim diff)) ""))))
    (print (+ "  " (dim (+ "streak: " (str streak) "  correct: "
               (str correct) "/" (str i)
               (if (> i 0)
                 (+ "  (" (.format "{:.0f}" (* (/ correct i) 100)) "%)")
                 "")))))
    (hrule)
    (print)

    ;; question
    (print (bold "  Q: ") q)
    (print)
    (print (dim "  [Enter] reveal answer  [q] quit"))

    ;; wait for reveal
    (setv inp (.strip (input "")))
    (when (= inp "q")
      (break))

    ;; answer
    (hrule)
    (print)
    (print (green "  A: ") a)
    (print)
    (hrule)
    (print)
    (print (+ "  " (green "[y]") " got it   "
              (red "[n]") " missed   "
              (yellow "[s]") " skip   "
              (dim "[q] quit")))

    (setv resp (.strip (.lower (input "  > "))))
    (cond
      (= resp "q") (break)
      (= resp "s") (continue)
      (in resp ["y" "yes" ""])
        (do
          (+= correct 1)
          (+= streak 1)
          (when (> streak best-streak)
            (setv best-streak streak)))
      True
        (do
          (setv streak 0)
          (.append missed card))))

  ;; summary
  (setv elapsed (- (time.time) start-time))
  (setv seen (min (+ (len missed) correct) total))
  (clear)
  (print)
  (print (bold "  ══ SESSION COMPLETE ══"))
  (print)
  (print (+ "  Cards:     " (str seen) "/" (str total)))
  (print (+ "  Correct:   " (green (str correct))))
  (print (+ "  Missed:    " (red (str (len missed)))))
  (when (> seen 0)
    (print (+ "  Accuracy:  " (.format "{:.1f}%" (* (/ correct seen) 100)))))
  (print (+ "  Streak:    " (yellow (str best-streak)) " best"))
  (print (+ "  Time:      " (.format "{:.0f}" (/ elapsed 60)) "m "
            (.format "{:.0f}" (% elapsed 60)) "s"))
  (print)

  ;; save missed for --missed next time
  (setv state (load-state))
  (setv (get state "missed") missed)
  (+= (get state "seen") seen)
  (+= (get state "correct") correct)
  (when (> best-streak (.get state "best-streak" 0))
    (setv (get state "best-streak") best-streak))
  (save-state state)

  (when (> (len missed) 0)
    (print (dim (+ "  " (str (len missed))
                   " missed cards saved. Run with --missed to retry.")))
    (print)))

(defn run-quiz-session [cards]
  (setv total (len cards))
  (setv correct 0)
  (setv start-time (time.time))

  (for [[i item] (enumerate cards)]
    (clear)
    (setv num (+ i 1))
    (setv repo (.get item "repo" ""))
    (setv q (.get item "q" "?"))
    (setv options (.get item "options" {}))
    (setv answer (.get item "answer" "?"))
    (setv explanation (.get item "explanation" ""))

    (print (bold (+ "  QUIZ " (str num) "/" (str total))))
    (when repo (print (+ "  " (cyan repo))))
    (print (+ "  " (dim (+ "correct: " (str correct) "/" (str i)))))
    (hrule)
    (print)
    (print (bold (+ "  " q)))
    (print)
    (for [[k v] (sorted (.items options))]
      (print (+ "    " (yellow k) ". " v)))
    (print)

    (setv resp (.strip (.upper (input "  Your answer (A/B/C/D or q): "))))
    (when (= resp "Q") (break))

    (print)
    (if (= resp answer)
      (do
        (+= correct 1)
        (print (green (+ "  Correct! (" answer ")"))))
      (print (red (+ "  Wrong. Answer: " answer))))
    (when explanation
      (print (dim (+ "  " explanation))))
    (print)
    (input (dim "  [Enter] next")))

  (setv elapsed (- (time.time) start-time))
  (setv seen (min (+ i 1) total))
  (clear)
  (print)
  (print (bold "  ══ QUIZ COMPLETE ══"))
  (print (+ "  Score: " (green (+ (str correct) "/" (str seen)))
           "  (" (.format "{:.0f}%" (* (/ correct (max seen 1)) 100)) ")"))
  (print (+ "  Time:  " (.format "{:.0f}" (/ elapsed 60)) "m "
            (.format "{:.0f}" (% elapsed 60)) "s"))
  (print))

(defn main []
  (setv args (parse-args))

  ;; load cards
  (setv fpath (if args.quiz (str (/ CARDS-DIR "quiz.json")) args.file))
  (with [f (open fpath)] (setv cards (json.load f)))

  ;; --missed: use saved missed cards
  (when args.missed
    (setv state (load-state))
    (setv cards (.get state "missed" []))
    (when (= (len cards) 0)
      (print "No missed cards from last session.")
      (sys.exit 0)))

  ;; --repo filter
  (when args.repo
    (setv cards (lfor c cards :if (in args.repo (.get c "repo" "")) c))
    (print f"Filtered to {(len cards)} cards matching '{args.repo}'"))

  (when (= (len cards) 0)
    (print "No cards to drill.")
    (sys.exit 0))

  ;; shuffle unless --sequential
  (when (not args.sequential)
    (random.shuffle cards))

  ;; --limit
  (when (> args.limit 0)
    (setv cards (cut cards 0 args.limit)))

  (if args.quiz
    (run-quiz-session cards)
    (run-flashcard-session cards)))

(main)
