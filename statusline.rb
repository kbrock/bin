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
#   ◷ 3h ▰▱▱▱▱         5h and 7d subscription limits; the label IS the reset
#                       countdown. Bar (wide) = 5 slots of 20%, or the % (narrow).
#                       Used slots are solid: green, purple 10+ ahead of pace, red
#                       at LIMIT_WALL (90%) or more. Behind pace, everything up to and
#                       including the block you're in is bright green (used solid,
#                       catch-up room hollow); the rest of the window is dim.
#                       5h pace is linear across the window (1 slot per hour).
#                       7d pace splits 100% over the half-days (10am-3pm, 3pm-8pm)
#                       of the days in CLAUDE_PACE_DAYS (default mon-fri, 10% each)
#                       reached so far.
#                       Either hitting 100% collapses both to
#                       "API <clock>": you're on pay-as-you-go until then (7d
#                       wins if both are maxed).
#   CLAUDE_PACE_DAYS    days the 7d pace counts: "mon-fri" (default), "sat,sun",
#                       "all". Ranges and commas mix ("mon-wed,fri").
#   Glyphs              STATUSLINE_GLYPH picks one pair for every bar (context and
#                       limits): parallelogram (default), braille, circles,
#                       squares, pills, shades.
#   ⬢ Opus ⇑           model name and effort: ↓ low, no arrow for medium,
#                       ↑ yellow high, ⇑ red xhigh, ⇈ red max.

# One glyph pair for every bar (context and limits): [filled, hollow].
# STATUSLINE_GLYPH picks the set; see the samples at the top.
GLYPHS = {
  'parallelogram' => %w[▰ ▱], 'circles' => %w[● ○], 'squares' => %w[■ □],
  'pills' => %w[▮ ▯], 'braille' => %w[⣿ ⣀], 'shades' => %w[▓ ░]
}.freeze
FILL, HOLLOW = GLYPHS.fetch(ENV['STATUSLINE_GLYPH'].to_s, GLYPHS['parallelogram'])

def dig_i(h, *path)
  (h.dig(*path) || 0).to_i
end

def dig_f(h, *path)
  (h.dig(*path) || 0).to_f
end

# At most 4 chars. Floored, not rounded, so 9999 stays "9.9k".
FMT_COUNT = ->(n) {
  if n >= 1_000_000 then format('%.1fM', (n / 100_000) / 10.0)
  elsif n >= 10_000 then "#{n / 1000}k"
  elsif n >= 1_000  then format('%.1fk', (n / 100) / 10.0)
  else n.to_s
  end
}

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
  color.to_s.empty? ? str : "#{color}#{str}#{RESET}"
end

# The name of the tier a value falls in. tiers maps each tier's lower bound to
# its name: { 0 => :good, 80_000 => :multi_hop }. nil when below the first bound.
def calc_tier(value, tiers)
  tiers.select { |from, _| from <= value }.max_by { |from, _| from }&.last
end

def color_limits(v, str, yellow, red, low = '')
  paint(v >= red ? RED : v >= yellow ? YELLOW : low, str)
end

MODEL_COLORS = [GREEN, BLUE, YELLOW, RED].freeze

CTX_TIER_NAMES = %i[good multi_hop degraded fried].freeze

# Autocompact hits ~5% free. Trip :compact at 15% free: ten points of headroom
# to act (save notes, flag surprises) before the wipe.
CTX_COMPACT_PERCENT = 85

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

# [used %, resets_at]; a window with no activity yet (5h first thing in the morning) is 0%
def limit_window(data, key)
  w = data.dig('rate_limits', key) || {}
  [w['used_percentage'] || 0, w['resets_at']]
end

# Work day is 10am-8pm, split into two half-days. Rough on purpose.
HALF_DAY_STARTS = [10, 15].freeze
HALF_DAY_SECS   = 5 * 3_600

DAY_NAMES = %w[sun mon tue wed thu fri sat].freeze

# Days this account is used, as wday numbers. CLAUDE_PACE_DAYS="mon-fri" (work,
# the default), "sat,sun" (personal) or "all" (every day); ranges and commas mix.
def pace_days
  spec = (ENV['CLAUDE_PACE_DAYS'] || 'mon-fri').downcase
  return (0..6).to_a if spec == 'all'
  spec.split(',').flat_map do |part|
    from, to = part.split('-').map { |d| DAY_NAMES.index(d[0, 3]) }
    next [from] unless to
    from <= to ? (from..to).to_a : (from..6).to_a + (0..to).to_a
  end.compact.uniq
end

