#!/usr/bin/env hy
;; nblm_sources.hy — Create a NotebookLM notebook via Discovery Engine API
;;
;; Creates notebook "Empire = Posterior Support" and adds three sources:
;;   1. https://arxiv.org/abs/2303.10798  (monotile / einstein hat)
;;   2. https://arxiv.org/abs/2306.12672  (Wong word-to-world)
;;   3. https://github.com/chrisreade/PenroseKiteDart (Reade codebase)
;;
;; Auth: gcloud auth print-access-token
;; Project: 302712368086
;; Output: notebook ID -> /Users/alice/worlds/n/notebook_id.txt

(import subprocess)
(import json)
(import sys)
(import time)

;; ════════════════════════════════════════════════════════════════
;; Configuration
;; ════════════════════════════════════════════════════════════════

(setv PROJECT-NUMBER "302712368086")
(setv LOCATION "global")
(setv BASE-URL
  (.format "https://{}-discoveryengine.googleapis.com/v1alpha/projects/{}/locations/{}"
           LOCATION PROJECT-NUMBER LOCATION))
(setv NOTEBOOK-TITLE "Empire = Posterior Support")
(setv OUTPUT-PATH "/Users/alice/worlds/n/notebook_id.txt")

(setv SOURCES [
  {"webUri" "https://arxiv.org/abs/2303.10798"
   "label"  "monotile"}
  {"webUri" "https://arxiv.org/abs/2306.12672"
   "label"  "Wong word-to-world"}
  {"webUri" "https://github.com/chrisreade/PenroseKiteDart"
   "label"  "Reade codebase"}])

;; ════════════════════════════════════════════════════════════════
;; Auth — get bearer token via flox activate -- gcloud
;; ════════════════════════════════════════════════════════════════

(defn get-token []
  "Retrieve a fresh bearer token from gcloud."
  (setv result (subprocess.run
    ["flox" "activate" "--" "gcloud" "auth" "print-access-token"]
    :capture-output True :text True :timeout 30))
  (when (!= result.returncode 0)
    (print f"ERROR: gcloud auth failed: {result.stderr}" :file sys.stderr)
    (sys.exit 1))
  (setv token (.strip result.stdout))
  (when (not token)
    (print "ERROR: empty token from gcloud" :file sys.stderr)
    (sys.exit 1))
  token)

;; ════════════════════════════════════════════════════════════════
;; curl helper — shells out to curl via subprocess
;; ════════════════════════════════════════════════════════════════

(defn curl-json [method url token #** kwargs]
  "Call curl with JSON content-type and bearer auth. Return parsed JSON."
  (setv body (.get kwargs "body" None))
  (setv cmd ["curl" "-s" "-X" method
             "-H" f"Authorization: Bearer {token}"
             "-H" "Content-Type: application/json"
             "-H" "x-goog-user-project: merovingians"])
  (when body
    (.extend cmd ["-d" (json.dumps body)]))
  (.append cmd url)

  (print f"  curl {method} {url}")
  (setv result (subprocess.run cmd :capture-output True :text True :timeout 60))

  (when (!= result.returncode 0)
    (print f"ERROR: curl failed (exit {result.returncode}): {result.stderr}"
           :file sys.stderr)
    (return None))

  (try
    (json.loads result.stdout)
    (except [json.JSONDecodeError]
      (setv preview (cut result.stdout 0 500))
      (print f"ERROR: non-JSON response: {preview}" :file sys.stderr)
      None)))

;; ════════════════════════════════════════════════════════════════
;; Notebook Operations
;; ════════════════════════════════════════════════════════════════

(defn create-notebook [token title]
  "POST to create a new NotebookLM notebook. Return the full resource."
  (setv url f"{BASE-URL}/notebooks")
  (setv body {"title" title})
  (curl-json "POST" url token :body body))

(defn extract-notebook-id [resource]
  "Extract the notebook ID from the resource name or notebookId field.
   name looks like: projects/302712368086/locations/global/notebooks/NOTEBOOK_ID"
  (setv name (.get resource "name" ""))
  (when name
    (get (.split name "/") -1)))

(defn add-source [token notebook-id source-spec]
  "POST a web source to the notebook."
  (setv url f"{BASE-URL}/notebooks/{notebook-id}/sources:batchCreate")
  (setv body {"requests" [{"source" {"webUri" (get source-spec "webUri")}}]})
  (curl-json "POST" url token :body body))

;; ════════════════════════════════════════════════════════════════
;; Main
;; ════════════════════════════════════════════════════════════════

(defn main []
  (print "╔══════════════════════════════════════════════════════════════╗")
  (print "║  nblm_sources.hy — NotebookLM via Discovery Engine API     ║")
  (print "╚══════════════════════════════════════════════════════════════╝")
  (print)

  ;; 1. Authenticate
  (print "[1/3] Acquiring bearer token...")
  (setv token (get-token))
  (setv tok-prefix (cut token 0 12))
  (setv tok-suffix (cut token -4 None))
  (print f"  token: {tok-prefix}...{tok-suffix}")
  (print)

  ;; 2. Create notebook
  (print (+ "[2/3] Creating notebook: \"" NOTEBOOK-TITLE "\""))
  (setv nb-resource (create-notebook token NOTEBOOK-TITLE))
  (when (is nb-resource None)
    (print "FATAL: notebook creation returned None" :file sys.stderr)
    (sys.exit 1))

  ;; Check for error in response
  (when (in "error" nb-resource)
    (setv err-msg (json.dumps nb-resource :indent 2))
    (print f"FATAL: API error: {err-msg}" :file sys.stderr)
    (sys.exit 1))

  (setv notebook-id (extract-notebook-id nb-resource))
  (when (not notebook-id)
    (print f"FATAL: could not extract notebook ID from: {nb-resource}"
           :file sys.stderr)
    (sys.exit 1))

  (print f"  notebook ID: {notebook-id}")
  (setv nb-name (.get nb-resource "name" "?"))
  (print f"  full name:   {nb-name}")
  (print)

  ;; 3. Add sources
  (setv nsources (len SOURCES))
  (print f"[3/3] Adding {nsources} sources...")
  (setv added 0)
  (for [src SOURCES]
    (setv src-label (get src "label"))
    (setv src-uri (get src "webUri"))
    (print f"  + {src-label}: {src-uri}")
    (setv resp (add-source token notebook-id src))
    (if (and resp (not (in "error" resp)))
      (do
        (+= added 1)
        (print "    OK"))
      (do
        (print f"    WARN: response: {resp}" :file sys.stderr)))
    ;; small delay between source additions
    (time.sleep 1))

  (print)
  (print f"  Added {added}/{nsources} sources.")
  (print)

  ;; 4. Write notebook ID to file
  (with [f (open OUTPUT-PATH "w")]
    (.write f notebook-id)
    (.write f "\n"))
  (print f"Notebook ID written to {OUTPUT-PATH}")
  (print f"  {notebook-id}")
  (print)
  (print "Done."))

(main)
