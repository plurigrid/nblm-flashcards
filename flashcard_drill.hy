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

(setv CARDS-DIR (Path (or (os.environ.get "NBLM_FLASHCARDS_DIR")
                         (str (/ (Path __file__).parent.resolve "flashcards")))))
(setv STATE-FILE (/ CARDS-DIR ".drill-state.json"))
(setv MU-FILE (/ CARDS-DIR ".mu-feedback.json"))

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
    {"missed" [] "seen" 0 "correct" 0 "streak" 0 "best-streak" 0 "mu" 0}))

(defn save-state [state]
  (with [f (open STATE-FILE "w")]
    (json.dump state f :indent 2)))

;; ── mu (無) feedback persistence ─────────────────────────────

(defn load-mu-feedback []
  (if (.exists (Path MU-FILE))
    (do (with [f (open MU-FILE)] (json.load f)))
    []))

(defn save-mu-entry [card reason driller]
  "Save a mu/wu rejection: the driller unasks the question with a reason."
  (setv entries (load-mu-feedback))
  (.append entries {"q" (.get card "q" "")
                    "a" (.get card "a" "")
                    "repo" (.get card "repo" "")
                    "mu_reason" reason
                    "driller" driller
                    "timestamp" (time.strftime "%Y-%m-%dT%H:%M:%SZ" (time.gmtime))})
  (with [f (open MU-FILE "w")]
    (json.dump entries f :indent 2)))

;; ── main ──────────────────────────────────────────────────────

(defn parse-args []
  (setv p (argparse.ArgumentParser :description "Terminal flashcard drill"))
  (.add-argument p "--file" :default (str (/ CARDS-DIR "flashcards.json")))
  (.add-argument p "--repo" :default None :help "Filter by repo (substring match)")
  (.add-argument p "--missed" :action "store_true" :help "Retry missed cards from last session")
  (.add-argument p "--quiz" :action "store_true" :help "Use quiz.json instead")
  (.add-argument p "--limit" :type int :default 0 :help "Max cards per session (0=all)")
  (.add-argument p "--sequential" :action "store_true" :help "Don't shuffle")
  (.add-argument p "--driller" :default (or (os.environ.get "USER") "anon")
                 :help "Your name (for mu feedback attribution)")
  (.add-argument p "--mu" :action "store_true" :help "Review mu (無) feedback log")
  (.parse-args p))

(defn run-flashcard-session [cards driller]
  (setv total (len cards))
  (setv correct 0)
  (setv missed [])
  (setv mu-count 0)
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
                 "")
               (if (> mu-count 0) (+ "  mu: " (str mu-count)) "")))))
    (hrule)
    (print)

    ;; question
    (print (bold "  Q: ") q)
    (print)
    (print (dim "  [Enter] reveal  [m] mu (無) unask  [q] quit"))

    ;; wait for reveal or mu
    (setv inp (.strip (.lower (input ""))))
    (when (= inp "q")
      (break))
    (when (in inp ["m" "mu" "wu"])
      ;; mu: reject the question's premise before seeing the answer
      (print)
      (print (magenta "  MU (無) — This question is wrong, misleading, or should not be asked."))
      (print (magenta "  Why? (your feedback for the card authors):"))
      (setv reason (.strip (input "  > ")))
      (when (> (len reason) 0)
        (save-mu-entry card reason driller)
        (+= mu-count 1)
        (print (dim "  Feedback saved. The authors will see this.")))
      (input (dim "  [Enter] next"))
      (continue))

    ;; answer
    (hrule)
    (print)
    (print (green "  A: ") a)
    (print)
    (hrule)
    (print)
    (print (+ "  " (green "[y]") " got it   "
              (red "[n]") " missed   "
              (magenta "[m]") " mu (無)   "
              (yellow "[s]") " skip   "
              (dim "[q] quit")))

    (setv resp (.strip (.lower (input "  > "))))
    (cond
      (= resp "q") (break)
      (= resp "s") (continue)
      (in resp ["m" "mu" "wu"])
        (do
          ;; mu after seeing the answer — can disagree with the answer too
          (print)
          (print (magenta "  MU (無) — The question or answer is wrong/misleading."))
          (print (magenta "  Why? (your feedback):"))
          (setv reason (.strip (input "  > ")))
          (when (> (len reason) 0)
            (save-mu-entry card reason driller)
            (+= mu-count 1)
            (print (dim "  Feedback saved.")))
          (input (dim "  [Enter] next")))
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
  (setv seen (min (+ (len missed) correct mu-count) total))
  (clear)
  (print)
  (print (bold "  ══ SESSION COMPLETE ══"))
  (print)
  (print (+ "  Cards:     " (str seen) "/" (str total)))
  (print (+ "  Correct:   " (green (str correct))))
  (print (+ "  Missed:    " (red (str (len missed)))))
  (print (+ "  Mu (無):   " (magenta (str mu-count))))
  (when (> seen 0)
    (print (+ "  Accuracy:  " (.format "{:.1f}%" (* (/ correct (max 1 (- seen mu-count))) 100)))))
  (print (+ "  Streak:    " (yellow (str best-streak)) " best"))
  (print (+ "  Time:      " (.format "{:.0f}" (/ elapsed 60)) "m "
            (.format "{:.0f}" (% elapsed 60)) "s"))
  (print)

  ;; save state
  (setv state (load-state))
  (setv (get state "missed") missed)
  (+= (get state "seen") seen)
  (+= (get state "correct") correct)
  (+= (get state "mu") mu-count)
  (when (> best-streak (.get state "best-streak" 0))
    (setv (get state "best-streak") best-streak))
  (save-state state)

  (when (> (len missed) 0)
    (print (dim (+ "  " (str (len missed))
                   " missed cards saved. Run with --missed to retry."))))
  (when (> mu-count 0)
    (print (dim (+ "  " (str mu-count)
                   " mu rejections saved to .mu-feedback.json"))))
  (print))

