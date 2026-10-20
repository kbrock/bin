#!/usr/bin/env ruby
require 'json'
require 'date'

# Bar charts available (reference). Samples at ~60%.
#
# Binary: every cell is full or empty.
#   circles       ●●●○○      big circles   ⬤⬤⬤◯◯      pills         ▮▮▮▯▯
#   parallelogram ▰▰▰▱▱      squares       ■■■□□      rects         ◼◼◼▭▭
#   arrows        ►►►▷▷      bars          ≡≡≡−−      shades        ▓▓▓░░
#   solid+shade   ███░░      braille       ⣿⣿⣿⣀⣀      low line      ███▁▁
#   emoji (2 wide, fixed color)  ⬛⬛⬛⬜⬜  ⚫⚫⚫⚪⚪
#
# Graded: one cell can be partly full, so N cells give more than N steps.
#   eighth blocks ███▍ (▏▎▍▌▋▊▉█, 8 steps/cell)    braille dots (8 per cell, 4 tall)
#   partial glyph ⬤⬤⬤◔○  ■■■◱□                     levels ▃▅▆█▇ (a sparkline, not a fill)
#
# Background track: fill in the foreground color over a gray background
# (\e[48;5;238m) so the empty part shows where 100% ends. Works with any glyph,
# best with eighth blocks and braille.
#
# Seen in the wild: solid colored fill, dithered dark track, percent in the
# fill's color; green, then yellow, then red as it fills.

# Statusline — where am I, what is this costing, and when does the cache go cold?
#
# One line: a left group and a right group, the right one pushed to the edge
# using COLUMNS (minus RIGHT_MARGIN, which keeps clear of notifications).
# Wide layout when it fits; then narrow; then narrow without $cost and model
# (no context bar, limits as %, branch hidden on main/master and in worktrees).
#
#   ✔ [main] repo #22   one state symbol, [branch], repo (bold blue), PR number
#                       (links to the PR). Branch is turquoise. The symbol is the
#                       first that applies: ✖ red detached, ✚ yellow local changes,
#                       ⚑ yellow stash, ↑ cyan unpushed or no upstream, ↓ cyan
#                       behind, ✔ green in sync (ahead/behind as of the last fetch).
#   ▣ ▰▰▱▱ 120.0k      context size. Green/blue/yellow/red = model-degradation
#                       zones (model_zones); bold red = 85% of the context window.
#                       The bar (wide) is scaled to
#                       the model's degraded size: Sonnet 10 slots of 40k, Opus 12
#                       of 50k, plus RED_SLOTS past degraded. Each slot has its band's
#                       color: solid once reached, hollow while ahead. The size takes
#                       the color of the highest band reached.
#   ⛁ 10:06pm          prompt-cache expiry: green = warm, red EXPIRED (next send
#                       misses). Absent when Claude Code reports no expiry.
#   ▲up ▼down ⚒count   tokens for this whole turn: your prompt plus every tool
#                       round-trip (summed from the transcript). ▲ = new input
#                       (uncached + cache writes), ▼ = output. Falls back to the
#                       last API request when the transcript can't be read.
#                       ▲ blue/red = the turn's first send hit/missed the cache
#                       (tool round-trips are seconds apart, so they're always warm).
#                       ⚒ = tool calls this turn. Off when SHOW_TURN is false.
#   $cost               session API cost (not real billing on subscription)
#   ◷ 3h ▰▰▱▱▱         5h and 7d subscription limits; the label IS the reset
#                       countdown. Bar (wide) = 5 slots of 20%, or the % (narrow).
#                       Color is pace: teal too low, green on pace, purple too
#                       high, red at WALL (90%) or more.
#                       5h pace is linear across the window (teal 10+ behind,
#                       purple 10+ ahead). 7d pace is 10% per weekday half-day
#                       (10am-3pm, 3pm-8pm) so far (teal 20+ behind, purple 10+
#                       ahead). Either hitting 100% collapses both to
#                       "API <clock>": you're on pay-as-you-go until then (7d
#                       wins if both are maxed).
#   ⬢ Opus ⇑           model name and effort: ↓ low, no arrow for medium,
#                       ↑ yellow high, ⇑ red xhigh, ⇈ red max.

