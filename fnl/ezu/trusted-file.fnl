;; ABOUTME: Checks that a file can be trusted with the user's credentials: theirs,
;; ABOUTME: changeable by no one else, and, for secrets, readable by no one else.
(local util (require :ezu.util))

(fn command-output [command]
  (let [h (io.popen command)
        out (when h (h:read :*a))]
    (when h (h:close))
    (or out "")))

(var user-id nil)

(fn listing [path]
  "(mode owner target) of path as ls -ldn shows it, target for a link."
  (let [out (command-output (.. "ls -ldn " (util.shell-quote path)
                                " 2>/dev/null"))
        (mode owner) (out:match "^(%S+)%s+%S+%s+(%d+)")]
    (values mode owner (out:match " %-> (.-)%s*$"))))

(fn dirname [path]
  (or (path:match "^(.*)/[^/]*$") "."))

(fn real-file [path]
  "path with the links leading to it followed."
  (var current path)
  (for [_ 1 16 &until (not= "l" (: (or (listing current) "") :sub 1 1))]
    (let [(_ _ target) (listing current)]
      (set current (if (target:match "^/") target
                       (.. (dirname current) "/" target)))))
  current)

(var user-name nil)

(fn access-entries [path mode]
  "The entries of path's access list, as {:who principal :allow boolean
:rights {right true}}; [] when it has none; nil when it has one ls can't list.
ls marks an access list with + after the mode; on macOS, extended attributes
take that place (@) and hide it, so the entries ls -le lists tell. GNU ls has
no -e: there a + gives nil."
  (let [mark (mode:sub 11 11)
        out (if (or (= mark "+") (= mark "@"))
                (command-output (.. "ls -lde " (util.shell-quote path)
                                    " 2>/dev/null"))
                "")
        entries (icollect [line (out:gmatch "[^\n]+")]
                  (let [(who rest) (line:match "^%s*%d+:%s+(%S+)%s+(.*)$")]
                    (when who
                      {: who
                       :allow (not= nil (rest:match "^%S*%s*allow%s"))
                       :rights (collect [right (: (or (rest:match "(%S+)%s*$")
                                                      "")
                                                  :gmatch "[^,]+")]
                                 right
                                 true)})))]
    (when (or (not= mark "+") (next entries))
      entries)))

(fn others-allowed? [entries rights]
  "Whether an entry allows someone other than the user one of rights."
  (when (not user-name)
    (set user-name (: (command-output "id -un") :match "^(.-)%s*$")))
  (accumulate [found false _ e (ipairs entries) &until found]
    (and e.allow (not= e.who (.. "user:" user-name))
         (accumulate [any false _ right (ipairs rights) &until any]
           (= true (. e.rights right))))))

;; the rights that let one add, replace or remove what a directory holds
(local directory-change-rights [:add_file
                                :add_subdirectory
                                :delete_child
                                :write])

(fn fail [path what why]
  (error (.. what " " path ": " why) 0))

(fn others-can-change? [mode]
  "Whether a file or directory of mode can be changed by group or others:
for a directory, unless it is sticky (others can't replace what is yours)."
  (and (or (= (mode:sub 6 6) :w) (= (mode:sub 9 9) :w))
       (not (and (= (mode:sub 1 1) :d)
                 (or (= (mode:sub 10 10) :t) (= (mode:sub 10 10) :T))))))

(fn check [path what ?private]
  "Raise, naming what path is (plugin, secret file), unless path is a file of
the user's, in directories of the user's or root's, that no one else can
change, nor, when ?private, read. Links are followed."
  (when (not user-id)
    (set user-id (: (command-output "id -u") :match "%d+")))
  (let [file (real-file path)
        (mode owner) (listing file)]
    (when (not mode)
      (fail path what "not found"))
    (when (not= (mode:sub 1 1) "-")
      (fail path what "not a file"))
    (when (not= owner user-id)
      (fail path what "belongs to another user"))
    (when (and ?private (or (= (mode:sub 5 5) :r) (= (mode:sub 8 8) :r)))
      (fail path what (.. "can be read by other users (chmod go-r " file ")")))
    (when (others-can-change? mode)
      (fail path what (.. "can be changed by other users, who would get your credentials (chmod go-w "
                          file ")")))
    (let [entries (access-entries file mode)]
      (when (or (not entries) (accumulate [any false _ e (ipairs entries)
                                           &until any]
                                e.allow))
        (fail path what
              "has an access list, which may let other users change it: remove it")))
    ;; nor may anyone else replace it: no directory up to / is theirs to change
    (var dir (: (command-output (.. "cd " (util.shell-quote (dirname file))
                                    " 2>/dev/null && pwd -P"))
                :match "^(.-)%s*$"))
    (while (and dir (not= dir ""))
      (let [(dir-mode dir-owner) (listing dir)]
        (when (or (not dir-mode)
                  (not (or (= dir-owner user-id) (= dir-owner "0")))
                  (others-can-change? dir-mode))
          (fail path what
                (.. "is in " dir
                    ", which can be changed by other users, who would get your credentials")))
        (let [entries (access-entries dir dir-mode)]
          (when (or (not entries)
                    (others-allowed? entries directory-change-rights))
            (fail path what
                  (.. "is in " dir
                      ", whose access list may let other users change it, who would get your credentials"))))
        (set dir (if (= dir "/") nil
                     (let [parent (dirname dir)]
                       (if (= parent "") "/" parent))))))))

{: check}
