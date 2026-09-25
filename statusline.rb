#!/usr/bin/env ruby
require 'json'

# Statusline — where's my cost/context going, and do I need to adjust?
#
#   ▲up ▼down    tokens used this turn
#   $cost        session API cost (not real billing on subscription)
#   ctx          context size; none/blue/yellow/red = model-degradation risk,
#                bold red = 85% of context window (compaction imminent)
#   hist:turn    history dragged along per token of new work this turn;
#                high = paying to carry a fat context for a small action
#   5h/7d        subscription rate-limit usage; label IS the reset countdown.
#                Either hitting 100% collapses this to "API <clock>" — you're
#                on pay-as-you-go until then (7d wins if both are maxed)
#   ⛃time       prompt-cache expiry; blue=warm hit, red=missed/expired

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

BLUE, YELLOW, RED, BOLD_RED, RESET = "\e[34m", "\e[33m", "\e[31m", "\e[1;31m", "\e[0m"

def color_limits(v, str, yellow, red, low = '')
  color = v >= red ? RED : v >= yellow ? YELLOW : low
  color.empty? ? str : "#{color}#{str}#{RESET}"
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

def rate_limit_str(data)
  five_pct     = data.dig('rate_limits', 'five_hour', 'used_percentage')
  five_resets  = data.dig('rate_limits', 'five_hour', 'resets_at')
  seven_pct    = data.dig('rate_limits', 'seven_day', 'used_percentage')
  seven_resets = data.dig('rate_limits', 'seven_day', 'resets_at')
  return nil unless five_pct || seven_pct

  five_maxed  = five_pct && five_pct >= 100
  seven_maxed = seven_pct && seven_pct >= 100

  if five_maxed || seven_maxed
    # Subscription usage is blocked — you're on API billing (Usage Credits,
    # if enabled) until this clears. 7d always wins here: even if 5h resets
    # in the meantime, you're still gated by 7d, so that's the only reset
    # worth knowing about. Percentage is dropped — it's just 100%, not info.
    clock = seven_maxed ? FMT_CLOCK[seven_resets, true] : FMT_CLOCK[five_resets, false]
    return "#{RED}API #{clock}#{RESET}"
  end

  parts = []
  if five_pct
    label = FMT_LEFT[five_resets]
    label = '5h' if label.empty?
    parts << color_limits(five_pct, "#{label} #{five_pct.round}%", 70, 90)
  end
  if seven_pct
    label = FMT_LEFT[seven_resets]
    label = '7d' if label.empty?
    parts << color_limits(seven_pct, "#{label} #{seven_pct.round}%", 70, 90)
  end
  parts.join('  ')
end

def render(data)
  cw = data['context_window'] || {}
  cu = cw['current_usage'] || {}

  tool_in    = dig_i(cu, 'cache_creation_input_tokens')
  cache_in   = dig_i(cu, 'cache_read_input_tokens')
  turn_in    = dig_i(cw, 'total_input_tokens')
  turn_out   = dig_i(cw, 'total_output_tokens')
  cost       = dig_f(data, 'cost', 'total_cost_usd')
  ctx_max    = dig_i(cw, 'context_window_size')
  model_name = data.dig('model', 'display_name')

  ctx   = turn_in + turn_out
  turn  = tool_in + turn_out
  ratio = turn > 0 ? [ctx - turn, 0].max / turn : 0

  color = ctx_color(ctx, model_name, ctx_max)
  ctx_str = color.empty? ? "ctx #{FMT[ctx]}" : "#{color}ctx #{FMT[ctx]}#{RESET}"
  ratio_str = color_limits(ratio, "#{ratio}:1", 10, 20)
  rate_str = rate_limit_str(data)

  pc = data['prompt_cache']
  warm = pc && pc.key?('warm') ? pc['warm'] : cache_in > tool_in
  cache_color = warm ? BLUE : RED

  line = "▲#{FMT[tool_in]}  ▼#{FMT[turn_out]} | $#{format('%.2f', cost)}" \
         "  │  #{ctx_str}  hist:turn #{ratio_str}"
  line += "  │  #{rate_str}" if rate_str

  if pc && pc['expires_at']
    remaining = pc['expires_at'] - Time.now.to_i
    if remaining > 0
      line += "  │  #{cache_color}⛃ #{FMT_CLOCK[pc['expires_at'], false]}#{RESET}"
    else
      line += "  │  #{cache_color}⛃ EXPIRED#{RESET}"
    end
  end
  line
end

if __FILE__ == $0
  data = JSON.parse($stdin.read) rescue {}
  puts render(data)
end