def dig_i(h, *path)
  (h.dig(*path) || 0).to_i
end

def dig_f(h, *path)
  (h.dig(*path) || 0).to_f
end

# ▲▼ tokens are at most 4 chars. Floored, not rounded, so 9999 stays "9.9k".
# ctx is padded to a fixed width so the line doesn't jitter.
FMT_TOKENS = ->(n) {
  s = if n >= 1_000_000 then format('%.1fM', (n / 100_000) / 10.0)
      elsif n >= 10_000 then "#{n / 1000}k"
      elsif n >= 1_000  then format('%.1fk', (n / 100) / 10.0)
      else n.to_s
      end
  s
}
FMT_CTX = ->(n) { (n >= 1000 ? format('%.1fk', n / 1000.0) : n.to_s).rjust(7) }

# Single unit, 5h22m -> "6h", not
# This label doubles as the rate-limit's name (see rate_limit_str)
FMT_LEFT = ->(ts) {
  return '' unless ts
  secs = (ts - Time.now.to_i).to_i
  return '' if secs <= 0
  if secs >= 86_400
    "#{(secs / 86_400.0).ceil}d"
  elsif secs >= 3_600
    "#{(secs / 3_600.0).ceil}h"
  else
    "#{(secs / 60.0).ceil}m"
  end
}

# Absolute wall-clock, for the moments you glance at this later and need to
# compare against "now". with_date always includes the date
FMT_CLOCK = ->(ts, with_date) {
  return '' unless ts
  t = Time.at(ts)
  time = t.strftime('%I:%M') + t.strftime('%p').downcase
  with_date ? "#{t.strftime('%-m/%-d')} #{time}" : time
}

BLUE, YELLOW, RED, BOLD_RED, PURPLE, GREEN, RESET =
  "\e[34m", "\e[33m", "\e[31m", "\e[1;31m", "\e[38;5;135m", "\e[32m", "\e[0m"

def paint(color, str)
  color.empty? ? str : "#{color}#{str}#{RESET}"
end

def color_limits(v, str, yellow, red, low = '')
  paint(v >= red ? RED : v >= yellow ? YELLOW : low, str)
end

MODEL_COLORS = [GREEN, BLUE, YELLOW, RED].freeze

# Reasoning-quality zone by model. Sonnet 5.5 vs Opus 5.5
def model_zones(model_name)
  case model_name.to_s.downcase
  when /opus/i
    [150_000, 350_000, 600_000]
  when /sonnet/i
    [80_000, 200_000, 400_000]
  when /qwen.*coder/i
    [24_000, 45_000, 85_000]
  else
    [32_000, 80_000, 150_000] # Fallback
  end
end

def model_level(ctx, model_name)
  good_max, multi_hop, degraded = model_zones(model_name)

  return 3 if ctx >= degraded
  return 2 if ctx >= multi_hop
  return 1 if ctx >= good_max
  0
end
# Physical ceiling: true autocompact hits ~5% free. Trip this at 15% free —
# ten points of headroom to actually act (save notes, flag surprises)
# before the wipe, not a warning that it already happened.
def physical_alert?(ctx, window_size)
  return false if window_size <= 0
  (ctx.to_f / window_size) >= 0.85
end

def ctx_color(ctx, model_name, window_size)
  return BOLD_RED if physical_alert?(ctx, window_size)
  MODEL_COLORS[model_level(ctx, model_name)]
end

# [used %, resets_at]; a window with no activity yet (5h first thing in the morning) is 0%
def limit_window(data, key)
  w = data.dig('rate_limits', key) || {}
  [w['used_percentage'] || 0, w['resets_at']]
end

# Work day is 10am-8pm, split into two half-days. Rough on purpose.
HALF_DAY_STARTS = [10, 15].freeze
HALF_DAY_SECS   = 5 * 3_600