# 7d pace: the week's 100% split evenly over the half-days of pace_days; each
# one reached so far this window counts (10% each for mon-fri). The half-day the
# window started in counts whole. Other days add nothing.
def seven_day_allowance(resets_at)
  return 100 unless resets_at
  days = pace_days
  return 100 if days.empty?
  now   = Time.now
  start = Time.at(resets_at - 7 * 86_400)
  halves = (start.to_date..now.to_date).sum do |d|
    next 0 unless days.include?(d.wday)
    HALF_DAY_STARTS.count do |h|
      slot = Time.local(d.year, d.month, d.day, h)
      slot + HALF_DAY_SECS > start && slot <= now
    end
  end
  [halves * 100.0 / (days.size * HALF_DAY_STARTS.size), 100].min
end

# Limit tiers. :wall comes from the % used; the others from how far past the
# pace you are, in points (negative = behind). Lower bounds, see calc_tier.
LIMIT_WALL = { 90 => :wall }.freeze
LIMIT_PACE = { -Float::INFINITY => :behind, 0 => :on_pace, 10 => :ahead }.freeze

BRIGHT_GREEN = "\e[1;92m"
DIM_GREEN    = "\e[38;5;65m"

# pace is linear: the share of the window already elapsed
def five_hour_pace(resets_at)
  return nil unless resets_at
  (1 - (resets_at - Time.now.to_i) / 18_000.0).clamp(0, 1) * 100
end

# pace is the allowance for the days this account works (see seven_day_allowance)
def seven_day_pace(resets_at)
  resets_at && seven_day_allowance(resets_at)
end

# 5 slots, 20% each; any use shows at least one, full only at 100%.
# Behind pace, the window up to and including the block you're in is bright:
# the used slots (solid) and the catch-up room (hollow). The rest is dim.
def limit_slots(pct, pace, color)
  filled = (pct / 20.0).round
  filled = [filled, 1].max if pct > 0
  filled = [filled, 4].min if pct < 100
  filled = [filled, 5].min
  due    = pace ? [(pace / 20.0).ceil, 5].min : 0
  behind = color == GREEN && due > filled
  (0...5).map do |k|
    if    k < filled then paint(behind ? BRIGHT_GREEN : color, FILL)
    elsif k < due    then paint(BRIGHT_GREEN, HOLLOW)
    else                  paint(DIM_GREEN, HOLLOW)
    end
  end.join
end

# time left, then % used as a bar (wide) or a number (narrow), in the pace color
def limit_bar(pct, resets, fallback, pace, tier, wide)
  color = THEME[tier]
  label = FMT_LEFT[resets]
  label = fallback if label.empty?
  # narrow: the % is right-aligned in 3 so "3h  5%" and "3d 42%" use one space for 2 digits
  return "◷ #{label} #{paint(color, format('%3s', "#{pct.round}%"))}" unless wide
  "◷ #{label.ljust(3)} #{limit_slots(pct, pace, color)}"
end

def rate_limit_str(session, wide = false)
  return nil unless session.limits? # no subscription limits (API key)

  if session.five_pct >= 100 || session.seven_pct >= 100
    # Subscription usage is blocked — you're on API billing (Usage Credits,
    # if enabled) until this clears. 7d always wins here: even if 5h resets
    # in the meantime, you're still gated by 7d, so that's the only reset
    # worth knowing about. Percentage is dropped — it's just 100%, not info.
    clock = session.seven_pct >= 100 ? FMT_CLOCK[session.seven_resets, true] : FMT_CLOCK[session.five_resets, false]
    return paint(THEME[:api], "API #{clock}")
  end

  "#{limit_bar(session.five_pct, session.five_resets, '5h', session.five_expected, session.five_tier, wide)}  #{limit_bar(session.seven_pct, session.seven_resets, '7d', session.seven_expected, session.seven_tier, wide)}"
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
def ctx_slots(session)
  count = ctx_slot_count(session.model_name)
  width = session.ctx_zones[2].to_f / count
  count += RED_SLOTS # the red zone starts at degraded, so it needs slots of its own
  lit   = [(session.ctx / width).floor, count].min
  (1..count).map do |k|
    band = MODEL_COLORS[model_level(((k - 1) * width).to_i, session.model_name)]
    k <= lit ? paint(band, FILL) : paint(band, HOLLOW)
  end.join
end

SHOW_TURN = true

# "▣ ▰▰▱▱ 120.3k": the ▣ takes the size's color (so the 85% alert shows without
# the number). wide adds the bar, size adds the number.
def context_str(session, wide = false, size = true)
  color = THEME[session.ctx_tier]
  str   = paint(color, '▣')
  str  += " #{ctx_slots(session)}" if wide
  str  += paint(color, FMT_COUNT[session.ctx].rjust(7)) if size
  str
