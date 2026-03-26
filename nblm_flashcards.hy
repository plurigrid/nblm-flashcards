#!/usr/bin/env hy
;; nblm_flashcards.hy — Generate flashcards from NotebookLM Enterprise notebook
;;
;; Strategy: Pull all 300 source titles from the enterprise notebook,
;; then use Gemini (Vertex AI) to generate flashcards grounded in
;; source metadata + DeepWiki context.
;;
;; Auth: gcloud auth print-access-token (reuses existing enterprise creds)
;; No notebooklm-py needed — pure gcloud/Vertex.
;;
;; Usage:
;;   hy nblm_flashcards.hy
;;   hy nblm_flashcards.hy --count 50 --difficulty hard

(import subprocess)
(import json)
(import sys)
(import os)
(import time)
(import pathlib [Path])
(import argparse)

;; ════════════════════════════════════════════════════════════════
;; Configuration
;; ════════════════════════════════════════════════════════════════

(setv PROJECT-NUMBER "302712368086")
(setv PROJECT-ID "merovingians")
(setv LOCATION "global")
(setv REGION "us-central1")
(setv NOTEBOOK-ID "9ca780dc-4e0f-4f57-9262-a6090af028e4")
(setv GEMINI-MODEL "gemini-2.5-flash")
(setv OUTPUT-DIR (Path "/Users/alice/worlds/n/nblm-flashcards/flashcards"))
(setv NBLM-BASE
  (.format "https://{}-discoveryengine.googleapis.com/v1alpha/projects/{}/locations/{}"
           LOCATION PROJECT-NUMBER LOCATION))

;; ════════════════════════════════════════════════════════════════
;; CLI args
;; ════════════════════════════════════════════════════════════════

(defn parse-args []
  (setv p (argparse.ArgumentParser :description "Generate flashcards from NBLM Enterprise"))
  (.add-argument p "--notebook-id" :default NOTEBOOK-ID)
  (.add-argument p "--per-source" :type int :default 10 :help "Flashcards per source")
  (.add-argument p "--batch-size" :type int :default 5 :help "Sources per Gemini call")
  (.add-argument p "--difficulty" :choices ["easy" "medium" "hard"] :default "hard")
  (.add-argument p "--format" :choices ["json" "markdown"] :default "json")
  (.add-argument p "--output-dir" :default (str OUTPUT-DIR))
  (.add-argument p "--model" :default GEMINI-MODEL)
  (.parse-args p))

;; ════════════════════════════════════════════════════════════════
;; Auth
;; ════════════════════════════════════════════════════════════════

(defn get-token []
  (setv r (subprocess.run ["gcloud" "auth" "print-access-token"]
            :capture-output True :text True :timeout 30))
  (when (!= r.returncode 0)
    (print f"ERROR: gcloud auth failed: {r.stderr}" :file sys.stderr)
    (sys.exit 1))
  (.strip r.stdout))

;; ════════════════════════════════════════════════════════════════
;; HTTP helper (shells to curl)
;; ════════════════════════════════════════════════════════════════