# 7d pace: 10% per weekday half-day reached so far this window (10 per week).
# The half-day the window started in counts whole. Nights/weekends add nothing.
def seven_day_allowance(resets_at)
  return 100 unless resets_at
  now   = Time.now
  start = Time.at(resets_at - 7 * 86_400)
  halves = (start.to_date..now.to_date).sum do |d|
    next 0 if d.saturday? || d.sunday?
    HALF_DAY_STARTS.count do |h|
      slot = Time.local(d.year, d.month, d.day, h)
      slot + HALF_DAY_SECS > start && slot <= now
    end
  end
  [halves * 10, 100].min
end

WALL = 90 # % used where a limit turns red regardless of pace

TEAL = "\e[38;5;37m"

# teal = too low (idle capacity), green = on pace, purple = too high, red = near the wall.
# behind/ahead are how many points off pace counts as too low/too high.
def pace_color(pct, pace, behind, ahead)
  return RED if pct >= WALL
  pct < pace - behind ? TEAL : pct > pace + ahead ? PURPLE : GREEN
end

# pace is the weekday half-day allowance (see seven_day_allowance)
def seven_day_color(pct, resets_at)
  return GREEN unless resets_at
  pace_color(pct, seven_day_allowance(resets_at), 20, 10)
end

# pace is linear: the share of the window already elapsed
def five_hour_color(pct, resets_at)
  return GREEN unless resets_at
  elapsed = (1 - (resets_at - Time.now.to_i) / 18_000.0).clamp(0, 1) * 100
  pace_color(pct, elapsed, 10, 10)
end

def slots_bar(filled, total = 5)
  '▰' * filled + '▱' * (total - filled)
end

# 5 slots, 20% each; any use shows at least one, full only at 100%
def limit_slots(pct)
  filled = (pct / 20.0).round
  filled = [filled, 1].max if pct > 0
  filled = [filled, 4].min if pct < 100
  slots_bar([filled, 5].min)
end

# time left, then % used as a bar (wide) or a number (narrow), in the pace color
def limit_bar(pct, resets, fallback, color, wide)
  label = FMT_LEFT[resets]
  label = fallback if label.empty?
  # narrow: the % is right-aligned in 3 so "3h  5%" and "3d 42%" use one space for 2 digits
  return "◷ #{label} #{paint(color, format('%3s', "#{pct.round}%"))}" unless wide
  "◷ #{label.ljust(3)} #{paint(color, limit_slots(pct))}"
end

def rate_limit_str(data, wide = false)
  return nil unless data['rate_limits'] # no subscription limits (API key)
  five_pct,  five_resets  = limit_window(data, 'five_hour')
  seven_pct, seven_resets = limit_window(data, 'seven_day')

  if five_pct >= 100 || seven_pct >= 100
    # Subscription usage is blocked — you're on API billing (Usage Credits,
    # if enabled) until this clears. 7d always wins here: even if 5h resets
    # in the meantime, you're still gated by 7d, so that's the only reset
    # worth knowing about. Percentage is dropped — it's just 100%, not info.
    clock = seven_pct >= 100 ? FMT_CLOCK[seven_resets, true] : FMT_CLOCK[five_resets, false]
    return paint(RED, "API #{clock}")
  end

  seven_color = seven_day_color(seven_pct, seven_resets)
  "#{limit_bar(five_pct, five_resets, '5h', five_hour_color(five_pct, five_resets), wide)}  #{limit_bar(seven_pct, seven_resets, '7d', seven_color, wide)}"
end

# Only the tail is read: the statusline re-runs often and transcripts grow large
TRANSCRIPT_TAIL = 4 * 1024 * 1024

