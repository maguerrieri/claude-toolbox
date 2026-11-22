# examine.jq: one PR's issue timeline and state, turned into wake events.
#
# bin/pr-notifier runs it three times per examined PR, with --arg phase:
#   edits   prints the node ids (one per line) of comments edited after the
#           baseline, and of new items whose text may ride the wake, whose
#           last edit and editor the notifier then reads through GraphQL (the
#           REST timeline names an item's author, never its editor)
#   need    prints the logins (one per line) whose owner-check result the
#           filter needs (needs_owner): new items, and edits, by an actor that
#           is neither the sessions' own login nor any bot, and the authors
#           and editors that decide whose text rides the wake
#   result  prints {ps, events, log}: the PR's new cursor, the events to
#           queue (each with its details), and one record per filtered item
#           for the log
#
# Inputs:
#   $tl            --slurpfile: the timeline, as gh's --paginate --slurp pages
#   $pr            --slurpfile: the PR (GET /repos/{o}/{r}/pulls/{n})
#   $psf           --slurpfile: this PR's cursor from state.json ({} when new)
#   $me            --arg: the sessions' own login
#   $bots          --argjson: the configured review-bot logins
#   $baseline      --arg: the earliest subscribed_at of the PR's subscriptions
#   $now           --argjson: epoch seconds
#   $retry_window  --argjson: seconds a failed owner check is retried
#   $owner_text    --argjson: whether the owner's text may ride the wake
#   $text_store    --argjson: characters of an item's text kept for the wake
#   $editors       --argjson: {node id: {edited_at, login, type}}, login and
#                  type only when GraphQL names an editor (need, result)
#   $owners        --argjson: {lowercased login: owner-check exit code} (result)
#
# An event's details are raw values as GitHub gave them. lib/wake.jq checks
# each one when it renders the wake, so nothing here is trusted to be safe.
#
# The filter reads the timeline, never the notification: a notification
# carries no author and no event type (the #292 spike, Design corrections).

def lc: ascii_downcase;