(defn curl-json [method url token #** kw]
  (setv body (.get kw "body" None))
  (setv cmd ["curl" "-s" "-X" method
             "-H" f"Authorization: Bearer {token}"
             "-H" "Content-Type: application/json"
             "-H" f"x-goog-user-project: {PROJECT-ID}"])
  (when body
    (.extend cmd ["-d" (if (isinstance body str) body (json.dumps body))]))
  (.append cmd url)
  (setv r (subprocess.run cmd :capture-output True :text True :timeout 300))
  (when (!= r.returncode 0)
    (return None))
  (try
    (json.loads r.stdout)
    (except [json.JSONDecodeError]
      None)))

;; ════════════════════════════════════════════════════════════════
;; NotebookLM Enterprise — fetch sources
;; ════════════════════════════════════════════════════════════════

(defn fetch-notebook-sources [token notebook-id]
  "GET notebook and extract source titles + deepwiki URLs."
  (setv url f"{NBLM-BASE}/notebooks/{notebook-id}")
  (setv data (curl-json "GET" url token))
  (when (or (is data None) (in "error" data))
    (print f"ERROR fetching notebook: {data}" :file sys.stderr)
    (return []))
  (setv sources (.get data "sources" []))
  (setv result [])
  (for [s sources]
    (setv title (.get s "title" "unknown"))
    (setv url-guess f"https://deepwiki.com/{title}")
    (.append result {"title" title "url" url-guess}))
  result)

;; ════════════════════════════════════════════════════════════════
;; Vertex AI Gemini — generate flashcards
;; ════════════════════════════════════════════════════════════════

(defn gemini-generate [token prompt #** kw]
  "Call Gemini via Vertex AI. Returns the text response."
  (setv model (.get kw "model" GEMINI-MODEL))
  (setv url (.format
    "https://{}-aiplatform.googleapis.com/v1/projects/{}/locations/{}/publishers/google/models/{}:generateContent"
    REGION PROJECT-NUMBER REGION model))
  (setv payload
    {"contents" [{"role" "user"
                  "parts" [{"text" prompt}]}]
     "generationConfig" {"temperature" 0.7
                         "maxOutputTokens" 65536
                         "topP" 0.95}})
  (setv data (curl-json "POST" url token :body payload))
  (when (or (is data None) (in "error" data))
    (print f"ERROR from Gemini: {data}" :file sys.stderr)
    (return None))
  (try
    (get (get (get (get (get data "candidates") 0) "content") "parts") 0 "text")
    (except [e [KeyError IndexError]]
      (print f"ERROR parsing Gemini response: {e}" :file sys.stderr)
      None)))

(defn build-flashcard-prompt [sources per-source difficulty]
  "Build the prompt for Gemini to generate flashcards for a batch of sources."
  (setv source-list
    (.join "\n" (lfor s sources
      (+ "- " (get s "title") ": " (get s "url")))))
  (setv total (* (len sources) per-source))
  (.format "You are a quiz master creating flashcards for a software engineering team.

Below are {} GitHub repositories from the bmorphism and plurigrid organizations,
indexed via DeepWiki. Each repo is a source in our NotebookLM Enterprise notebook.

SOURCES:
{}

TASK:
Generate exactly {} flashcards per source ({} total) at {} difficulty level.
Each flashcard should test understanding of a specific repo's purpose,
architecture, key APIs, or relationship to other repos in the ecosystem.

Every source MUST have exactly {} flashcards. Cover diverse aspects of each repo.

OUTPUT FORMAT:
Return ONLY a valid JSON array (no markdown fences, no commentary).
Each element: {{\"q\": \"<question>\", \"a\": \"<answer>\", \"repo\": \"<org/repo>\", \"difficulty\": \"{}\"}}

Generate all {} flashcards now:" (len sources) source-list per-source total difficulty per-source difficulty total))

(defn build-quiz-prompt [sources per-source difficulty]
  "Build prompt for multiple-choice quiz for a batch of sources."
  (setv source-list
    (.join "\n" (lfor s sources
      (+ "- " (get s "title")))))
  (setv total (* (len sources) per-source))
  (.format "You are creating a multiple-choice quiz about these {} repositories:

{}

Generate {} questions per source ({} total) at {} difficulty.
Each question has 4 options (A-D) with exactly one correct answer.
Every source MUST have exactly {} questions.

OUTPUT FORMAT:
Return ONLY a valid JSON array.
Each element: {{\"q\": \"<question>\", \"options\": {{\"A\": \"...\", \"B\": \"...\", \"C\": \"...\", \"D\": \"...\"}}, \"answer\": \"<letter>\", \"explanation\": \"<why>\", \"repo\": \"<org/repo>\"}}

Generate all {} questions now:" (len sources) source-list per-source total difficulty per-source total))

;; ════════════════════════════════════════════════════════════════
;; Output formatting
;; ════════════════════════════════════════════════════════════════

(defn save-json [data path]
  (with [f (open path "w")]
    (json.dump data f :indent 2 :ensure-ascii False))
  (print f"  Saved: {path} ({(len data)} items)"))

(defn save-markdown [data path artifact-type]
  (with [f (open path "w")]
    (.write f f"# {artifact-type}\n\n")
    (.write f f"Generated from NotebookLM Enterprise notebook\n")
    (.write f f"Notebook: {NOTEBOOK-ID}\n")
    (.write f f"Sources: 300 repos (bmorphism + plurigrid)\n\n---\n\n")
    (if (= artifact-type "Flashcards")
      (for [[i card] (enumerate data :start 1)]
        (setv repo-tag (if (in "repo" card) (+ " [" (get card "repo") "]") ""))
        (setv q-text (.get card "q" "?"))
        (setv a-text (.get card "a" "?"))
        (.write f (+ "### Card " (str i) repo-tag "\n\n"))
        (.write f (+ "**Q:** " q-text "\n\n"))
        (.write f (+ "**A:** " a-text "\n\n---\n\n")))
      ;; quiz format
      (for [[i item] (enumerate data :start 1)]
        (setv repo-tag (if (in "repo" item) (+ " [" (get item "repo") "]") ""))
        (setv q-text (.get item "q" "?"))
        (.write f (+ "### Question " (str i) repo-tag "\n\n"))
        (.write f (+ "**" q-text "**\n\n"))
        (for [[k v] (.items (.get item "options" {}))]
          (.write f (+ "- **" k ".** " v "\n")))
        (.write f (+ "\n**Answer:** " (.get item "answer" "?") "\n"))
        (.write f (+ "**Explanation:** " (.get item "explanation" "") "\n\n---\n\n")))))
  (print f"  Saved: {path}"))

(defn parse-json-response [text]
  "Extract JSON array from Gemini response, handling fences and truncation."
  (setv cleaned (.strip text))
  ;; strip markdown fences
  (when (.startswith cleaned "```")
    (setv lines (.split cleaned "\n"))
    ;; if last line is ```, strip it; otherwise response was truncated
    (if (.startswith (.strip (get lines -1)) "```")
      (setv cleaned (.join "\n" (cut lines 1 -1)))
      (setv cleaned (.join "\n" (cut lines 1 None)))))
  (when (.startswith cleaned "json")
    (setv cleaned (cut cleaned 4)))
  (setv cleaned (.strip cleaned))
  ;; try direct parse
  (try
    (json.loads cleaned)
    (except [json.JSONDecodeError]
      ;; find the array
      (setv start (.find cleaned "["))
      (when (< start 0)
        (print "ERROR: no JSON array found in response" :file sys.stderr)
        (return []))
      (setv arr-text (cut cleaned start None))
      ;; try as-is
      (try
        (json.loads arr-text)
        (except [json.JSONDecodeError]
          ;; truncated — find last complete object and close the array
          (setv last-obj (.rfind arr-text "}"))
          (when (< last-obj 0)
            (print "ERROR: no complete JSON object in response" :file sys.stderr)
            (return []))
          (setv repaired (+ (cut arr-text 0 (+ last-obj 1)) "\n]"))
          (try
            (do
              (setv result (json.loads repaired))
              (print (+ "WARN: repaired truncated JSON, recovered "
                        (str (len result)) " items") :file sys.stderr)
              result)
            (except [json.JSONDecodeError]
              (print "ERROR: could not repair truncated JSON" :file sys.stderr)
              [])))))))

;; ════════════════════════════════════════════════════════════════
;; Main
;; ════════════════════════════════════════════════════════════════

(defn chunk [lst n]
  "Split lst into sublists of size n."
  (lfor i (range 0 (len lst) n)
    (cut lst i (+ i n))))

(defn generate-batched [sources per-source batch-size difficulty model prompt-fn label]
  "Generate items in batches, refreshing token as needed."
  (setv batches (chunk sources batch-size))
  (setv total-expected (* (len sources) per-source))
  (setv all-items [])
  (setv token (get-token))
  (setv token-time (time.time))
  (print f"  {(len batches)} batches of {batch-size} sources, {per-source}/source = {total-expected} target")
  (for [[i batch] (enumerate batches :start 1)]
    ;; refresh token every 30 minutes
    (when (> (- (time.time) token-time) 1800)
      (print "    (refreshing token...)")
      (setv token (get-token))
      (setv token-time (time.time)))
    (setv batch-target (* (len batch) per-source))
    (print f"  [{i}/{(len batches)}] {(len batch)} sources, expecting {batch-target} {label}..." :flush True)
    (setv prompt (prompt-fn batch per-source difficulty))
    (setv raw (gemini-generate token prompt :model model))
    (if (is raw None)
      (print f"    WARN: batch {i} returned None, skipping")
      (do
        (setv items (or (parse-json-response raw) []))
        (print f"    got {(len items)}")
        (.extend all-items items)))
    ;; small delay to avoid rate limits
    (time.sleep 1))
  (print f"  Total: {(len all-items)} {label}")
  all-items)

(defn main []
  (setv args (parse-args))
  (setv outdir (Path args.output_dir))
  (.mkdir outdir :parents True :exist-ok True)

  (print "╔══════════════════════════════════════════════════════════════╗")
  (print "║  nblm_flashcards.hy — Enterprise Flashcard Generator       ║")
  (print "║  Gemini × Vertex AI × NotebookLM Enterprise (3K mode)      ║")
  (print "╚══════════════════════════════════════════════════════════════╝")
  (print)

  ;; 1. Auth
  (print "[1/4] Authenticating...")
  (setv token (get-token))
  (print f"  Token: {(cut token 0 12)}...{(cut token -4 None)}")
  (print)

  ;; 2. Fetch sources from enterprise notebook
  (print f"[2/4] Fetching sources from notebook {args.notebook_id}...")
  (setv sources (fetch-notebook-sources token args.notebook_id))
  (print f"  Found {(len sources)} sources")
  (setv bm (lfor s sources :if (in "bmorphism" (get s "title")) s))
  (setv pg (lfor s sources :if (in "plurigrid" (get s "title")) s))
  (print f"    bmorphism: {(len bm)}")
  (print f"    plurigrid: {(len pg)}")
  (setv total-target (* (len sources) args.per_source))
  (print f"  Target: {total-target} flashcards + {total-target} quiz questions")
  (print)

  (when (= (len sources) 0)
    (print "FATAL: no sources found" :file sys.stderr)
    (sys.exit 1))

  ;; 3. Generate flashcards in batches
  (print f"[3/4] Generating flashcards via {args.model} (difficulty={args.difficulty})...")
  (setv flashcards (generate-batched
    sources args.per_source args.batch_size args.difficulty args.model
    build-flashcard-prompt "flashcards"))
  (print)

  ;; Save flashcards
  (setv fc-json-path (/ outdir "flashcards.json"))
  (setv fc-md-path (/ outdir "flashcards.md"))
  (save-json flashcards fc-json-path)
  (save-markdown flashcards fc-md-path "Flashcards")
  (print)

  ;; 4. Generate quiz in batches
  (print f"[4/4] Generating quiz via {args.model} (difficulty={args.difficulty})...")
  (setv quiz (generate-batched
    sources args.per_source args.batch_size args.difficulty args.model
    build-quiz-prompt "quiz questions"))
  (print)

  ;; Save quiz
  (setv quiz-json-path (/ outdir "quiz.json"))
  (setv quiz-md-path (/ outdir "quiz.md"))
  (save-json quiz quiz-json-path)
  (save-markdown quiz quiz-md-path "Quiz")

  (print)
  (print f"Output: {outdir}/")
  (for [f (sorted (.iterdir outdir))]
    (when (.is-file f)
      (setv sz (. (.stat f) st_size))
      (print (+ "  " (. f name) "  (" (.format "{:,}" sz) " bytes)"))))
  (print)
  (print (+ "Done. " (str (len flashcards)) " flashcards + " (str (len quiz)) " quiz questions.")))

(main)
