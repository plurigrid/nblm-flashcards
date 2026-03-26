;;; nblm-drill.el --- Flashcard drill from NotebookLM Enterprise -*- lexical-binding: t -*-

;; Usage:
;;   (load "/Users/alice/worlds/n/nblm-flashcards/nblm-drill.el")
;;   M-x nblm-drill          — flashcard session (shuffled)
;;   M-x nblm-drill-quiz     — multiple choice quiz
;;   M-x nblm-drill-repo     — filter by repo
;;   M-x nblm-drill-missed   — retry missed cards

;;; Code:

(require 'json)

(defgroup nblm-drill nil
  "NotebookLM flashcard drill."
  :group 'games)

(defvar nblm-drill-dir "/Users/alice/worlds/n/nblm-flashcards/flashcards/"
  "Directory containing flashcard JSON files.")

(defvar nblm-drill--cards nil "Current deck.")
(defvar nblm-drill--index 0 "Current card index.")
(defvar nblm-drill--correct 0)
(defvar nblm-drill--missed nil "List of missed cards.")
(defvar nblm-drill--revealed nil "Whether answer is shown.")
(defvar nblm-drill--streak 0)
(defvar nblm-drill--best-streak 0)
(defvar nblm-drill--start-time nil)
(defvar nblm-drill--mode nil "Either 'flashcard or 'quiz.")
(defvar nblm-drill--quiz-answered nil)

(defface nblm-drill-question
  '((t :weight bold :height 1.2))
  "Face for questions.")

(defface nblm-drill-answer
  '((t :foreground "#6ae46a" :height 1.1))
  "Face for answers.")

(defface nblm-drill-repo
  '((t :foreground "#6ac6db" :slant italic))
  "Face for repo names.")

(defface nblm-drill-dim
  '((t :foreground "#888888"))
  "Face for dim text.")

(defface nblm-drill-correct
  '((t :foreground "#6ae46a" :weight bold))
  "Face for correct.")

(defface nblm-drill-wrong
  '((t :foreground "#e46a6a" :weight bold))
  "Face for wrong.")

;; ── data loading ──────────────────────────────────────────────

(defun nblm-drill--load-json (file)
  "Load FILE as JSON array."
  (let ((json-array-type 'list)
        (json-object-type 'alist)
        (json-key-type 'string))
    (json-read-file (expand-file-name file nblm-drill-dir))))

(defun nblm-drill--shuffle (list)
  "Fisher-Yates shuffle of LIST."
  (let ((v (vconcat list)))
    (cl-loop for i from (1- (length v)) downto 1
             for j = (random (1+ i))
             do (cl-rotatef (aref v i) (aref v j)))
    (append v nil)))

(defun nblm-drill--repos ()
  "Get sorted unique repo names from flashcards."
  (let* ((cards (nblm-drill--load-json "flashcards.json"))
         (repos (delete-dups
                 (mapcar (lambda (c) (alist-get "repo" c nil nil #'equal))
                         cards))))
    (sort (seq-filter #'identity repos) #'string<)))

;; ── state file ────────────────────────────────────────────────

(defvar nblm-drill--state-file
  (expand-file-name ".drill-state-emacs.json" nblm-drill-dir))

(defun nblm-drill--save-missed ()
  "Save missed cards to state file."
  (let ((json-encoding-pretty-print t))
    (with-temp-file nblm-drill--state-file
      (insert (json-encode `(("missed" . ,(vconcat nblm-drill--missed))
                             ("correct" . ,nblm-drill--correct)
                             ("best-streak" . ,nblm-drill--best-streak)))))))

(defun nblm-drill--load-missed ()
  "Load missed cards from state file."
  (when (file-exists-p nblm-drill--state-file)
    (let* ((json-array-type 'list)
           (json-object-type 'alist)
           (json-key-type 'string)
           (state (json-read-file nblm-drill--state-file)))
      (alist-get "missed" state nil nil #'equal))))

;; ── display ───────────────────────────────────────────────────

(defun nblm-drill--render ()
  "Render current card in the buffer."
  (let* ((inhibit-read-only t)
         (card (nth nblm-drill--index nblm-drill--cards))
         (total (length nblm-drill--cards))
         (num (1+ nblm-drill--index))
         (repo (or (alist-get "repo" card nil nil #'equal) ""))
         (diff (or (alist-get "difficulty" card nil nil #'equal) ""))
         (q (or (alist-get "q" card nil nil #'equal) "?"))
         (a (or (alist-get "a" card nil nil #'equal) "?")))
    (erase-buffer)
    (insert "\n")
    ;; header
    (insert (propertize (format "  FLASHCARD %d/%d" num total)
                        'face 'nblm-drill-question))
    (insert "\n")
    (when (not (string-empty-p repo))
      (insert "  " (propertize repo 'face 'nblm-drill-repo))
      (when (not (string-empty-p diff))
        (insert "  " (propertize diff 'face 'nblm-drill-dim)))
      (insert "\n"))
    (insert "  "
            (propertize (format "streak: %d  correct: %d/%d%s"
                                nblm-drill--streak
                                nblm-drill--correct
                                nblm-drill--index
                                (if (> nblm-drill--index 0)
                                    (format "  (%.0f%%)"
                                            (* 100.0 (/ (float nblm-drill--correct)
                                                        nblm-drill--index)))
                                  ""))
                        'face 'nblm-drill-dim))
    (insert "\n")
    (insert (propertize "  ─────────────────────────────────────────────────\n"
                        'face 'nblm-drill-dim))
    (insert "\n")
    ;; question
    (insert (propertize "  Q: " 'face 'bold)
            (propertize q 'face 'nblm-drill-question))
    (insert "\n\n")
    ;; answer or prompt
    (if nblm-drill--revealed
        (progn
          (insert (propertize "  ─────────────────────────────────────────────────\n"
                              'face 'nblm-drill-dim))
          (insert "\n")
          (insert (propertize "  A: " 'face 'bold)
                  (propertize a 'face 'nblm-drill-answer))
          (insert "\n\n")
          (insert (propertize "  ─────────────────────────────────────────────────\n"
                              'face 'nblm-drill-dim))
          (insert "\n")
          (insert "  "
                  (propertize "[y]" 'face 'nblm-drill-correct) " got it   "
                  (propertize "[n]" 'face 'nblm-drill-wrong) " missed   "
                  (propertize "[s]" 'face 'nblm-drill-dim) " skip   "
                  (propertize "[q]" 'face 'nblm-drill-dim) " quit\n"))
      (insert "  "
              (propertize "[SPC] reveal answer   [q] quit" 'face 'nblm-drill-dim)
              "\n"))
    (goto-char (point-min))))

(defun nblm-drill--render-quiz ()
  "Render current quiz question."
  (let* ((inhibit-read-only t)
         (card (nth nblm-drill--index nblm-drill--cards))
         (total (length nblm-drill--cards))
         (num (1+ nblm-drill--index))
         (repo (or (alist-get "repo" card nil nil #'equal) ""))
         (q (or (alist-get "q" card nil nil #'equal) "?"))
         (options (alist-get "options" card nil nil #'equal))
         (answer (or (alist-get "answer" card nil nil #'equal) "?"))
         (explanation (or (alist-get "explanation" card nil nil #'equal) "")))
    (erase-buffer)
    (insert "\n")
    (insert (propertize (format "  QUIZ %d/%d" num total)
                        'face 'nblm-drill-question))
    (insert "\n")
    (when (not (string-empty-p repo))
      (insert "  " (propertize repo 'face 'nblm-drill-repo) "\n"))
    (insert "  "
            (propertize (format "correct: %d/%d" nblm-drill--correct nblm-drill--index)
                        'face 'nblm-drill-dim)
            "\n")
    (insert (propertize "  ─────────────────────────────────────────────────\n"
                        'face 'nblm-drill-dim))
    (insert "\n")
    (insert "  " (propertize q 'face 'nblm-drill-question) "\n\n")
    ;; options
    (dolist (opt (sort (mapcar #'car options)  #'string<))
      (let ((val (alist-get opt options nil nil #'equal))
            (face (cond
                   ((not nblm-drill--quiz-answered) 'default)
                   ((string= opt answer) 'nblm-drill-correct)
                   (t 'default))))
        (insert "    " (propertize (format "%s." opt) 'face 'bold) " "
                (propertize val 'face face) "\n")))
    (insert "\n")
    (if nblm-drill--quiz-answered
        (progn
          (insert (propertize "  ─────────────────────────────────────────────────\n"
                              'face 'nblm-drill-dim))
          (insert "\n")
          (when (not (string-empty-p explanation))
            (insert "  " (propertize explanation 'face 'nblm-drill-dim) "\n\n"))
          (insert "  " (propertize "[SPC] next   [q] quit" 'face 'nblm-drill-dim) "\n"))
      (insert "  " (propertize "Press A, B, C, or D   [q] quit" 'face 'nblm-drill-dim) "\n"))
    (goto-char (point-min))))

(defun nblm-drill--summary ()
  "Show session summary."
  (let* ((inhibit-read-only t)
         (elapsed (- (float-time) nblm-drill--start-time))
         (seen (min (+ (length nblm-drill--missed) nblm-drill--correct)
                    (length nblm-drill--cards)))
         (mins (floor (/ elapsed 60)))
         (secs (mod (floor elapsed) 60)))
    (erase-buffer)
    (insert "\n")
    (insert (propertize "  ══ SESSION COMPLETE ══\n\n" 'face 'nblm-drill-question))
    (insert (format "  Cards:     %d/%d\n" seen (length nblm-drill--cards)))
    (insert "  Correct:   " (propertize (number-to-string nblm-drill--correct)
                                        'face 'nblm-drill-correct) "\n")
    (insert "  Missed:    " (propertize (number-to-string (length nblm-drill--missed))
                                        'face 'nblm-drill-wrong) "\n")
    (when (> seen 0)
      (insert (format "  Accuracy:  %.1f%%\n" (* 100.0 (/ (float nblm-drill--correct) seen)))))
    (insert "  Streak:    " (propertize (number-to-string nblm-drill--best-streak)
                                        'face 'bold) " best\n")
    (insert (format "  Time:      %dm %ds\n" mins secs))
    (insert "\n")
    (nblm-drill--save-missed)
    (when (> (length nblm-drill--missed) 0)
      (insert (propertize
               (format "  %d missed cards saved. M-x nblm-drill-missed to retry.\n"
                       (length nblm-drill--missed))
               'face 'nblm-drill-dim)))
    (insert "\n  " (propertize "[q] close" 'face 'nblm-drill-dim) "\n")))

;; ── commands ──────────────────────────────────────────────────

(defun nblm-drill--reveal ()
  "Reveal the answer."
  (interactive)
  (when (and (eq nblm-drill--mode 'flashcard) (not nblm-drill--revealed))
    (setq nblm-drill--revealed t)
    (nblm-drill--render)))

(defun nblm-drill--mark-correct ()
  "Mark current card correct and advance."
  (interactive)
  (when (and (eq nblm-drill--mode 'flashcard) nblm-drill--revealed)
    (cl-incf nblm-drill--correct)
    (cl-incf nblm-drill--streak)
    (when (> nblm-drill--streak nblm-drill--best-streak)
      (setq nblm-drill--best-streak nblm-drill--streak))
    (nblm-drill--advance)))

(defun nblm-drill--mark-wrong ()
  "Mark current card wrong and advance."
  (interactive)
  (when (and (eq nblm-drill--mode 'flashcard) nblm-drill--revealed)
    (setq nblm-drill--streak 0)
    (push (nth nblm-drill--index nblm-drill--cards) nblm-drill--missed)
    (nblm-drill--advance)))

(defun nblm-drill--skip ()
  "Skip current card."
  (interactive)
  (when nblm-drill--revealed
    (nblm-drill--advance)))

(defun nblm-drill--advance ()
  "Move to next card or show summary."
  (cl-incf nblm-drill--index)
  (if (>= nblm-drill--index (length nblm-drill--cards))
      (nblm-drill--summary)
    (setq nblm-drill--revealed nil
          nblm-drill--quiz-answered nil)
    (if (eq nblm-drill--mode 'quiz)
        (nblm-drill--render-quiz)
      (nblm-drill--render))))

(defun nblm-drill--quiz-answer (choice)
  "Answer quiz with CHOICE (A/B/C/D)."
  (when (and (eq nblm-drill--mode 'quiz) (not nblm-drill--quiz-answered))
    (let* ((card (nth nblm-drill--index nblm-drill--cards))
           (answer (alist-get "answer" card nil nil #'equal)))
      (setq nblm-drill--quiz-answered t)
      (when (string= choice answer)
        (cl-incf nblm-drill--correct))
      (nblm-drill--render-quiz))))

(defun nblm-drill--quiz-a () (interactive) (nblm-drill--quiz-answer "A"))
(defun nblm-drill--quiz-b () (interactive) (nblm-drill--quiz-answer "B"))
(defun nblm-drill--quiz-c () (interactive) (nblm-drill--quiz-answer "C"))
(defun nblm-drill--quiz-d () (interactive) (nblm-drill--quiz-answer "D"))

(defun nblm-drill--quiz-next ()
  "Advance quiz after answering."
  (interactive)
  (when (and (eq nblm-drill--mode 'quiz) nblm-drill--quiz-answered)
    (nblm-drill--advance)))

(defun nblm-drill-quit ()
  "Quit drill session."
  (interactive)
  (nblm-drill--save-missed)
  (quit-window t))

;; ── keymap ────────────────────────────────────────────────────

(defvar nblm-drill-mode-map
  (let ((map (make-sparse-keymap)))
    ;; flashcard
    (define-key map (kbd "SPC") #'nblm-drill--reveal)
    (define-key map (kbd "RET") #'nblm-drill--reveal)
    (define-key map (kbd "y") #'nblm-drill--mark-correct)
    (define-key map (kbd "n") #'nblm-drill--mark-wrong)
    (define-key map (kbd "s") #'nblm-drill--skip)
    (define-key map (kbd "q") #'nblm-drill-quit)
    ;; quiz
    (define-key map (kbd "a") #'nblm-drill--quiz-a)
    (define-key map (kbd "b") #'nblm-drill--quiz-b)
    (define-key map (kbd "c") #'nblm-drill--quiz-c)
    (define-key map (kbd "d") #'nblm-drill--quiz-d)
    map)
  "Keymap for nblm-drill-mode.")

(define-derived-mode nblm-drill-mode special-mode "Drill"
  "Major mode for flashcard drilling."
  (setq buffer-read-only t
        truncate-lines nil
        word-wrap t))

;; ── entry points ──────────────────────────────────────────────

(defun nblm-drill--start (cards mode)
  "Start a drill session with CARDS in MODE ('flashcard or 'quiz)."
  (switch-to-buffer (get-buffer-create "*nblm-drill*"))
  (nblm-drill-mode)
  (setq nblm-drill--cards (nblm-drill--shuffle cards)
        nblm-drill--index 0
        nblm-drill--correct 0
        nblm-drill--missed nil
        nblm-drill--revealed nil
        nblm-drill--quiz-answered nil
        nblm-drill--streak 0
        nblm-drill--best-streak 0
        nblm-drill--start-time (float-time)
        nblm-drill--mode mode)
  (if (eq mode 'quiz)
      (nblm-drill--render-quiz)
    (nblm-drill--render)))

;;;###autoload
(defun nblm-drill ()
  "Start a flashcard drill session."
  (interactive)
  (nblm-drill--start (nblm-drill--load-json "flashcards.json") 'flashcard))

;;;###autoload
(defun nblm-drill-all ()
  "Drill all flashcards across all notebooks (merged deck)."
  (interactive)
  (let ((merged (expand-file-name "all-flashcards.json" nblm-drill-dir)))
    (if (file-exists-p merged)
        (nblm-drill--start (nblm-drill--load-json "all-flashcards.json") 'flashcard)
      (message "No merged deck yet. Run: bb nblm_merge.bb"))))

;;;###autoload
(defun nblm-drill-all-quiz ()
  "Quiz across all notebooks (merged deck)."
  (interactive)
  (let ((merged (expand-file-name "all-quiz.json" nblm-drill-dir)))
    (if (file-exists-p merged)
        (nblm-drill--start (nblm-drill--load-json "all-quiz.json") 'quiz)
      (message "No merged deck yet. Run: bb nblm_merge.bb"))))

;;;###autoload
(defun nblm-drill-quiz ()
  "Start a multiple-choice quiz session."
  (interactive)
  (nblm-drill--start (nblm-drill--load-json "quiz.json") 'quiz))

;;;###autoload
(defun nblm-drill-repo ()
  "Drill flashcards filtered by repo."
  (interactive)
  (let* ((repos (nblm-drill--repos))
         (repo (completing-read "Repo: " repos nil t))
         (all (nblm-drill--load-json "flashcards.json"))
         (filtered (seq-filter
                    (lambda (c)
                      (string= repo (alist-get "repo" c "" nil #'equal)))
                    all)))
    (if filtered
        (nblm-drill--start filtered 'flashcard)
      (message "No cards for %s" repo))))

;;;###autoload
(defun nblm-drill-missed ()
  "Retry missed cards from last session."
  (interactive)
  (let ((missed (nblm-drill--load-missed)))
    (if (and missed (> (length missed) 0))
        (nblm-drill--start missed 'flashcard)
      (message "No missed cards from last session."))))

(provide 'nblm-drill)
;;; nblm-drill.el ends here
