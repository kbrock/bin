#!/usr/bin/env ruby
require 'json'
require 'date'

# Statusline — where's my cost/context going, and do I need to adjust?
#
#   ▲up ▼down    tokens for this whole turn: your prompt plus every tool
#                round-trip (summed from the transcript). ▲ = new input
#                (uncached + cache writes), ▼ = output. Falls back to the
#                last API request when the transcript can't be read.
#                ▲ blue/red = the turn's first send hit/missed the cache
#                (tool round-trips are seconds apart, so they're always warm)
#   $cost        session API cost (not real billing on subscription)
#   ctx          context size; none/blue/yellow/red = model-degradation risk,
#                bold red = 85% of context window (compaction imminent)
#   5h/7d        subscription rate-limit usage; label IS the reset countdown.
#                Either hitting 100% collapses this to "API <clock>" — you're
#                on pay-as-you-go until then (7d wins if both are maxed)
#                7d pace: 10% per weekday half-day (10am-3pm, 3pm-8pm) so far;
#                purple = ahead of pace, green = 2+ half-days behind (use more)
#   ⛃time       prompt-cache expiry; blue=still warm, red=expired (next send misses)

def dig_i(h, *path)
  (h.dig(*path) || 0).to_i
end

def dig_f(h, *path)
  (h.dig(*path) || 0).to_f
end

FMT = ->(n) { n >= 1000 ? format('%.1fk', n / 1000.0) : n.to_s }

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

MODEL_COLORS = ['', BLUE, YELLOW, RED].freeze

# Reasoning-quality zone by model. Sonnet 5.5 vs Opus 5.5
def model_level(ctx, model_name)
  name = model_name.to_s.downcase

  good_max, multi_hop, degraded =
    case name
    when /opus/i
      [150_000, 350_000, 600_000]
    when /sonnet/i
      [80_000, 200_000, 400_000]
    when /qwen.*coder/i
      [24_000, 45_000, 85_000]
    else
      [32_000, 80_000, 150_000] # Fallback
    end

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

# purple = ahead of pace, green = 2+ half-days behind
def seven_day_color(pct, resets_at)
  allowance = seven_day_allowance(resets_at)
  pct > allowance ? PURPLE : pct < allowance - 20 ? GREEN : ''
end

def limit_label(pct, resets, fallback)
  label = FMT_LEFT[resets]
  label = fallback if label.empty?
  "#{label} #{pct.round}%"
end

def rate_limit_str(data)
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

  seven_str = paint(seven_day_color(seven_pct, seven_resets), limit_label(seven_pct, seven_resets, '7d'))
  "#{limit_label(five_pct, five_resets, '5h')}  #{seven_str}"
end

# Only the tail is read: the statusline re-runs often and transcripts grow large
TRANSCRIPT_TAIL = 4 * 1024 * 1024

# {up:, down:, warm:} summed over every API request for the current prompt;
# nil if the transcript or this prompt's first send isn't found.
def turn_usage(data)
  path, pid = data['transcript_path'], data['prompt_id']
  return nil unless path && pid && File.file?(path)

  lines = File.open(path) do |f|
    f.seek([f.size - TRANSCRIPT_TAIL, 0].max)
    f.read.lines
  end
  seen, cur, turn = {}, nil, nil
  lines.each do |l|
    j = JSON.parse(l) rescue next # first line may be cut off by the seek
    next if j['isSidechain']
    cur = j['promptId'] if j['type'] == 'user' && j['promptId']
    next unless cur == pid && j['type'] == 'assistant'
    u = j.dig('message', 'usage')
    id = j.dig('message', 'id')
    next if !u || seen[id] # one response can span several entries
    seen[id] = true
    # first send of the turn: the only one that can find the cache cold
    turn ||= { up: 0, down: 0, warm: dig_i(u, 'cache_read_input_tokens') > dig_i(u, 'cache_creation_input_tokens') }
    turn[:up]   += dig_i(u, 'input_tokens') + dig_i(u, 'cache_creation_input_tokens')
    turn[:down] += dig_i(u, 'output_tokens')
  end
  turn
end

# ▲▼ $  │  ctx — these share tokens, so they're built together
# ▲ blue = turn's first send hit a warm cache, red = cold (paid full price to re-send)
def usage_str(data, warm)
  cw = data['context_window'] || {}
  cu = cw['current_usage'] || {}

  tool_in    = dig_i(cu, 'cache_creation_input_tokens')
  turn_in    = dig_i(cw, 'total_input_tokens')
  turn_out   = dig_i(cw, 'total_output_tokens')
  if (turn = turn_usage(data))
    tool_in, down, warm = turn[:up], turn[:down], turn[:warm]
  else
    down = turn_out
  end
  ctx_max    = dig_i(cw, 'context_window_size')
  cost       = dig_f(data, 'cost', 'total_cost_usd')
  model_name = data.dig('model', 'display_name')

  ctx = turn_in + turn_out

  ctx_str  = paint(ctx_color(ctx, model_name, ctx_max), "ctx #{FMT[ctx]}")
  up_str   = paint(warm.nil? ? '' : warm ? BLUE : RED, "▲#{FMT[tool_in]}")
  down_str = paint(PURPLE, "▼#{FMT[down]}")
  "#{up_str}  #{down_str} | $#{format('%.2f', cost)}  │  #{ctx_str}"
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

def render(data)
  warm, expires_at = prompt_cache(data)

  line = usage_str(data, warm)

  rate_str = rate_limit_str(data)
  line += "  │  #{rate_str}" if rate_str

  if expires_at
    remaining = expires_at - Time.now.to_i
    if remaining > 0
      line += "  │  #{paint(BLUE, "⛃ #{FMT_CLOCK[expires_at, false]}")}"
    else
      line += "  │  #{paint(RED, '⛃ EXPIRED')}"
    end
  end
  line
end

if __FILE__ == $0
  data = JSON.parse($stdin.read) rescue {}
  puts render(data)
end
