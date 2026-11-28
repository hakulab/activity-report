# ==================================================================================================
# Activity Report: Antigravity CLI
# ==================================================================================================
# Maps Antigravity CLI transcript steps to events.
# ==================================================================================================

use ../transcripts.nu [glob-under load-sessions project-session read-transcript valid-id]

def workspace-path [value: any]: nothing -> bool {
  ($value | describe --detailed | get type) == "string" and ($value =~ '^/[^\x00]*$')
}

def summaries [base: string]: nothing -> record {
  let file = ($base | path join "conversation_summaries.db")
  if ($file | path type) != "file" { return {} }

  let wal = $"($file)-wal"
  let has_wal = ($wal | path exists)
  let has_shm = ($"($file)-shm" | path exists)
  if $has_wal and not $has_shm and (ls $wal | get 0.size) > 0b {
    print --stderr "Skipped Antigravity conversation summaries with a WAL and no shared-memory file"
    return {}
  }

  # Immutable mode avoids creating WAL sidecars when the store has no live pair.
  let database = if $has_wal and $has_shm {
    $file
  } else {
    $"file:($file | url encode --all)?immutable=1"
  }
  let query = "SELECT conversation_id, workspace_uris, parent_conversation_id FROM conversation_summaries"
  let run = (
    ^sqlite3
      -init /dev/null
      -readonly
      -safe
      -json
      $database $query
    | complete
  )
  if $run.exit_code != 0 or ($run.stdout | is-empty) { return {} }

  $run.stdout
  | from json
  | where {|row| valid-id $row.conversation_id }
  | each {|row|
    let id = $row.conversation_id
    let parent = $row.parent_conversation_id
    let uris = (try { $row.workspace_uris | from json })
    let urls = if ($uris | describe --detailed | get type) == "list" {
      $uris | each {|uri| try { $uri | url parse } }
    } else {
      []
    }
    let cwd = (
      $urls
      | where {|u| $u.scheme == "file" and ($u.host | str lowercase) in ["" "localhost"] }
      | each {|u| try { $u.path | url decode } }
      | where {|path| (workspace-path $path) and $path !~ '^/[A-Za-z]:($|/)' }
      | first
    )

    [$id {
      cwd: $cwd
      has_workspaces: ($urls | is-not-empty)
      parent: (if (valid-id $parent) and $id != $parent { $parent })
    }]
  }
  | into record
}

def history-workspaces [base: string]: nothing -> record {
  let file = ($base | path join "history.jsonl")
  if ($file | path type) != "file" { return {} }

  read-transcript $file --skip-invalid
  | where {|row| (valid-id $row.conversationId?) and (workspace-path $row.workspace?) }
  | reverse
  | uniq-by conversationId
  | each {|row| [$row.conversationId $row.workspace] }
  | into record
}

# The resume cache keeps one conversation per workspace. Only a unique reverse lookup is useful.
def cached-workspaces [base: string]: nothing -> record {
  let file = ($base | path join "cache/last_conversations.json")
  let cache = (try { open --raw $file | from json })
  if ($cache | describe --detailed | get type) != "record" { return {} }

  $cache
  | transpose workspace id
  | where {|row| (workspace-path $row.workspace) and (valid-id $row.id) }
  | group-by id
  | items {|id, rows| if ($rows | length) == 1 { [$id $rows.0.workspace] } }
  | into record
}

def conversation-workspace [
  metadata: record
  workspaces: record
  id: string
  seen: list = []
]: nothing -> any {
  let summary = ($metadata | get -o $id)
  let cwd = $summary.cwd?
  let parent = $summary.parent?

  if $cwd != null or $summary.has_workspaces? == true {
    $cwd
  } else {
    let fallback = ($workspaces | get -o $id)
    if $fallback != null {
      $fallback
    } else if $parent != null and $id not-in $seen {
      conversation-workspace $metadata $workspaces $parent ($seen | append $id)
    }
  }
}

def prompt-text []: string -> string {
  let text = $in
  let request = (
    $text
    | parse --regex '(?s)^\s*<USER_REQUEST>(?<request>.*)</USER_REQUEST>\s*(?:<(?:ADDITIONAL_METADATA|USER_SETTINGS_CHANGE)>.*)?$'
  )
  $request | get -o 0.request | default $text | str trim
}

def step-events [step: record]: nothing -> list {
  let content = $step.content?
  let text = if ($content | describe --detailed | get type) == "string" { $content } else { "" }
  let ts = $step.ts
  let source = $step.source?

  if $step.type? == "USER_INPUT" and $source in ["USER_EXPLICIT" "USER_IMPLICIT" "SYSTEM_SDK"] {
    let kind = if $source == "USER_EXPLICIT" { "prompt" } else { "trigger" }
    [{kind: $kind, ts: $ts, text: ($text | prompt-text)}]
  } else if $source == "MODEL" {
    let signal = if $step.type? == "PLANNER_RESPONSE" {
      if $step.status? == "CANCELED" {
        {kind: "abort", ts: $ts}
      } else if (
        $step.status? == "DONE"
        and ($step.tool_calls? | is-empty)
        and ($text | str trim | is-not-empty)
      ) {
        {kind: "reply", ts: $ts, text: $text}
      }
    }
    [{kind: "model", ts: $ts} $signal] | compact
  } else {
    []
  }
}

def read-session [cfg: record, file: string, session: record]: nothing -> record {
  let steps = (
    read-transcript $file --skip-invalid
    | each {|step|
      let ts = (try { $step.created_at? | into datetime --format "%+" })
      if $ts != null { $step | upsert ts $ts }
    }
  )
  let session = ($session | insert events ($steps | each {|step| step-events $step } | flatten))
  project-session $cfg "agy" $file $session ($steps | get -o ts)
}

export def sessions [cfg: record, since: datetime]: nothing -> list {
  let base = $cfg.assistants.agy
  let globs = [
    "brain/*/.system_generated/logs/transcript.jsonl"
    "brain/*/.system_generated/logs/transcript_full.jsonl"
  ]
  let files = (
    glob-under $base ...$globs
    | each {|file|
      let id = ($file | path relative-to $base | path split | get 1)
      let info = (ls $file | first)
      if (valid-id $id) {
        {
          id: $id
          file: $file
          modified: $info.modified
          recent: ($info.modified >= $since)
          size: $info.size
        }
      }
    }
    | sort-by --reverse recent size file
    | uniq-by id
  )
  if not ($files | any {|file| $file.recent }) { return [] }

  let metadata = (summaries $base)
  let workspaces = ((cached-workspaces $base) | merge (history-workspaces $base))
  let by_id = ($files | each {|entry| [$entry.id $entry.file] } | into record)
  load-sessions $files $since {|file|
    let id = ($file | path relative-to $base | path split | get 1)
    let cwd = (conversation-workspace $metadata $workspaces $id)
    let parent_id = ($metadata | get -o $id | get -o parent)
    let parent = if $parent_id != null { $by_id | get -o $parent_id }

    if $cwd != null {
      read-session $cfg $file {
        id: $id
        cwd: $cwd
        attended: ($parent_id == null)
        parent: $parent
      }
    }
  }
}
