# Design

`activity-report digest` normalizes assistant transcripts into turns, links delegated work into units, and estimates daily human and agent time. The [output reference](../../skills/activity-report/references/output.md) owns the field definitions, time formulas, and evidence-selection rules.

## Reading stores

The digest reads transcripts and session metadata without changing their contents. Its TOML inputs are documented under [Configuration](../../README.md#configuration).

A transcript is JSON lines, optionally compressed. A live session may leave a partial last line, so the reader retries parsing without it. NUL-only records are skipped with a warning.

The reader starts with transcripts modified since the first requested local midnight, then loads their parent sessions recursively, including older parents. Plain and compressed copies count once. Filter dates after linking sessions so recent delegates retain their original prompts.

Antigravity CLI keeps plaintext steps in `brain/<conversation-id>/.system_generated/logs/`. The reader chooses one of `transcript.jsonl` and `transcript_full.jsonl`, preferring a copy modified within the scan window, then the larger file. It reads timestamped steps and skips malformed records.

Antigravity's `conversation_summaries.db` maps each conversation ID to its workspace URIs and, for delegates, its parent conversation ID. The first local file URI supplies the working directory. If the summary lists no workspace, the reader checks the latest matching entry in `history.jsonl`, then `cache/last_conversations.json` if exactly one workspace names the conversation there. A delegate with no mapping of its own can inherit its parent's workspace. The digest skips sessions it cannot place in a local workspace.

SQLite uses its normal read locks when the summary database has both a write-ahead log (`-wal`) and a shared-memory index (`-shm`). With no pending log data, the digest can read the database directly. If a nonempty log is missing its index, the digest warns and falls back to the JSON workspace mappings.

## Linking turns

Adapters distinguish human prompts, automatic triggers, replies, cancellations, and other model output. The common reader inserts pauses for idle gaps. Canceled turns cannot borrow a later reply, and local commands with no model output do not create agent work.

A delegate's turn joins the parent turn running at its start and follows that turn's owning prompt. Turns without an attended prompt form a run. Attended prompts share one timeline across sessions so the next prompt cuts human credit even when it comes from another session.

Timing uses the first reply, while evidence keeps the last reply within each prompt or trigger interval. Steering prompts can share a time boundary, but only the latest prompt owns the reply text. Parallel delegates each add their own agent time.

## Repository attribution

Resolve session directories to their main checkout. Preserve resolution of deleted sibling worktrees under `<name>__worktrees` before falling back to the nearest existing ancestor, so historical work keeps its repository after cleanup.

The skill attributes tasks to projects from conversation and supporting evidence. Unit sources retain other contributing sessions' directories, while code owns the daily estimates and their boundaries.