(defn run-quiz-session [cards driller]
  (setv total (len cards))
  (setv correct 0)
  (setv mu-count 0)
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
    (print (+ "  " (dim (+ "correct: " (str correct) "/" (str i)
               (if (> mu-count 0) (+ "  mu: " (str mu-count)) "")))))
    (hrule)
    (print)
    (print (bold (+ "  " q)))
    (print)
    (for [[k v] (sorted (.items options))]
      (print (+ "    " (yellow k) ". " v)))
    (print)

    (setv resp (.strip (.upper (input "  Your answer (A/B/C/D), [M]u (無), or [Q]uit: "))))
    (when (= resp "Q") (break))
    (when (in resp ["M" "MU" "WU"])
      (print)
      (print (magenta "  MU (無) — This question is wrong, misleading, or none of the options are correct."))
      (print (magenta "  Why? (your feedback):"))
      (setv reason (.strip (input "  > ")))
      (when (> (len reason) 0)
        (save-mu-entry item reason driller)
        (+= mu-count 1)
        (print (dim "  Feedback saved.")))
      (input (dim "  [Enter] next"))
      (continue))

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
  (when (> mu-count 0)
    (print (+ "  Mu (無): " (magenta (str mu-count)) " questions challenged")))
  (print (+ "  Time:  " (.format "{:.0f}" (/ elapsed 60)) "m "
            (.format "{:.0f}" (% elapsed 60)) "s"))
  (print))

(defn show-mu-log []
  "Display the mu (無) feedback log for card authors to review."
  (setv entries (load-mu-feedback))
  (when (= (len entries) 0)
    (print "No mu (無) feedback yet.")
    (return))
  (print (bold (+ "  ══ MU (無) FEEDBACK LOG — " (str (len entries)) " rejections ══")))
  (print)
  (for [[i entry] (enumerate entries)]
    (print (+ "  " (magenta (+ "[" (str (+ i 1)) "]"))
              " " (dim (.get entry "timestamp" ""))))
    (print (+ "    " (cyan (.get entry "repo" ""))
              "  by " (yellow (.get entry "driller" "anon"))))
    (print (+ "    Q: " (.get entry "q" "")[:80]))
    (print (+ "    " (magenta "MU: ") (.get entry "mu_reason" "")))
    (print)))

(defn main []
  (setv args (parse-args))

  ;; --mu: show feedback log
  (when args.mu
    (show-mu-log)
    (sys.exit 0))

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
    (print (+ "Filtered to " (str (len cards)) " cards matching '" args.repo "'")))

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
    (run-quiz-session cards args.driller)
    (run-flashcard-session cards args.driller)))

(main)