# {up:, down:, warm:, tools:} summed over every API request for the current prompt;
# nil if the transcript or this prompt's first send isn't found.
def turn_usage(data)
  path, pid = data['transcript_path'], data['prompt_id']
  return nil unless path && pid && File.file?(path)

  lines = File.open(path) do |f|
    f.seek([f.size - TRANSCRIPT_TAIL, 0].max)
    f.read.lines
  end
  seen, tools, cur, turn = {}, {}, nil, nil
  lines.each do |l|
    j = JSON.parse(l) rescue next # first line may be cut off by the seek
    next if j['isSidechain']
    cur = j['promptId'] if j['type'] == 'user' && j['promptId']
    next unless cur == pid && j['type'] == 'assistant'
    # each entry holds one content block, so count tools before the dedupe
    (j.dig('message', 'content') || []).each do |b|
      tools[b['id']] = true if b['type'] == 'tool_use'
    end
    u = j.dig('message', 'usage')
    id = j.dig('message', 'id')
    next if !u || seen[id] # one response can span several entries
    seen[id] = true
    # first send of the turn: the only one that can find the cache cold
    turn ||= { up: 0, down: 0, warm: dig_i(u, 'cache_read_input_tokens') > dig_i(u, 'cache_creation_input_tokens') }
    turn[:up]   += dig_i(u, 'input_tokens') + dig_i(u, 'cache_creation_input_tokens')
    turn[:down] += dig_i(u, 'output_tokens')
  end
  turn&.merge(tools: tools.size)
end

# [▲▼⚒ ▣ctx, $cost] — these share tokens, so they're built together
# ▲ blue = turn's first send hit a warm cache, red = cold (paid full price to re-send)
# Slot width = degraded size / count, so every zone edge lands on a slot edge:
# Sonnet 10 x 40k, Opus 12 x 50k.
RED_SLOTS = 2 # extra slots past degraded, same width
def ctx_slot_count(model_name)
  case model_name.to_s.downcase
  when /opus/i   then 12
  when /sonnet/i then 10
  else 5
  end
end

# Every slot has the color of its band (the zone at the slot's start): solid
# when ctx has reached it, hollow when it is still ahead.
def ctx_slots(ctx, model_name)
  count = ctx_slot_count(model_name)
  width = model_zones(model_name)[2].to_f / count
  count += RED_SLOTS # the red zone starts at degraded, so it needs slots of its own
  lit   = [(ctx / width).floor, count].min
  (1..count).map do |k|
    band = MODEL_COLORS[model_level(((k - 1) * width).to_i, model_name)]
    k <= lit ? paint(band, '▰') : paint(band, '▱')
  end.join
end

SHOW_TURN = true

def usage_str(data, warm, wide = false, size = true, extras = true)
  cw = data['context_window'] || {}

  turn_in    = dig_i(cw, 'total_input_tokens')
  turn_out   = dig_i(cw, 'total_output_tokens')
  ctx_max    = dig_i(cw, 'context_window_size')
  cost       = dig_f(data, 'cost', 'total_cost_usd')
  model_name = data.dig('model', 'display_name')

  ctx = turn_in + turn_out

  # Per-turn ▲▼⚒ took a while to tune: DO NOT DELETE. Set SHOW_TURN to false to
  # hide it (it also skips reading the transcript).
  turn_str = ''
  if SHOW_TURN && extras
    cu      = cw['current_usage'] || {}
    tool_in = dig_i(cu, 'cache_creation_input_tokens')
    if (turn = turn_usage(data))
      tool_in, down, warm, tools = turn[:up], turn[:down], turn[:warm], turn[:tools]
    else
      down, tools = turn_out, 0
    end
    up_str   = paint(warm.nil? ? '' : warm ? BLUE : RED, "▲#{FMT_TOKENS[tool_in]}")
    down_str = paint(PURPLE, "▼#{FMT_TOKENS[down]}")
    turn_str = "#{up_str} #{down_str} ⚒#{tools}  "
  end

  ctx_col  = ctx_color(ctx, model_name, ctx_max)
  # the ▣ takes the size's color (so the 85% alert shows without the number)
  ctx_str  = paint(ctx_col, '▣')
  ctx_str += " #{ctx_slots(ctx, model_name)}" if wide
  ctx_str += paint(ctx_col, FMT_CTX[ctx]) if size
  # ▲▼⚒ sit just left of the cost
  [ctx_str, extras ? "#{turn_str}#{paint(MUTED, format('$%.2f', cost))}" : nil]
end

