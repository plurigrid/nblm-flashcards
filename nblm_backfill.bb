#!/usr/bin/env bb
;; nblm_backfill.bb — Create NBLM notebooks to cover the 946-repo gap
;;
;; Pipeline:
;;   1. Read gap list → chunk into groups of 300
;;   2. Create a new NBLM Enterprise notebook per chunk
;;   3. Add DeepWiki URLs as sources (batches of 5)
;;   4. Verify ingestion status
;;   5. Run flashcard generation per notebook
;;
;; Usage:
;;   bb nblm_backfill.bb                    # full run
;;   bb nblm_backfill.bb --dry-run          # show plan only
;;   bb nblm_backfill.bb --chunk 2          # only process chunk 2
;;   bb nblm_backfill.bb --status           # check all notebook statuses

(require '[babashka.http-client :as http])
(require '[babashka.process :as p])
(require '[babashka.fs :as fs])
(require '[cheshire.core :as json])
(require '[clojure.string :as str])

;; ═══════════════════════════════════════════════════════════
;; Config
;; ═══════════════════════════════════════════════════════════

(def PROJECT-NUMBER "302712368086")
(def PROJECT-ID "merovingians")
(def NBLM-BASE (str "https://global-discoveryengine.googleapis.com/v1alpha"
                     "/projects/" PROJECT-NUMBER "/locations/global"))
(def GAP-FILE "/tmp/nblm_gap.txt")
(def STATE-FILE "/Users/alice/worlds/n/nblm-flashcards/flashcards/backfill-state.json")
(def CHUNK-SIZE 300)
(def SOURCE-BATCH-SIZE 5)
(def DEEPWIKI-BASE "https://deepwiki.com")

;; ═══════════════════════════════════════════════════════════
;; Auth
;; ═══════════════════════════════════════════════════════════

(defn get-token []
  (let [r (p/shell {:out :string :err :string}
                   "gcloud auth print-access-token")]
    (str/trim (:out r))))

(def ^:dynamic *token* nil)
(def ^:dynamic *token-time* 0)

(defn fresh-token []
  (let [now (System/currentTimeMillis)]
    (when (or (nil? *token*) (> (- now *token-time*) (* 30 60 1000)))
      (alter-var-root #'*token* (constantly (get-token)))
      (alter-var-root #'*token-time* (constantly now))))
  *token*)

;; ═══════════════════════════════════════════════════════════
;; HTTP helpers
;; ═══════════════════════════════════════════════════════════

(defn api-get [path]
  (let [resp (http/get (str NBLM-BASE path)
                       {:headers {"Authorization" (str "Bearer " (fresh-token))
                                  "Content-Type" "application/json"
                                  "x-goog-user-project" PROJECT-ID}
                        :throw false})]
    (when (= 200 (:status resp))
      (json/parse-string (:body resp) true))))

(defn api-post [path body & {:keys [retries] :or {retries 3}}]
  (loop [attempt 1]
    (let [result (try
                   (let [resp (http/post (str NBLM-BASE path)
                                         {:headers {"Authorization" (str "Bearer " (fresh-token))
                                                    "Content-Type" "application/json"
                                                    "x-goog-user-project" PROJECT-ID}
                                          :body (json/generate-string body)
                                          :throw false
                                          :timeout (* 30 1000)})]
                     (let [parsed (try (json/parse-string (:body resp) true) (catch Exception _ nil))]
                       (when (not (<= 200 (:status resp) 299))
                         (println "  API error:" (:status resp) (or (:message (:error parsed)) (:body resp))))
                       parsed))
                   (catch Exception e
                     (println (str "  Connection error (attempt " attempt "/" retries "): " (.getMessage e)))
                     ::error))]
      (if (and (= result ::error) (< attempt retries))
        (do (Thread/sleep (* attempt 2000))
            (recur (inc attempt)))
        (when (not= result ::error) result)))))

;; ═══════════════════════════════════════════════════════════
;; State persistence
;; ═══════════════════════════════════════════════════════════

(defn load-state []
  (if (fs/exists? STATE-FILE)
    (json/parse-string (slurp STATE-FILE) true)
    {:notebooks [] :completed-chunks []}))

(defn save-state [state]
  (spit STATE-FILE (json/generate-string state {:pretty true})))

;; ═══════════════════════════════════════════════════════════
;; Gap list
;; ═══════════════════════════════════════════════════════════

(defn read-gap-list []
  (->> (slurp GAP-FILE)
       str/split-lines
       (map str/trim)
       (filter #(and (seq %) (str/includes? % "/")))))

(defn deepwiki-url [repo]
  (str DEEPWIKI-BASE "/" repo))

(defn chunk-repos [repos]
  (->> repos
       (partition-all CHUNK-SIZE)
       (map-indexed (fn [i chunk]
                      {:index (inc i)
                       :repos (vec chunk)
                       :title (format "Flashcard Backfill %d/%d (%d repos)"
                                      (inc i)
                                      (int (Math/ceil (/ (count repos) (double CHUNK-SIZE))))
                                      (count chunk))}))))

;; ═══════════════════════════════════════════════════════════
;; NBLM Operations
;; ═══════════════════════════════════════════════════════════

(defn create-notebook [title]
  (println (str "  Creating notebook: " title))
  (let [resp (api-post "/notebooks" {:title title})]
    (when resp
      (let [id (or (:notebookId resp) (get resp :name))]
        (println (str "  Created: " id))
        id))))

(defn add-sources-batch [notebook-id urls]
  (let [contents (mapv (fn [url] {:webContent {:url url}}) urls)]
    (api-post (str "/notebooks/" notebook-id "/sources:batchCreate")
              {:userContents contents})))

(defn get-notebook [notebook-id]
  (api-get (str "/notebooks/" notebook-id)))

(defn count-sources [notebook-id]
  (let [nb (get-notebook notebook-id)]
    (when nb
      (let [sources (or (:sources nb) [])
            complete (count (filter #(= "SOURCE_STATUS_COMPLETE"
                                        (get-in % [:settings :status])) sources))
            error (count (filter #(= "SOURCE_STATUS_ERROR"
                                     (get-in % [:settings :status])) sources))
            pending (- (count sources) complete error)]
        {:total (count sources) :complete complete :error error :pending pending}))))

;; ═══════════════════════════════════════════════════════════
;; Pipeline
;; ═══════════════════════════════════════════════════════════

(defn existing-source-urls [notebook-id]
  "Get set of URLs already in a notebook."
  (let [nb (get-notebook notebook-id)]
    (when nb
      (->> (or (:sources nb) [])
           (map #(get-in % [:sourceId :url] (get-in % [:webContent :url] "")))
           set))))

(defn process-chunk [{:keys [index repos title]} state & {:keys [dry-run]}]
  (println)
  (println (str "═══ Chunk " index " ═══"))
  (println (str "  " (count repos) " repos"))
  (println (str "  Title: " title))
  (println (str "  First: " (first repos)))
  (println (str "  Last:  " (last repos)))
  (println)

  (when-not dry-run
    ;; Check if notebook already exists for this chunk
    (let [existing (first (filter #(= index (:chunk-index %)) (:notebooks state)))
          notebook-id (if existing
                        (do (println (str "  Resuming notebook: " (:notebook-id existing)))
                            (:notebook-id existing))
                        (create-notebook title))]
      (when-not notebook-id
        (println "  FATAL: failed to create notebook")
        (System/exit 1))

      ;; Figure out which repos still need adding
      (let [all-urls (set (map deepwiki-url repos))
            already-added (or (when existing (existing-source-urls notebook-id)) #{})
            remaining-urls (remove already-added (map deepwiki-url repos))
            url-batches (partition-all SOURCE-BATCH-SIZE remaining-urls)]

        (println (str "  Already added: " (count already-added)
                      ", remaining: " (count remaining-urls)))
        (when (seq remaining-urls)
          (println (str "  Adding in " (count url-batches) " batches..."))
          (doseq [[i batch] (map-indexed vector url-batches)]
            (print (str "  [" (inc i) "/" (count url-batches) "] "
                        (count batch) " sources... "))
            (flush)
            (let [resp (add-sources-batch notebook-id (vec batch))]
              (if resp
                (println "ok")
                (println "WARN: no response")))
            ;; rate limit courtesy
            (Thread/sleep 1000))))

      ;; Return notebook info
      (println)
      (println (str "  Notebook: " notebook-id))
      (println (str "  View: https://notebooklm.cloud.google.com/global/notebook/"
                    notebook-id "?project=" PROJECT-NUMBER))
      {:chunk-index index
       :notebook-id notebook-id
       :title title
       :repo-count (count repos)
       :repos repos})))

(defn run-status [state]
  (println)
  (println "═══ Notebook Status ═══")
  (println)
  (doseq [nb (:notebooks state)]
    (let [id (:notebook-id nb)
          counts (count-sources id)]
      (println (format "  Chunk %d: %s" (:chunk-index nb) id))
      (println (format "    Title: %s" (:title nb)))
      (println (format "    Repos: %d" (:repo-count nb)))
      (if counts
        (println (format "    Sources: %d total, %d complete, %d error, %d pending"
                         (:total counts) (:complete counts)
                         (:error counts) (:pending counts)))
        (println "    Sources: (could not fetch)"))
      (println))))

(defn run-flashcards [state]
  (println)
  (println "═══ Generating Flashcards ═══")
  (println)
  (doseq [nb (:notebooks state)]
    (let [id (:notebook-id nb)]
      (println (format "  Chunk %d: %s (%d repos)"
                       (:chunk-index nb) id (:repo-count nb)))
      (let [outdir (format "/Users/alice/worlds/n/nblm-flashcards/flashcards/chunk-%d" (:chunk-index nb))]
        (println (format "  Output: %s" outdir))
        (p/shell "hy" "n/nblm_flashcards.hy"
                 "--notebook-id" id
                 "--per-source" "10"
                 "--batch-size" "5"
                 "--difficulty" "hard"
                 "--output-dir" outdir)
        (println)))))

;; ═══════════════════════════════════════════════════════════
;; CLI
;; ═══════════════════════════════════════════════════════════

(let [args (set *command-line-args*)
      dry-run (contains? args "--dry-run")
      status-only (contains? args "--status")
      gen-cards (contains? args "--generate")
      chunk-only (some #(str/starts-with? % "--chunk=") args)
      chunk-num (when chunk-only
                  (parse-long (second (str/split (first (filter #(str/starts-with? % "--chunk=") args)) #"="))))]

  (println "╔══════════════════════════════════════════════════════════════╗")
  (println "║  nblm_backfill.bb — NotebookLM Gap Coverage Pipeline       ║")
  (println "║  946 repos → 4 notebooks × 300 sources → flashcards        ║")
  (println "╚══════════════════════════════════════════════════════════════╝")

  (cond
    ;; Status check
    status-only
    (let [state (load-state)]
      (if (seq (:notebooks state))
        (run-status state)
        (println "\n  No notebooks created yet. Run without --status first.")))

    ;; Generate flashcards from existing notebooks
    gen-cards
    (let [state (load-state)]
      (if (seq (:notebooks state))
        (run-flashcards state)
        (println "\n  No notebooks created yet. Run without --generate first.")))

    ;; Main pipeline
    :else
    (do
      (let [repos (read-gap-list)
            chunks (chunk-repos repos)
            chunks (if chunk-num
                     (filter #(= chunk-num (:index %)) chunks)
                     chunks)]

        (println)
        (println (format "  Gap: %d repos in %s" (count repos) GAP-FILE))
        (println (format "  Chunks: %d (max %d sources each)" (count chunks) CHUNK-SIZE))
        (when dry-run (println "  Mode: DRY RUN"))
        (when chunk-num (println (format "  Processing chunk %d only" chunk-num)))

        ;; Show plan
        (doseq [c chunks]
          (println (format "\n  Chunk %d: %d repos → \"%s\""
                           (:index c) (count (:repos c)) (:title c))))

        (when-not dry-run
          (let [state (load-state)
                results (doall
                          (for [c chunks]
                            (process-chunk c state)))]

            ;; Save state — merge by chunk-index, don't duplicate
            (let [new-notebooks (filterv some? results)
                  existing-indices (set (map :chunk-index (:notebooks state)))
                  truly-new (filterv #(not (existing-indices (:chunk-index %))) new-notebooks)
                  updated-state (update state :notebooks into truly-new)]
              (save-state updated-state)
              (println)
              (println (format "  State saved to %s" STATE-FILE))
              (println (format "  Created %d notebooks" (count new-notebooks)))
              (println)
              (println "  Next steps:")
              (println "    1. Wait for source ingestion (check with --status)")
              (println "    2. Generate flashcards: bb nblm_backfill.bb --generate")
              (println "    3. Merge all flashcard JSONs for unified Emacs drill"))))))))
