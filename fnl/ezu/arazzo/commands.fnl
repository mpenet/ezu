;; ABOUTME: The command words of Arazzo documents (x-ezu-command on workflows and
;; ABOUTME: on Arazzo sources, which mount them): resolving and listing them.
(local util (require :ezu.util))

(fn words-of [command]
  "The words of an x-ezu-command, or nil when it isn't words."
  (when (= (type command) :string)
    (let [words (icollect [w (command:gmatch "%S+")] w)]
      (when (and (next words)
                 (accumulate [ok true _ w (ipairs words) &until (not ok)]
                   (not= nil (w:match "^[%w][%w_.-]*$"))))
        words))))

(fn mounts [doc]
  "The Arazzo sources doc mounts: [{:words :source}]."
  (icollect [_ src (ipairs (or doc.sourceDescriptions []))]
    (let [words (when (= src.type :arazzo) (words-of (. src :x-ezu-command)))]
      (when words {: words :source src}))))

(fn commands? [doc]
  "Whether doc gives its workflows or sources command words."
  (or (accumulate [found false _ wf (ipairs (or doc.workflows [])) &until found]
        (not= nil (words-of (. wf :x-ezu-command))))
      (not= nil (next (mounts doc)))))

(fn tree [doc]
  "doc's command tree: nodes {:doc :root :children {word node} :workflow
:mount}, a mount being an Arazzo source to load when reached."
  (let [root {: doc :root true :children {}}
        insert (fn [words leaf]
                 (var node root)
                 (each [_ w (ipairs words)]
                   (when (not (. node.children w))
                     (tset node.children w {: doc :children {}}))
                   (set node (. node.children w)))
                 (when (not (or node.workflow node.mount))
                   (each [k v (pairs leaf)]
                     (tset node k v))))]
    (each [_ wf (ipairs (or doc.workflows []))]
      (match (words-of (. wf :x-ezu-command))
        words (insert words {:workflow wf})))
    (each [_ m (ipairs (mounts doc))]
      (insert m.words {:mount m.source}))
    root))

(fn enter [node load]
  "node, or the root of the document it mounts, loaded with load."
  (if node.mount (tree (load node.doc node.mount)) node))

(fn resolve [doc words load ?values-from]
  "What words name in doc, loading mounted documents with (load doc source):
{:kind :workflow :doc :workflow :rest :path} for a workflow, the words after
it its arguments; {:kind :group :node :path} when the words end at a group;
{:kind :unknown :word :suggestion :node :path} for a word that names nothing.
At a document's top, a workflow's id names it too: helpers without words, and
documents without commands. Words from index ?values-from on (those given
after --) are a workflow's values, never command words."
  (var node (tree doc))
  (var result nil)
  (var i 1)
  (while (not result)
    (set node (enter node load))
    (let [word (. words i)
          value? (and ?values-from (>= i ?values-from))
          child (when (and word (not value?)) (. node.children word))
          path (icollect [j w (ipairs words)] (when (< j i) w))
          rest #(icollect [j w (ipairs words)] (when (>= j $) w))
          by-id (when (and word node.root (not child) (not value?))
                  (accumulate [found nil _ wf (ipairs (or node.doc.workflows []))
                               &until found]
                    (when (= wf.workflowId word) wf)))]
      (if (and node.workflow (not child))
          (set result {:kind :workflow
                       :doc node.doc
                       :workflow node.workflow
                       :rest (rest i)
                       : path})
          by-id
          (set result
               {:kind :workflow
                :doc node.doc
                :workflow by-id
                :rest (rest (+ i 1))
                :path (doto path (table.insert word))})
          (= nil word)
          (set result {:kind :group : node : path})
          (not child)
          (set result {:kind :unknown
                       : word
                       :suggestion (util.closest word
                                                 (doto (icollect [w (pairs node.children)]
                                                         w)
                                                   ;; ids run workflows at a
                                                   ;; document's top too
                                                   (#(when node.root
                                                       (each [_ wf (ipairs (or node.doc.workflows
                                                                               []))]
                                                         (when (= (type wf.workflowId)
                                                                  :string)
                                                           (table.insert $
                                                                         wf.workflowId)))))))
                       : node
                       : path})
          (do
            (set node child)
            (set i (+ i 1))))))
  result)

(fn summary-of [node load]
  "What a listing says of node: its workflow's summary, its mounted document's
summary or title, or a group's words."
  (if node.workflow node.workflow.summary node.mount
      (let [(ok doc) (pcall load node.doc node.mount)]
        (when ok
          (or (?. doc :info :summary) (?. doc :info :title))))
      (let [words (icollect [w (pairs node.children)] w)]
        (table.sort words)
        (table.concat words ", "))))

(fn entries [node load]
  "The commands under node: [{:word :summary}], sorted; a document without
commands lists its workflows, by id, in its order."
  (if (and node.root (not (commands? node.doc)))
      (icollect [_ wf (ipairs (or node.doc.workflows []))]
        {:word (tostring (or wf.workflowId "(no workflowId)"))
         :summary wf.summary})
      (let [words (icollect [w (pairs node.children)] w)]
        (table.sort words)
        (icollect [_ w (ipairs words)]
          {:word w :summary (summary-of (. node.children w) load)}))))

(fn problems [doc]
  "What is wrong with doc's command words: [{:where :message}], by where."
  (let [found []
        leaves []
        report #(table.insert found {:where $1 :message $2})]
    (each [_ wf (ipairs (or doc.workflows []))]
      (let [command (. wf :x-ezu-command)
            words (words-of command)
            where (tostring wf.workflowId)]
        (if words (table.insert leaves {: where : words :name where})
            (not= nil command)
            (report where
                    "x-ezu-command must be words, like \"instance create\""))))
    (each [_ src (ipairs (or doc.sourceDescriptions []))]
      (let [command (. src :x-ezu-command)
            where (.. "source " (tostring src.name))]
        (when (not= nil command)
          (if (not= src.type :arazzo)
              (report where
                      (.. "x-ezu-command mounts an Arazzo document, and "
                          (tostring src.name) " isn't one"))
              (match (words-of command)
                words (table.insert leaves {: where : words})
                _ (report where "x-ezu-command must be words, like \"compute\""))))))
    (let [text #(table.concat $ " ")
          prefix? (fn [short long]
                    (and (< (length short) (length long))
                         (accumulate [ok true i w (ipairs short) &until (not ok)]
                           (= w (. long i)))))
          first-of {}]
      (each [_ leaf (ipairs leaves)]
        (let [key (text leaf.words)
              earlier (. first-of key)
              longer (accumulate [found nil _ other (ipairs leaves) &until found]
                       (when (prefix? leaf.words other.words) other))]
          (if earlier
              (report leaf.where
                      (.. "x-ezu-command '" key "' is also "
                          (if earlier.name (.. "workflow " earlier.name "'s")
                              earlier.where)))
              longer
              (report leaf.where
                      (.. "x-ezu-command '" key
                          "' is also a group of commands (" (text longer.words)
                          ")")))
          (when (not earlier)
            (tset first-of key leaf)))))
    (table.sort found #(if (= $1.where $2.where) (< $1.message $2.message)
                           (< $1.where $2.where)))
    found))

{: resolve : entries : commands? : problems}
