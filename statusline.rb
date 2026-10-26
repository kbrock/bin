#!/usr/bin/env ruby
require 'json'
require 'date'

# Statusline: one line, left group and right group pushed to the edge by COLUMNS.
#   git_str         [branch] dir
#   context_str     ▣ bar size      zone color per model; bold red at 85% of the window
#   cache_str       ⛁ clock         green warm, turquoise under 2m, red EXPIRED
#   turn_str        ▲up ▼down ⚒n    tokens this turn, from the transcript
#   cost_str        $cost           API cost
#   rate_limit_str  ◷ 3h ▰▱▱▱▱     5h and 7d limits; the label is the reset countdown
#   model_str       ⬢ Opus ⇑       effort arrow

# One glyph pair for every bar (context and limits): [filled, empty]. STATUSLINE_GLYPH picks one.
# Ideas, not built (a cell can be partly full, so they need a different bar): eighth blocks
# ▏▎▍▌▋▊▉█, braille dots ⣀⣄⣤⣦⣶⣷⣿, a low line ▁▂▃▄▅▆▇█, a gray background behind the empty part.
GLYPHS = {
  'parallelogram' => %w[▰ ▱], 'arrows' => %w[► ▷], 'squares' => %w[■ □], 'rects' => %w[◼ ▭],
  'circles' => %w[● ○], 'pills' => %w[▮ ▯], 'shades' => %w[▓ ░]
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

# name is a THEME entry; nil or unknown is plain text
def paint(name, str)
  color = THEME[name]
  color ? "#{color}#{str}#{RESET}" : str
end

# The name of the tier a value falls in. tiers maps each tier's lower bound to
# its name: { 0 => :good, 80_000 => :multi_hop }. nil when below the first bound.
def calc_tier(value, tiers)
  tiers.select { |from, _| from <= value }.max_by { |from, _| from }&.last
end

CTX_TIER_NAMES = %i[good multi_hop degraded fried].freeze

# Autocompact hits ~5% free. Trip :compact at 15% free: ten points of headroom
# to act (save notes, flag surprises) before the wipe.
CTX_COMPACT_PERCENT = 85

# Reasoning-quality zones (where good ends, multi-hop ends, degraded ends) and bar
# slots per model. Sonnet 5.5 vs Opus 5.5; the last entry is the fallback.
CTX_MODELS = {
  /opus/i        => { zones: [150_000, 350_000, 600_000], slots: 12 },
  /sonnet/i      => { zones: [80_000, 200_000, 400_000],  slots: 10 },
  /qwen.*coder/i => { zones: [24_000, 45_000, 85_000],    slots: 5 }
}.freeze
CTX_FALLBACK = { zones: [32_000, 80_000, 150_000], slots: 5 }.freeze

def ctx_model(model_name)
  CTX_MODELS.find { |name, _| name =~ model_name.to_s }&.last || CTX_FALLBACK
end

# [used %, resets_at]; a window with no activity yet (5h first thing in the morning) is 0%
def limit_window(data, key)
  w = data.dig('rate_limits', key) || {}
  [w['used_percentage'] || 0, w['resets_at']]
end

# Limit tiers. :wall comes from the % used; the others from how far past the
# pace you are, in points (negative = behind). Lower bounds, see calc_tier.
LIMIT_WALL = { 90 => :wall }.freeze
LIMIT_PACE = { -Float::INFINITY => :behind, 0 => :on_pace, 10 => :ahead }.freeze

# 5 slots, 20% each; any use shows at least one, full only at 100%.
# Behind pace, the window up to and including the block you're in is bright:
# the used slots (solid) and the catch-up room (hollow). The rest is dim.
def limit_slots(pct, pace, tier)
  filled = (pct / 20.0).round
  filled = [filled, 1].max if pct > 0
  filled = [filled, 4].min if pct < 100
  filled = [filled, 5].min
  due    = pace ? [(pace / 20.0).ceil, 5].min : 0
  used   = %i[behind on_pace].include?(tier) ? (due > filled ? :behind : :on_pace) : tier
  bar(filled, [used] * 5, [:behind] * due + [:future] * (5 - due))
end

# time left, then % used as a bar (wide) or a number (narrow), in the pace color
def limit_bar(pct, resets, fallback, pace, tier, wide)
  label = FMT_LEFT[resets]
  label = fallback if label.empty?
  # narrow: the % is right-aligned in 3 so "3h  5%" and "3d 42%" use one space for 2 digits
  return "◷ #{label} #{paint(tier, format('%3s', "#{pct.round}%"))}" unless wide
  "◷ #{label.ljust(3)} #{limit_slots(pct, pace, tier)}"
end

def rate_limit_str(session, wide = false)
  return nil unless session.limits? # no subscription limits (API key)

  if session.five_pct >= 100 || session.seven_pct >= 100
    # Subscription usage is blocked — you're on API billing (Usage Credits,
    # if enabled) until this clears. 7d always wins here: even if 5h resets
    # in the meantime, you're still gated by 7d, so that's the only reset
    # worth knowing about. Percentage is dropped — it's just 100%, not info.
    clock = session.seven_pct >= 100 ? FMT_CLOCK[session.seven_resets, true] : FMT_CLOCK[session.five_resets, false]
    return paint(:api, "API #{clock}")
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
# One slot per entry: solid in on[k] if k < filled, else hollow in off[k] (theme names)
def bar(filled, on, off)
  on.each_index.map { |k| k < filled ? paint(on[k], FILL) : paint(off[k], HOLLOW) }.join
end

RED_SLOTS = 2 # extra slots past degraded, same width
# Every slot has the color of its band (the zone at the slot's start): solid
# when ctx has reached it, hollow when it is still ahead.
def ctx_slots(session)
  count = ctx_model(session.model_name)[:slots]
  width = session.ctx_zones[2].to_f / count
  count += RED_SLOTS # the red zone starts at degraded, so it needs slots of its own
  bands = (0...count).map { |k| calc_tier((k * width).to_i, session.ctx_zone_tiers) }
  bar([(session.ctx / width).floor, count].min, bands, bands)
end

# "▣ ▰▰▱▱ 120k": the ▣ takes the size's color (so the 85% alert shows without
# the number). wide adds the bar. The bar is scaled to the
# model's degraded size (Sonnet 10 slots of 40k, Opus 12 of 50k) plus RED_SLOTS past
# it; each slot has its zone's color, solid once reached.
def context_str(session, wide = false)
  str   = paint(session.ctx_tier, '▣')
  str  += " #{ctx_slots(session)}" if wide
  str + paint(session.ctx_tier, FMT_COUNT[session.ctx].rjust(5))
end

# "▲200 ▼300 ⚒2": tokens for this whole turn. ▲ is blue or red when the turn's first
# send hit or missed the cache.
def turn_str(session)
  up_str   = paint(session.turn_cache_tier, "▲#{FMT_COUNT[session.turn_up]}")
  down_str = paint(:turn_down, "▼#{FMT_COUNT[session.turn_down]}")
  "#{up_str} #{down_str} ⚒#{session.turn_tools}"
end

def cost_str(session)
  paint(:cost, format('$%.2f', session.cost))
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
BRIGHT_GREEN = "\e[1;92m"
DIM_GREEN    = "\e[38;5;65m"

# Name to color. The session names what a value means (a tier, an effort level,
# a git state); this decides how it looks. The last group are fixed-color text.
THEME = {
  good: GREEN, multi_hop: BLUE, degraded: YELLOW, fried: RED, compact: BOLD_RED,
  cache_hit: BLUE, cache_miss: RED,
  behind: BRIGHT_GREEN, future: DIM_GREEN, on_pace: GREEN, ahead: PURPLE, wall: RED,
  warm: GREEN, cooling: TURQUOISE, expired: RED,
  high: YELLOW, xhigh: RED, max: RED,
  cost: MUTED, model: MUTED, api: RED, turn_down: PURPLE,
  repo: BOLD_BLUE, branch: TURQUOISE
}.freeze

EFFORT_ARROWS = { 'low' => '↓', 'medium' => '→', 'high' => '↑', 'xhigh' => '⇑', 'max' => '⇈' }.freeze

# "Opus ⇑": model name without the version, then an arrow for effort
# (colored when xhigh/max). Medium and models without effort get no arrow.
def model_str(session)
  name  = paint(:model, session.model_name.to_s[/\A[A-Za-z]+/].to_s)
  level = session.effort
  return name if level.nil? || level == 'medium'
  "#{name} #{paint(level.to_sym, EFFORT_ARROWS.fetch(level, level[0]))}"
end

# "[branch] dir"; nil outside git or on a detached HEAD
def git_str(session)
  branch = IO.popen(['git', '-C', session.cwd, 'branch', '--show-current', err: File::NULL], &:read).to_s.strip
  "[#{paint(:branch, branch)}] #{paint(:repo, File.basename(session.cwd))}" unless branch.empty?
end

# Everything a display needs, read from the JSON Claude Code sends. Plain values
# are set once in the constructor; derived values are methods, memoized, so what
# the line doesn't show is never computed (the transcript is only read by #turn).
# Limits are percents (0-100), and so are the *_expected pace values.
class ClaudeSession
  attr_accessor :ctx, :output_tokens, :cache_created, :window_size, :cost, :model_name, :effort, :cwd,
                :five_pct, :five_resets, :seven_pct, :seven_resets, :cache_warm, :cache_expires_at

  def initialize(data)
    @data = data
    window = data['context_window'] || {}
    @window_size   = dig_i(window, 'context_window_size')
    @output_tokens = dig_i(window, 'total_output_tokens')
    @ctx           = dig_i(window, 'total_input_tokens') + @output_tokens
    # the payload zeroes context_window around a cache miss; the tokens the next send re-caches are the real size
    @ctx           = dig_i(data, 'prompt_cache', 'recache_tokens_if_cold') if @ctx.zero?
    @cache_created = dig_i(window, 'current_usage', 'cache_creation_input_tokens')
    @cost          = dig_f(data, 'cost', 'total_cost_usd')
    @model_name    = data.dig('model', 'display_name')
    @effort        = data.dig('effort', 'level')
    @cwd           = data.dig('workspace', 'current_dir') || data['cwd'] || Dir.pwd
    @five_pct, @five_resets   = limit_window(data, 'five_hour')
    @seven_pct, @seven_resets = limit_window(data, 'seven_day')
    @cache_warm, @cache_expires_at = prompt_cache(data) # nil when Claude Code reports no cache expiry
  end

  # nil when there are no subscription limits (API key)
  def limits?
    !@data['rate_limits'].nil?
  end

  # Reasoning-quality zones for this model
  def ctx_zones
    @ctx_zones ||= ctx_model(model_name)[:zones]
  end

  # { 0 => :good, 150_000 => :multi_hop, 350_000 => :degraded, 600_000 => :fried }
  def ctx_zone_tiers
    @ctx_zone_tiers ||= ([0] + ctx_zones).zip(CTX_TIER_NAMES).to_h
  end

  # Named tiers for ctx: the model's zones, then :compact once ctx fills
  # CTX_COMPACT_PERCENT of the window (a ceiling: later zones are dropped).
  # { 0 => :good, 150_000 => :multi_hop, ..., 850_000.0 => :compact }
  def ctx_tiers
    @ctx_tiers ||= begin
      tiers = ctx_zone_tiers
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

  def five_expected
    return unless five_resets
    hours = (Time.now - Time.at(five_resets - 5 * 3600)) / 3600
    (hours * 20).clamp(0, 100) # 20% per hour
  end

  def seven_expected
    return unless seven_resets
    days = Time.at(seven_resets - 7 * 86_400).to_date..Time.now.to_date
    [days.count { |d| d.wday.between?(1, 5) } * 20, 100].min # 20% per weekday
  end

  # :wall, :ahead, :on_pace or :behind; no pace known counts as :on_pace
  def five_tier
    limit_tier(five_pct, five_expected)
  end

  def seven_tier
    limit_tier(seven_pct, seven_expected)
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
  "⛁ #{paint(tier, text)}"
end

# Width picks the pieces: 82+ draws bars, 174+ adds ▲▼⚒ $cost and model.
# The ctx number always shows.
def render(data)
  columns = ENV['COLUMNS'].to_i
  bars    = columns >= 82
  extras  = columns >= 174
  session = ClaudeSession.new(data)

  left  = [git_str(session), [context_str(session, bars), cache_str(session)].compact.join(' ')]
  right = []
  right += [turn_str(session), cost_str(session)] if extras
  right << rate_limit_str(session, bars)
  right << "⬢ #{model_str(session)}" if extras

  left, right = [left, right].map { |parts| parts.compact.join('  ') }
  bars && !extras ? "#{left}  #{right}" : justify(left, right) # medium keeps the groups together
end

if __FILE__ == $0
  input = $stdin.read
  # dev only: STATUSLINE_DUMP=/path/file.json saves what Claude Code sends (owner-readable)
  #File.write(ENV['STATUSLINE_DUMP'], input, perm: 0o600) if ENV['STATUSLINE_DUMP']
  data = JSON.parse(input) rescue {}
  puts render(data)
end