# A Codex summary comment's review state, "<commit>:<status>", read from its
# codex-review-state line; null for any other comment. Codex's clean result
# edits this comment and adds a reaction, and neither is a new timeline item.
def codex_state:
  (.body // "") as $b
  | if ($b | startswith("<!-- codex-pull-request-review-summary -->")) then
      ((try ($b | capture("codex-review-state:v1 (?<j>.*?) -->").j | fromjson | .code_review
              | "\(.commit_sha // ""):\(.status // "")") catch null) // "")
    else null end;

# A line comment, normalized: who and when, its text, and where it sits.
def line_comment:
  {key: "review_comment:\(.id)", kind: "review", actor: (.user.login // ""),
   type: (.user.type // ""), url: (.html_url // ""), at: (.created_at // ""),
   id: (.id | tostring), node_id: (.node_id // ""),
   updated_at: (.updated_at // .created_at // ""), body: (.body // ""),
   path, line, original_line, start_line, original_start_line, side, subject_type,
   reply_to: .in_reply_to_id, review: .pull_request_review_id};

# The timeline items that can wake a session, normalized. A single line
# comment is a review too; a reply in a thread can surface as line-commented.
# A line comment whose review is itself on the timeline is that review's,
# so one review wakes one line however many comments it carries, and the
# review carries them (lines) for the wake's details.
def items:
  ($tl[0] // []) | (if type == "array" then flatten else [] end) as $all
  | ([ $all[] | select(type == "object" and .event == "reviewed") | .id | tostring ]
     | map({(.): true}) | add // {}) as $reviews
  | ([ $all[] | select(type == "object" and .event == "line-commented")
       | (.comments // [])[] | select(type == "object") | line_comment ]
     | group_by(.review | tostring)
     | map({key: (.[0].review | tostring), value: sort_by(.at, (.id | tonumber? // 0))}) | from_entries) as $lines
  | ($bots | map(lc)) as $bots_lc
  | [ $all[] | select(type == "object") as $e
    | if $e.event == "commented" then
        {key: "comment:\($e.id)", kind: "comment", actor: ($e.user.login // ""),
         type: ($e.user.type // ""), url: ($e.html_url // ""), at: ($e.created_at // ""),
         id: ($e.id | tostring), node_id: ($e.node_id // ""),
         updated_at: ($e.updated_at // $e.created_at // ""), body: ($e.body // ""),
         # Only a configured bot's comment can be a Codex summary: anyone can
         # post one's text, so a stranger's copy is an ordinary comment.
         codex: (if ($e.user.type // "") == "Bot" and ($bots_lc | index(($e.user.login // "") | lc)) != null
                 then ($e | codex_state) else null end)}
      elif $e.event == "reviewed" and (($e.state // "") | lc) != "pending" then
        {key: "review:\($e.id)", kind: "review", actor: ($e.user.login // ""),
         type: ($e.user.type // ""), url: ($e.html_url // ""), at: ($e.submitted_at // ""),
         node_id: ($e.node_id // ""), updated_at: ($e.updated_at // $e.submitted_at // ""),
         body: ($e.body // ""), state: (($e.state // "") | lc), commit: $e.commit_id,
         lines: ($lines[$e.id | tostring] // [])}
      elif $e.event == "line-commented" then
        ($e.comments // [])[] | select(type == "object") | line_comment
        | select($reviews[(.review // "") | tostring] | not)
      else empty end ];

# A configured bot must also be typed Bot by GitHub, so a user account that
# takes a bot's display login (e.g. "Copilot") is checked like anyone else.
# Any other Bot, or a login owner-check would refuse on its format alone,
# settles at once rather than being rechecked for the retry window.
def class($i):
  ($i.actor | lc) as $a
  | if $a == "" then "unknown"
    elif $a == ($me | lc) then "own"
    elif $i.type == "Bot" and (($bots | map(lc) | index($a)) != null) then "bot"
    elif $i.type == "Bot" or ($a | test("^[a-z0-9][a-z0-9-]{0,38}$") | not) then "other-bot"
    else "check" end;

def record($i; $verdict; $reason):
  {key: $i.key, actor: ($i.actor // ""), verdict: $verdict, reason: $reason};

($psf[0] // {}) as $ps
| ($ps.seen // []) as $seen
| ($seen | map({(.): true}) | add // {}) as $seenset
| items as $items
| [ $items[] | select($seenset[.key] | not) ] as $new
| ($ps.comments // {}) as $tracked
| ($editors // {}) as $editors
# A comment's updated_at as last recorded. One with no entry was last seen
# unedited, so its creation time stands in.
| def prev_updated($i): (($tracked[$i.id] // {}).updated_at) // $i.at;
# A comment edited after the baseline (Codex's summary has its own rule),
# whether or not its creation is decided yet: a stranger's comment still being
# rechecked can carry the owner's edit. The edit is its editor's, whoever
# wrote the comment, and is decided apart from the comment: its own owner
# check, the same cached one, and its own recheck window. No comment pins
# anyone's ownership. (The result phase skips an edit the first pass already
# covered, by the updated_at it just recorded.)
  def edited($i):
    $i.kind == "comment" and $i.codex == null
    and $i.updated_at >= $baseline and $i.updated_at != prev_updated($i);
# The edit as an item of its editor's, or null while the editor is unread.
  def edit($i): ($editors[$i.node_id] // {}) as $ed
    | if ($ed.login // "") == "" then null else $i + {actor: $ed.login, type: ($ed.type // "")} end;
# The one rule for who needs an owner check, shared by the need and result
# phases: an item the filter decides, by a login that is neither the
# sessions' own nor a bot's.
  def needs_owner($i): class($i) == "check";
# An item whose REST times differ, for the wake's updated token only: whose
# text rides is GraphQL's call (owner_text).
  def looks_edited($i): ($i.updated_at // "") != "" and $i.updated_at != $i.at;
# New items whose text may ride the wake: a check-class author's, and the
# line comments of such a review.
  def text_candidates:
    if $owner_text then $new[] | select(.at >= $baseline and needs_owner(.)) | (., (.lines // [])[])
    else empty end;
# The owner check accepted this login (exit 0) on this read.
  def owner_ok($i): needs_owner($i) and $owners[$i.actor | lc] == 0;
# {text, text_cut} for an item whose author the owner check accepted, and
# whose last editor it accepted too when GraphQL shows an edit; {} for any
# other item. GraphQL decides whether it was edited, never REST's times, so
# an item it didn't return (a failed read, no node id) gets no text, and so
# does one GraphQL shows edited after the REST read that gave its text.
  def owner_text($i):
    if ($owner_text | not) or (owner_ok($i) | not) then {}
    else ($i.body // "" | if type == "string" then . else "" end) as $b
      | ($editors[$i.node_id // ""] // null) as $ed
      | (if $ed == null then false
         elif $ed.edited_at == null then true
         elif ($ed.login // "") == "" then false
         elif ($ed.edited_at | tostring) > ($i.updated_at // "") then false
         else owner_ok({actor: $ed.login, type: ($ed.type // "")}) end) as $ok
      | if $ok then {text: $b[0:$text_store], text_cut: (($b | length) > $text_store)} else {} end
    end;
# Who and when, as the wake shows it: the item's creation, and its last
# update when that differs.
  def stamp($i): {by: $i.actor, type: $i.type, at: $i.at}
    + (if looks_edited($i) then {updated: $i.updated_at} else {} end);
# Where a line comment sits. An outdated one keeps its original line.
  def place($c):
    ($c.line // $c.original_line) as $l
    | {path: $c.path, line: $l,
       start_line: (($c.start_line // $c.original_start_line) as $s | if $s == $l then null else $s end),
       side: $c.side, subject: $c.subject_type,
       outdated: ($c.subject_type != "file" and $c.line == null and $c.original_line != null),
       reply_to: $c.reply_to}
    | with_entries(select(.value != null and .value != false));
# The details an event carries into the wake. A review lists at most 20 of
# its line comments, and counts them all.
  def details($i):
    if $i.kind == "comment" then stamp($i) + owner_text($i)
    elif ($i.key | startswith("review:")) then
      stamp($i) + {state: $i.state, commit: $i.commit, comments_total: ($i.lines | length),
                   comments: [$i.lines[:20][] | {url} + place(.) + stamp(.) + owner_text(.)]}
      + owner_text($i)
    else stamp($i) + place($i) + {review: $i.review} + owner_text($i) end
    | with_entries(select(.value != null));
# A completed Codex summary: the bot, and the commit its state line names.
  def codex_details($i):
    stamp($i) + {commit: (($i.codex | split(":")[0]) as $c | if $c == "" then null else $c end)}
    | with_entries(select(.value != null));
  def verdict($i):
    class($i) as $c
    | if $c == "own" then {keep: false, reason: "own login", settle: true}
      elif $c == "unknown" then {keep: false, reason: "no actor", settle: true}
      elif $c == "other-bot" then {keep: false, reason: "a bot or app not configured", settle: true}
      elif $c == "bot" then {keep: true, reason: "review bot"}
      elif needs_owner($i) then
        ($owners[$i.actor | lc]) as $o
        | if $o == 0 then {keep: true, reason: "owner"}
          elif $o == 3 then {keep: false, reason: "same-account login (owner-check 3)", settle: true}
          else {keep: false, reason: "not the owner (owner-check \($o // "not run"))", settle: false} end
      else {keep: false, reason: "unclassified", settle: true} end;
# A failed or negative owner check on an edit: the recorded updated_at stays
# put, so the edit is seen again, until the window for this very edit ends.
  def retry_edit($i; $why):
    ($tracked[$i.id] // {}) as $old
    | if $old.edit_retry == null or $old.edit_retry_for != $i.updated_at then
        .comments[$i.id] = {updated_at: prev_updated($i), edit_retry: $now, edit_retry_for: $i.updated_at}
        | .log += [record($i; "drop"; "\($why); rechecked for \($retry_window)s")]
      elif $now - $old.edit_retry >= $retry_window then
        .comments[$i.id] = {updated_at: $i.updated_at}
        | .log += [record($i; "drop"; "\($why); settled")]
      else . end;
  if $phase == "edits" then
    [ ($items[] | select(edited(.)) | .node_id),
      (text_candidates | .node_id) ]
    | map(select(type == "string" and . != "")) | unique | .[]
  elif $phase == "need" then
    [ ($new[] | select(.at >= $baseline) | select(needs_owner(.)) | .actor),
      ($items[] | select(edited(.)) | edit(.) // empty | select(needs_owner(.)) | .actor),
      # Whose text rides the wake: an edited comment's author, and the
      # editor GraphQL names for a new item.
      (if $owner_text then $items[] | select(edited(.)) | select(needs_owner(.)) | .actor else empty end),
      (text_candidates | edit(.) // empty | select(needs_owner(.)) | .actor) ]
    | unique_by(lc) | .[]
  else
    ($pr[0] // {}) as $p
    | reduce $new[] as $i (
        {seen: [], retry: ($ps.retry // {}), comments: $tracked, events: [], log: []};
        if $i.at < $baseline then
          # Before every subscription: never an event. A bot's comment is still
          # tracked, so a later edit of Codex's summary is caught.
          .seen += [$i.key]
          | if $i.kind == "comment" and class($i) == "bot" and $i.codex != null then
              .comments[$i.id] = {updated_at: $i.updated_at, codex: $i.codex}
              | if ($i.codex | endswith(":completed")) and $i.updated_at >= $baseline then
                  .events += [{key: "codex:\($i.id):\($i.codex)", kind: "review", url: $i.url, at: $i.updated_at,
                               details: codex_details($i)}]
                  | .log += [record($i; "keep"; "review bot (Codex summary completed)")]
                else . end
            else . end
        else
          verdict($i) as $v
          | if $v.keep then
              .seen += [$i.key]
              | .retry |= del(.[$i.key])
              | .events += [{key: $i.key, kind: $i.kind, url: $i.url, at: $i.at, details: details($i)}]
              | .log += [record($i; "keep"; $v.reason)]
              | if $i.kind == "comment" then
                  .comments[$i.id] = {updated_at: $i.updated_at, codex: $i.codex}
                else . end
            elif $v.settle then
              .seen += [$i.key] | .log += [record($i; "drop"; $v.reason)]
            else
              # owner-check's exit 1 can't tell a stranger from a failed read,
              # so the item is checked again until the retry window ends.
              (.retry[$i.key]) as $first
              | if $first == null then
                  .retry[$i.key] = $now
                  | .log += [record($i; "drop"; "\($v.reason); rechecked for \($retry_window)s")]
                elif $now - $first >= $retry_window then
                  .seen += [$i.key] | .retry |= del(.[$i.key])
                  | .log += [record($i; "drop"; "\($v.reason); settled")]
                else . end
            end
        end)
    # Edits, including of comments posted before the subscription or still
    # being rechecked: Codex's summary reaching a new completed state, or an
    # edit by the owner, whoever wrote the comment. A comment's entry records
    # only its updated_at (and Codex's state), never who owns it.
    | reduce ($items[] | select(.kind == "comment")) as $i (.;
        (.comments[$i.id]) as $c
        | if $i.codex != null then
            if $c != null and $i.codex != $c.codex then
              .comments[$i.id] += {codex: $i.codex, updated_at: $i.updated_at}
              | if ($i.codex | endswith(":completed")) then
                  .events += [{key: "codex:\($i.id):\($i.codex)", kind: "review", url: $i.url, at: $i.updated_at,
                               details: codex_details($i)}]
                  | .log += [record($i; "keep"; "review bot (Codex summary completed)")]
                else . end
            else . end
          # The first pass just kept this comment as it now reads: its event
          # covers the edit.
          elif (edited($i) | not) or $i.updated_at == ($c // {}).updated_at then .
          else
            edit($i) as $e
            | if $e == null then retry_edit($i; "edit, editor unread")
              else
                verdict($e) as $v
                | if $v.keep and $v.reason == "owner" then
                    .comments[$i.id] = {updated_at: $i.updated_at}
                    # by is the editor; the text, the comment's as it now
                    # reads, only when its author passes the check too.
                    | .events += [{key: "edit:\($i.id):\($i.updated_at)", kind: "edited", url: $i.url, at: $i.updated_at,
                                   details: (stamp($e) + owner_text($i))}]
                    | .log += [record($e; "keep"; "owner (edited)")]
                  elif $v.keep or $v.settle then
                    # A bot's edit, or one by the sessions' own login: nothing
                    # to wake for (Codex's summary has its own rule above).
                    .comments[$i.id] = {updated_at: $i.updated_at}
                    | .log += [record($e; "drop"; "edit: \(if $v.keep then "by a bot" else $v.reason end)")]
                  else retry_edit($e; "edit, \($v.reason)") end
              end
          end)
    # The PR's own state: a merge or a close wakes whoever did it.
    | (if $p.merged == true then {key: "state:merged:\($p.merged_at)", kind: "merged", at: ($p.merged_at // ""),
                                  details: {by: $p.merged_by.login?, type: $p.merged_by.type?, at: $p.merged_at}}
       elif $p.state == "closed" then {key: "state:closed:\($p.closed_at)", kind: "closed", at: ($p.closed_at // ""),
                                       details: {at: $p.closed_at}}
       else null end) as $s
    | if $s != null and ($seenset[$s.key] | not) then
        .seen += [$s.key]
        | if $s.at >= $baseline then
            .events += [$s + {url: ($p.html_url // ""), details: ($s.details | with_entries(select(.value != null)))}]
            | .log += [{key: $s.key, actor: "", verdict: "keep", reason: "PR \($s.kind)"}]
          else . end
      else . end
    | {ps: ($ps + {seen: (($seen + .seen) | unique), retry: .retry, comments: .comments,
                   pr_state: (if $p.merged == true then "merged" else ($p.state // "open") end),
                   closed_at: ($s.at // null),
                   # The PR's head and base as this read found them, for the
                   # wake's PR line (lib/wake.jq checks both).
                   head: $p.head.sha?, base: $p.base.ref?}),
       events: .events, log: .log}
  end
