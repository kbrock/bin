# statusline TODO

- ctx shows 0 (empty bar) with `⛁ EXPIRED` in a resumed session. Confirmed: Claude Code sends `total_input_tokens` 0, `used_percentage` 0 and an all-zero `current_usage` until the next request (payload kept in `/tmp/statusline_zero.json`). Not our bug. Option: fall back to the last usage in the transcript.
- Medium layout (82-173 columns) hides the ctx size. With an expired cache, show the size or `prompt_cache.recache_tokens_if_cold`.
- Git segment follows `workspace.current_dir`, which does not follow a `cd` or worktree switch. Needs a payload from a worktree session.
- `color_limits` has no callers.
- `▼` (`PURPLE`) is still a fixed color, not in `THEME`.
- The dump in `statusline.rb` writes `/tmp/statusline.json` from every session, so they overwrite each other. Uncommitted, dev only.