end

# "▲200 ▼300 ⚒2": tokens for this whole turn. nil when SHOW_TURN is false.
# Per-turn ▲▼⚒ took a while to tune: DO NOT DELETE. Set SHOW_TURN to false to
# hide it (it also skips reading the transcript).
def turn_str(session)
  return nil unless SHOW_TURN
  up_str   = paint(THEME[session.turn_cache_tier], "▲#{FMT_COUNT[session.turn_up]}")
  down_str = paint(PURPLE, "▼#{FMT_COUNT[session.turn_down]}")
  "#{up_str} #{down_str} ⚒#{session.turn_tools}"
end

def cost_str(session)
  paint(THEME[:cost], format('$%.2f', session.cost))
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

# Name to color. The session names what a value means (a tier, an effort level,
# a git state); this decides how it looks. The last group are fixed-color text.
THEME = {
  good: GREEN, multi_hop: BLUE, degraded: YELLOW, fried: RED, compact: BOLD_RED,
  cache_hit: BLUE, cache_miss: RED,
  behind: GREEN, on_pace: GREEN, ahead: PURPLE, wall: RED,
  warm: GREEN, cooling: TURQUOISE, expired: RED,
  high: YELLOW, xhigh: RED, max: RED,
  cost: MUTED, model: MUTED, api: RED
}.freeze

EFFORT_ARROWS = { 'low' => '↓', 'medium' => '→', 'high' => '↑', 'xhigh' => '⇑', 'max' => '⇈' }.freeze

# "Opus ⇑": model name without the version, then an arrow for effort
# (colored when xhigh/max). Medium and models without effort get no arrow.
def model_str(session)
  name  = paint(THEME[:model], session.model_name.to_s[/\A[A-Za-z]+/].to_s)
  level = session.effort
  return name if level.nil? || level == 'medium'
  "#{name} #{paint(THEME[level.to_sym], EFFORT_ARROWS.fetch(level, level[0]))}"
end

# "[branch] dir"; nil outside git or on a detached HEAD
def git_str(session)
  branch = IO.popen(['git', '-C', session.cwd, 'branch', '--show-current', err: File::NULL], &:read).to_s.strip
  "[#{TURQUOISE}#{branch}#{RESET}] #{BOLD_BLUE}#{File.basename(session.cwd)}#{RESET}" unless branch.empty?
end

