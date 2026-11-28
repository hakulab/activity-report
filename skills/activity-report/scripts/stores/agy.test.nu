#!/usr/bin/env nu

# ==================================================================================================
# Activity Report: Antigravity CLI Tests
# ==================================================================================================

use std/assert

use ../lib/fixtures.testlib.nu *

def prompt [clock: string, text: string]: nothing -> record {
  {
    step_index: 0
    source: "USER_EXPLICIT"
    type: "USER_INPUT"
    status: "DONE"
    created_at: (at $clock)
    content: $"<USER_REQUEST>($text)</USER_REQUEST><ADDITIONAL_METADATA>Context</ADDITIONAL_METADATA>"
  }
}

def "test agy links a delegate to its older parent and uses the recorded workspaces" [] {
  let dir = (mktemp --directory | path join "store #1?")
  let parent = "aaaaaaaa-1111-4111-8111-111111111111"
  let child = "bbbbbbbb-2222-4222-8222-222222222222"
  let seed = ($dir | path join "seed.db")
  let summaries = ($dir | path join "agy/conversation_summaries.db")
  let path = ["agy/brain" $parent ".system_generated/logs/transcript.jsonl"]
  transcript $dir $path [(prompt "2026-10-14T23:55" "Check the build")]
  with-env {TZ: "UTC"} {
    ^touch -t 202610142359 ($dir | path join ...$path)
  }
  transcript $dir ["agy/brain" $child ".system_generated/logs/transcript.jsonl"] [
    (prompt "00:05" "Inspect the tests")
    {
      step_index: 1
      source: "MODEL"
      type: "PLANNER_RESPONSE"
      status: "DONE"
      created_at: (at "00:20")
      content: "Tests passed"
    }
  ]
  [
    {
      conversation_id: $parent
      workspace_uris: '["file:///work/build%20tools", "file:///work/other"]'
      parent_conversation_id: ""
    }
    {
      conversation_id: $child
      workspace_uris: '["file:///work/tests"]'
      parent_conversation_id: $parent
    }
  ]
  | into sqlite --table-name "conversation_summaries" $seed
  let mode = (^sqlite3 -init /dev/null $seed "PRAGMA journal_mode = WAL")
  assert equal $mode "wal"
  cp $seed $summaries
  transcript $dir ["agy/history.jsonl"] [{conversationId: $parent, workspace: "/work/stale"}]

  let day = (digest-day $dir)

  assert equal ($day | select session cwd text hours agent) [
    {session: $parent, cwd: "/work/build tools", text: "Check the build", hours: 0, agent: 0.25}
  ]
  assert equal $day.0.sources [{tool: "agy", session: $child, cwd: "/work/tests", repo: null}]
  assert not ($"($summaries)-wal" | path exists)
  assert not ($"($summaries)-shm" | path exists)
}

def "test agy reports one turn from its full and compact logs in the history workspace" [] {
  let dir = (mktemp --directory)
  let app = (git-repo $dir "app")
  let cwd = ($app | path join "src")
  mkdir $cwd
  let id = "aaaaaaaa-1111-4111-8111-111111111111"
  let logs = ["agy/brain" $id ".system_generated/logs"]
  let request = (prompt "10:00" "Check </USER_REQUEST> handling")
  let reply = {
    step_index: 3
    source: "MODEL"
    type: "PLANNER_RESPONSE"
    status: "DONE"
    created_at: (at "10:55")
    content: "Parser checked"
  }
  transcript $dir [...$logs "transcript.jsonl"] [$request]
  transcript $dir [...$logs "transcript_full.jsonl"] [
    $request
    ($reply | merge {
      step_index: 1
      created_at: (at "10:05")
      content: "Reading the file"
      tool_calls: [{name: "view_file", args: {}}]
    })
    {
      step_index: 2
      source: "SYSTEM"
      type: "CHECKPOINT"
      status: "DONE"
      created_at: (at "10:15")
    }
    $reply
  ]
  transcript $dir ["agy/history.jsonl"] [{conversationId: $id, workspace: $cwd}]
  "\n{\"display\":" | save --raw --append ($dir | path join "agy/history.jsonl")
  mkdir ($dir | path join "agy/cache")
  {"/work/other": $id} | to json | save ($dir | path join "agy/cache/last_conversations.json")

  let output = (digest-output $dir)
  let day = ($output | day-entries)

  assert equal $output.repositories {app: $app}
  assert equal ($day | select tool session kind cwd repo text hours agent) [
    {
      tool: "agy"
      session: $id
      kind: "prompt"
      cwd: $cwd
      repo: "app"
      text: "Check </USER_REQUEST> handling"
      hours: 1
      agent: 0.25
    }
  ]
  assert equal $day.0.replies [{at: "2026-10-15T10:55:00+00:00", text: "Parser checked"}]
}

def "test agy falls back to unambiguous cached workspaces when summaries are unavailable" [] {
  let dir = (mktemp --directory)
  let cached = "bbbbbbbb-2222-4222-8222-222222222222"
  let ambiguous = "cccccccc-3333-4333-8333-333333333333"
  let unknown = "dddddddd-4444-4444-8444-444444444444"
  let remote = "eeeeeeee-5555-4555-8555-555555555555"
  for id in [$cached $ambiguous $unknown $remote] {
    transcript $dir ["agy/brain" $id ".system_generated/logs/transcript.jsonl"] [
      (prompt "11:00" "List the tasks")
    ]
  }
  let summaries = ($dir | path join "agy/conversation_summaries.db")
  {
    conversation_id: $remote
    workspace_uris: '["file:///work/stale"]'
    parent_conversation_id: ""
  }
  | into sqlite --table-name "conversation_summaries" $summaries
  let update = "UPDATE conversation_summaries SET workspace_uris = '[\"file://remote.example/work/app\"]'"
  (
    ^sqlite3 -init /dev/null $summaries
      "PRAGMA journal_mode = WAL"
      # cspell:ignore dbconfig ckpt
      ".dbconfig no_ckpt_on_close on"
      $update
    | ignore
  )

  mkdir ($dir | path join "agy/cache")
  {
    "/work/one": $cached
    "/work/two": $ambiguous
    "/work/three": $ambiguous
    "/work/four": $remote
  }
  | to json
  | save ($dir | path join "agy/cache/last_conversations.json")

  let day = (digest-day $dir)
  rm $"($summaries)-shm"
  let cached_day = (digest-day $dir | sort-by session)

  assert equal ($day | select session cwd text) [
    {session: $cached, cwd: "/work/one", text: "List the tasks"}
  ]
  assert equal ($cached_day | select session cwd) [
    {session: $cached, cwd: "/work/one"}
    {session: $remote, cwd: "/work/four"}
  ]
  assert not ($"($summaries)-shm" | path exists)
}
