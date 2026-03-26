#!/usr/bin/env bb
;; nblm_merge.bb — Merge flashcard JSONs from all chunks + original into unified deck
;;
;; Usage:
;;   bb nblm_merge.bb

(require '[cheshire.core :as json])
(require '[babashka.fs :as fs])
(require '[clojure.string :as str])

(def FLASHCARD-DIR "/Users/alice/worlds/n/nblm-flashcards/flashcards")

(println "═══ Merging Flashcard Decks ═══")
(println)

;; Find all flashcards.json and quiz.json across chunks + root
(let [fc-files (->> (fs/glob FLASHCARD-DIR "**/flashcards.json")
                    (mapv str)
                    sort)
      qz-files (->> (fs/glob FLASHCARD-DIR "**/quiz.json")
                    (mapv str)
                    sort)]

  (println (format "  Found %d flashcard files, %d quiz files" (count fc-files) (count qz-files)))
  (doseq [f fc-files] (println (str "    " f)))
  (println)

  ;; Merge flashcards
  (let [all-fc (vec (mapcat #(json/parse-string (slurp %) true) fc-files))
        all-qz (vec (mapcat #(json/parse-string (slurp %) true) qz-files))
        ;; Dedupe by q text
        fc-deduped (vec (vals (into {} (map (fn [c] [(:q c) c]) all-fc))))
        qz-deduped (vec (vals (into {} (map (fn [c] [(:q c) c]) all-qz))))]

    (println (format "  Flashcards: %d total → %d after dedup" (count all-fc) (count fc-deduped)))
    (println (format "  Quiz:       %d total → %d after dedup" (count all-qz) (count qz-deduped)))

    ;; Write merged files
    (let [fc-out (str FLASHCARD-DIR "/all-flashcards.json")
          qz-out (str FLASHCARD-DIR "/all-quiz.json")]
      (spit fc-out (json/generate-string fc-deduped {:pretty true}))
      (spit qz-out (json/generate-string qz-deduped {:pretty true}))
      (println)
      (println (format "  Saved: %s (%s)" fc-out
                       (format "%,d bytes" (fs/size fc-out))))
      (println (format "  Saved: %s (%s)" qz-out
                       (format "%,d bytes" (fs/size qz-out))))

      ;; Stats by repo org
      (let [by-org (group-by #(first (str/split (or (:repo %) "unknown") #"/")) fc-deduped)]
        (println)
        (println "  Coverage by org:")
        (doseq [[org cards] (sort-by (comp - count val) by-org)]
          (println (format "    %-30s %d cards" org (count cards))))))))