# Everything a display needs, read from the JSON Claude Code sends. Every value is
# a method, memoized, so what the line doesn't show is never computed: the
# transcript is only read by #turn, `git status` only by #git_state.
# Limits are percents (0-100), and so are the *_expected pace values.
class ClaudeSession
  def initialize(data)
    @data = data
  end

  def ctx
    @ctx ||= dig_i(context_window, 'total_input_tokens') + dig_i(context_window, 'total_output_tokens')
  end

  def output_tokens
    @output_tokens ||= dig_i(context_window, 'total_output_tokens')
  end

  def cache_created
    @cache_created ||= dig_i(context_window, 'current_usage', 'cache_creation_input_tokens')
  end
  # Reasoning-quality zones for this model; level 0-3 for the current ctx; and
  # whether ctx is near the physical window limit
  def ctx_zones
    @ctx_zones ||= model_zones(model_name)
  end

  # Named tiers for ctx: the model's zones, then :compact once ctx fills
  # CTX_COMPACT_PERCENT of the window (a ceiling: later zones are dropped).
  # { 0 => :good, 150_000 => :multi_hop, ..., 850_000.0 => :compact }
  def ctx_tiers
    @ctx_tiers ||= begin
      tiers = ([0] + model_zones(model_name)).zip(CTX_TIER_NAMES).to_h
      if window_size > 0
        compact_at = window_size * CTX_COMPACT_PERCENT / 100.0
        tiers = tiers.reject { |from, _| from >= compact_at }
        tiers[compact_at] = :compact
      end
      tiers
    end
  end

  def ctx_tier
    calc_tier(ctx, ctx_tiers)
  end

  def ctx_percent
    window_size > 0 ? ctx * 100.0 / window_size : 0
  end

  def window_size
    @window_size ||= dig_i(context_window, 'context_window_size')
  end

  def cost
    @cost ||= dig_f(@data, 'cost', 'total_cost_usd')
  end

  def model_name
    @model_name ||= @data.dig('model', 'display_name')
  end

  def effort
    @effort ||= @data.dig('effort', 'level')
  end

  def cwd
    @cwd ||= @data.dig('workspace', 'current_dir') || @data['cwd'] || Dir.pwd
  end

  # nil when there are no subscription limits (API key)
  def limits?
    !@data['rate_limits'].nil?
  end

  def five_pct
    five_hour.first
  end

  def five_resets
    five_hour.last
  end

  def seven_pct
    seven_day.first
  end

  def seven_resets
    seven_day.last
  end

  def five_expected
    @five_expected ||= five_hour_pace(five_resets)
  end

  # :wall, :ahead, :on_pace or :behind; no pace known counts as :on_pace
  def five_tier
    limit_tier(five_pct, five_expected)
  end

  def seven_tier
    limit_tier(seven_pct, seven_expected)
  end

  def seven_expected
    @seven_expected ||= seven_day_pace(seven_resets)
  end

  # nil when Claude Code reports no cache expiry
  def cache_warm
    cache&.first
  end

  def cache_expires_at
    cache&.last
  end

  def cache_seconds_left
    cache_expires_at && cache_expires_at - Time.now.to_i
  end

  # :warm, :cooling (under CACHE_LOW_SECS left) or :expired; nil with no cache
  def cache_tier
    seconds = cache_seconds_left
    seconds && calc_tier(seconds, CACHE_TIERS)
  end

  # {up:, down:, warm:, tools:} or nil; reads the transcript
  def turn
    defined?(@turn) ? @turn : (@turn = turn_usage(@data))
  end

  # Tokens sent, tokens received and tool calls for this turn. From the
  # transcript when it can be read, else from the last request.
  def turn_up
    turn ? turn[:up] : cache_created
  end

  def turn_down
    turn ? turn[:down] : output_tokens
  end

  def turn_tools
    turn ? turn[:tools] : 0
  end

  # Did the turn's first send find the cache? :cache_hit, :cache_miss, nil if unknown
  def turn_cache_tier
    warm = turn ? turn[:warm] : cache_warm
    warm.nil? ? nil : (warm ? :cache_hit : :cache_miss)
  end

  private

  def limit_tier(pct, expected)
    calc_tier(pct, LIMIT_WALL) || (expected ? calc_tier(pct - expected, LIMIT_PACE) : :on_pace)
  end

  def cache
    @cache ||= prompt_cache(@data)
  end

  def context_window
    @context_window ||= @data['context_window'] || {}
  end

  def five_hour
    @five_hour ||= limit_window(@data, 'five_hour')
  end

  def seven_day
    @seven_day ||= limit_window(@data, 'seven_day')
  end
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

# Under this the clock turns turquoise: a nudge, not an alarm (the expiry keeps
# getting pushed out, so yellow would fire too often)
CACHE_LOW_SECS = 120
CACHE_TIERS = { -Float::INFINITY => :expired, 1 => :cooling, CACHE_LOW_SECS => :warm }.freeze

# Sits right after ctx (▣ is the icon for both); red once the cache is gone
def cache_str(session)
  tier = session.cache_tier
  return nil unless tier
  text = tier == :expired ? 'EXPIRED' : FMT_CLOCK[session.cache_expires_at, false]
  "⛁ #{paint(THEME[tier], text)}"
end

# => [left, right]
# wide:      ✔ [branch] repo #pr  ▣ ▰▱▱▱▱ ctx ⛁ clock          $cost  ◷ 5h ▰▱▱▱▱  ◷ 7d ▰▱▱▱▱  ⬢ model
# condensed: ✔ repo branch #pr  ▣ ctx ⛁ clock                   $cost  ◷ 5h ⣿⡏⠀⠀  ◷ 7d ⠇⠀⠀⠀  ⬢ model
def layout(data, wide, size, extras)
  session = ClaudeSession.new(data)
  ctx_clock = [context_str(session, wide, size), cache_str(session)].compact.join(' ')
  usage     = extras ? [turn_str(session), cost_str(session)].compact.join('  ') : nil
  model     = "⬢ #{model_str(session)}"
  rates     = rate_limit_str(session, wide)

  [[git_str(session), ctx_clock].compact.join('  '), [[usage, rates].compact.join('  '), (model if extras)].compact.join('  ')]
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
  input = $stdin.read
  # dev only: STATUSLINE_DUMP=/path/file.json saves what Claude Code sends (owner-readable)
  File.write(ENV['STATUSLINE_DUMP'], input, perm: 0o600) if ENV['STATUSLINE_DUMP']
  data = JSON.parse(input) rescue {}
  puts render(data)
end