# [warm, expires_at]; nil when there is no cache
def prompt_cache(data)
  pc         = data['prompt_cache'] || {}
  cu         = data.dig('context_window', 'current_usage') || {}
  cache_in   = dig_i(cu, 'cache_read_input_tokens')
  tool_in    = dig_i(cu, 'cache_creation_input_tokens')
  expires_at = pc['expires_at']
  return nil unless expires_at

  warm = pc.key?('warm') ? pc['warm'] : cache_in > tool_in
  [warm, expires_at]
end

CYAN, BOLD_BLUE, TURQUOISE = "\e[36m", "\e[1;34m", "\e[38;5;80m"

# Quiet color for info that is never a warning ($cost, model name): plain text
# draws the eye, and the zone colors (green/blue/yellow/red) must keep their meaning.
MUTED = "\e[38;5;67m"

EFFORT_ARROWS = { 'low' => '↓', 'medium' => '→', 'high' => '↑', 'xhigh' => '⇑', 'max' => '⇈' }.freeze
EFFORT_COLORS = { 'high' => YELLOW, 'xhigh' => RED, 'max' => RED }.freeze

# "Opus ⇑": model name without the version, then an arrow for effort
# (colored when xhigh/max). Medium and models without effort get no arrow.
def model_str(data)
  name  = paint(MUTED, data.dig('model', 'display_name').to_s[/\A[A-Za-z]+/].to_s)
  level = data.dig('effort', 'level')
  return name if level.nil? || level == 'medium'
  "#{name} #{paint(EFFORT_COLORS.fetch(level, ''), EFFORT_ARROWS.fetch(level, level[0]))}"
end

# Same walk as the PS1 in dotfiles/bashrc.d/git-prompt.sh: find .git by walking
# up, read HEAD directly (no fork). A .git file means a linked worktree.
# => [root_dir, branch, linked_worktree?] or nil outside git
def git_head(start)
  dir = start.to_s
  until dir.empty? || dir == '/'
    git = File.join(dir, '.git')
    linked = File.file?(git)
    if linked
      gitdir = File.read(git)[/gitdir: (.+)/, 1]
      head = File.join(File.expand_path(gitdir, dir), 'HEAD') if gitdir
    elsif File.directory?(git)
      head = File.join(git, 'HEAD')
    end
    if head && File.file?(head)
      ref = File.read(head)
      return [dir, ref[%r{\Aref: refs/heads/(.+)}, 1]&.strip || '(detached)', linked]
    end
    dir = File.dirname(dir)
  end
  nil
end

# One symbol, the first that applies, shown left of the repo name:
#   ✖ detached HEAD (red)      ✚ any local change, staged or not (yellow)
#   ⚑ stash (yellow)           ↑ unpushed commits, or no upstream (cyan)
#   ↓ behind upstream (cyan)   ✔ in sync (green)
# Ahead/behind are as of the last fetch: no network.
def git_state(root)
  out = IO.popen(['git', '-C', root, 'status', '--porcelain=v2', '--branch', '--show-stash', err: File::NULL], &:readlines)
  return nil unless $?.success?

  head     = out.find { |l| l.start_with?('# branch.head ') }.to_s.split.last
  upstream = out.any? { |l| l.start_with?('# branch.upstream ') }
  ahead, behind = out.find { |l| l.start_with?('# branch.ab ') }.to_s.scan(/\d+/).map(&:to_i)
  stash    = out.find { |l| l.start_with?('# stash ') }.to_s.split.last.to_i
  dirty    = out.any? { |l| !l.start_with?('#') }

  if    head == '(detached)'                then paint(RED, '✖')
  elsif dirty                               then paint(YELLOW, '✚')
  elsif stash > 0                           then paint(YELLOW, '⚑')
  elsif !upstream || ahead.to_i > 0         then paint(CYAN, '↑')
  elsif behind.to_i > 0                     then paint(CYAN, '↓')
  else paint(GREEN, '✔')
  end
end

BRANCH_MAX = 24

# "#22", linked to the PR (OSC 8) when the url is known
def pr_str(data)
  number = data.dig('pr', 'number')
  return nil unless number
  text = "##{number}"
  url  = data.dig('pr', 'url')
  url ? "\e]8;;#{url}\e\\#{text}\e]8;;\e\\" : text
end

# "repo branch #pr"; nil outside git. The branch is dropped on main and in a
# linked worktree (the worktree folder already names it). State symbols come
# first, the repo name is bold blue as in the PS1, the branch is cyan.
#
# wide: "✔ [branch] repo #pr", branch always shown (PS1 style).
def git_str(data, wide = false)
  dir = data.dig('workspace', 'current_dir') || data['cwd'] || Dir.pwd
  root, branch, linked = git_head(dir)
  return nil unless root
  name = paint(BOLD_BLUE, File.basename(root))
  text = branch.length > BRANCH_MAX ? "#{branch[0, BRANCH_MAX - 1]}…" : branch
  if wide
    parts = [git_state(root), "[#{paint(TURQUOISE, text)}]", name]
  else
    parts = [git_state(root), name]
    parts << paint(TURQUOISE, text) unless linked || %w[main master].include?(branch)
  end
  parts << pr_str(data)
  parts.compact.join(' ')
end

# Claude Code sets COLUMNS for us; notifications share the right edge, so keep a margin
RIGHT_MARGIN = 5
ANSI = /\e\[[0-9;]*m|\e\]8;;[^\e]*\e\\/

def visible_len(str)
  str.gsub(ANSI, '').length
end

# left-aligned on the left, right on the right (2-space gap when COLUMNS is unknown or tight)
def justify(left, right)
  gap = ENV['COLUMNS'].to_i - RIGHT_MARGIN - visible_len(left) - visible_len(right)
  "#{left}#{' ' * [gap, 2].max}#{right}"
end

def cache_expired?(expires_at)
  expires_at && expires_at <= Time.now.to_i
end

# Under this the clock turns turquoise: a nudge, not an alarm (the expiry keeps
# getting pushed out, so yellow would fire too often)
CACHE_LOW_SECS = 120

# Sits right after ctx (▣ is the icon for both); red once the cache is gone
def cache_str(expires_at)
  return nil unless expires_at
  clock = if cache_expired?(expires_at) then paint(RED, 'EXPIRED')
          elsif expires_at - Time.now.to_i < CACHE_LOW_SECS then paint(TURQUOISE, FMT_CLOCK[expires_at, false])
          else paint(GREEN, FMT_CLOCK[expires_at, false])
          end
  "⛁ #{clock}"
end

# => [left, right]
# wide:      ✔ [branch] repo #pr  ▣ ▰▱▱▱▱ ctx ⛁ clock          $cost  ◷ 5h ▰▱▱▱▱  ◷ 7d ▰▱▱▱▱  ⬢ model
# condensed: ✔ repo branch #pr  ▣ ctx ⛁ clock                   $cost  ◷ 5h ⣿⡏⠀⠀  ◷ 7d ⠇⠀⠀⠀  ⬢ model
def layout(data, wide, size, extras)
  warm, expires_at = prompt_cache(data)
  usage, cost = usage_str(data, warm, wide, size, extras)
  ctx_clock = "#{usage} #{cache_str(expires_at)}".rstrip
  model     = "⬢ #{model_str(data)}"
  rates     = rate_limit_str(data, wide)

  [[git_str(data, wide), ctx_clock].compact.join('  '), [[cost, rates].compact.join('  '), (model if extras)].compact.join('  ')]
end

# Tried in order: [bars, ctx size, ▲▼⚒ $cost model]
#   large:  bars + size + ▲▼⚒ $cost model
#   medium: bars only
#   small:  no bar, size only (nothing else)
# The first layout whose minimum COLUMNS is met wins; the width is the only rule.
# last flag: push the right group to the edge (medium keeps it next to the left group)
LAYOUTS = [[true, true, true, 174, true], [true, false, false, 82, false], [false, true, false, 0, true]].freeze

def render(data)
  columns = ENV['COLUMNS'].to_i
  wide, size, extras, _, edge = LAYOUTS.find { |_, _, _, min_columns, _| columns >= min_columns }
  left, right = layout(data, wide, size, extras)
  edge ? justify(left, right) : "#{left}  #{right}"
end

if __FILE__ == $0
  data = JSON.parse($stdin.read) rescue {}
  puts render(data)
end
