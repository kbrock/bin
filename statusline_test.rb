#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'statusline'

class StatuslineTest < Minitest::Test
  # --- model_level: Sonnet (80k / 200k / 400k) ---
  def test_sonnet_good
    assert_equal 0, model_level(50_000, 'Claude Sonnet 5')
  end

  def test_sonnet_multi_hop
    assert_equal 1, model_level(100_000, 'Claude Sonnet 5')
  end

  def test_sonnet_degraded_zone
    assert_equal 2, model_level(250_000, 'Claude Sonnet 5')
  end

  def test_sonnet_fried
    assert_equal 3, model_level(450_000, 'Claude Sonnet 5')
  end

  # --- model_level: Opus (150k / 350k / 600k) ---
  def test_opus_good
    assert_equal 0, model_level(100_000, 'Claude Opus 5.5')
  end

  def test_opus_multi_hop
    assert_equal 1, model_level(200_000, 'Claude Opus 5.5')
  end

  def test_opus_degraded_zone
    assert_equal 2, model_level(400_000, 'Claude Opus 5.5')
  end

  def test_opus_fried
    assert_equal 3, model_level(650_000, 'Claude Opus 5.5')
  end

  # --- model_level: Qwen Coder (24k / 45k / 85k) ---
  def test_qwen_good
    assert_equal 0, model_level(10_000, 'qwen2.5-coder')
  end

  def test_qwen_fried
    assert_equal 3, model_level(90_000, 'qwen2.5-coder')
  end

  # --- model_level: unrecognized model falls back to the conservative default ---
  def test_unknown_model_uses_fallback_thresholds
    assert_equal 0, model_level(10_000, 'gpt-4')
    assert_equal 3, model_level(160_000, 'gpt-4')
  end

  # --- physical_alert?: 15% free threshold, independent of model ---
  def test_physical_plenty_of_room
    refute physical_alert?(500_000, 1_000_000) # 50% free
  end

  def test_physical_checkpoint_near_boundary
    assert physical_alert?(860_000, 1_000_000) # ~86% used, past the 85% rule-of-thumb line
  end

  def test_physical_not_yet_at_boundary
    refute physical_alert?(800_000, 1_000_000) # 80% used, still under the line
  end

  def test_physical_ignores_zero_window
    refute physical_alert?(500_000, 0)
  end

  # --- ctx_color: physical overrides model, red never becomes bold on its own ---
  def test_color_good_is_uncolored
    assert_equal '', ctx_color(10_000, 'Claude Sonnet 5', 1_000_000)
  end

  def test_color_model_fried_is_plain_red_not_bold
    # ctx=450k trips Sonnet's degraded threshold (400k), but window is huge so plenty of physical room
    assert_equal RED, ctx_color(450_000, 'Claude Sonnet 5', 1_000_000)
  end

  def test_color_physical_checkpoint_overrides_low_model_level
    # ctx=300k is under Opus's degraded (600k) and multi_hop (350k) thresholds -- model_level is only 1 (blue) --
    # but a small window (340k) puts ~88% used, so physical wins and forces bold red
    assert_equal 1, model_level(300_000, 'Claude Opus 5.5')
    assert_equal BOLD_RED, ctx_color(300_000, 'Claude Opus 5.5', 340_000)
  end

  # --- FMT_LEFT: single unit, always rounded UP ---
  def test_fmt_left_rounds_hours_up
    assert_equal '5h', FMT_LEFT[Time.now.to_i + (4 * 3_600 + 56 * 60)] # 4h56m -> 5h
  end

  def test_fmt_left_exact_hour_stays_exact
    assert_equal '3h', FMT_LEFT[Time.now.to_i + 3 * 3_600]
  end

  def test_fmt_left_minutes_only_under_an_hour
    assert_equal '5m', FMT_LEFT[Time.now.to_i + 5 * 60]
  end

  def test_fmt_left_rounds_days_up_on_any_leftover
    assert_equal '6d', FMT_LEFT[Time.now.to_i + (5 * 86_400 + 22 * 3_600)] # 5d22h -> 6d
    assert_equal '6d', FMT_LEFT[Time.now.to_i + (5 * 86_400 + 3_600)]     # 5d1h -> 6d
  end

  def test_fmt_left_exact_days_stays_exact
    assert_equal '5d', FMT_LEFT[Time.now.to_i + 5 * 86_400]
  end

  def test_fmt_left_blank_for_nil_or_past
    assert_equal '', FMT_LEFT[nil]
    assert_equal '', FMT_LEFT[Time.now.to_i - 10]
  end

  # --- FMT_CLOCK: absolute wall-clock, am/pm, optional date ---
  def test_fmt_clock_time_only
    t = Time.new(2026, 9, 24, 20, 8, 0)
    assert_equal '08:08pm', FMT_CLOCK[t.to_i, false]
  end

  def test_fmt_clock_with_date
    t = Time.new(2026, 9, 27, 10, 40, 0)
    assert_equal '9/27 10:40am', FMT_CLOCK[t.to_i, true]
  end

  def test_fmt_clock_blank_for_nil
    assert_equal '', FMT_CLOCK[nil, false]
  end

  # --- rate_limit_str: normal (both under 100%) shows countdown-as-label ---
  def test_rate_limit_shows_both_when_neither_maxed
    data = { 'rate_limits' => {
      'five_hour' => { 'used_percentage' => 42, 'resets_at' => Time.now.to_i + 4 * 3_600 + 56 * 60 },
      'seven_day' => { 'used_percentage' => 5, 'resets_at' => Time.now.to_i + 5 * 86_400 + 22 * 3_600 },
    } }
    assert_equal '5h 42%  6d 5%', rate_limit_str(data)
  end

  def test_rate_limit_nil_when_no_rate_limits_present
    assert_nil rate_limit_str({})
  end

  # --- rate_limit_str: maxed collapses the whole field to "API <clock>" ---
  def test_rate_limit_five_hour_maxed_shows_time_only
    data = { 'rate_limits' => {
      'five_hour' => { 'used_percentage' => 100, 'resets_at' => Time.new(2026, 9, 24, 21, 50, 0).to_i },
      'seven_day' => { 'used_percentage' => 40, 'resets_at' => Time.now.to_i + 4 * 86_400 },
    } }
    assert_equal "#{RED}API 09:50pm#{RESET}", rate_limit_str(data)
  end

  def test_rate_limit_seven_day_maxed_shows_full_date_even_if_today
    data = { 'rate_limits' => {
      'five_hour' => { 'used_percentage' => 30, 'resets_at' => Time.now.to_i + 8_000 },
      'seven_day' => { 'used_percentage' => 103, 'resets_at' => Time.new(2026, 9, 24, 22, 0, 0).to_i },
    } }
    assert_equal "#{RED}API 9/24 10:00pm#{RESET}", rate_limit_str(data)
  end

  def test_rate_limit_both_maxed_seven_day_wins
    five_resets  = Time.now.to_i + 600
    seven_resets = Time.new(2026, 9, 27, 19, 40, 0).to_i
    data = { 'rate_limits' => {
      'five_hour' => { 'used_percentage' => 100, 'resets_at' => five_resets },
      'seven_day' => { 'used_percentage' => 100, 'resets_at' => seven_resets },
    } }
    out = rate_limit_str(data)
    assert_equal "#{RED}API 9/27 07:40pm#{RESET}", out
    refute_includes out, FMT_CLOCK[five_resets, false] # the "moot" 5h reset is not shown at all
  end

  # --- render: smoke test, output shape ---
  def test_render_smoke
    data = {
      'context_window' => {
        'current_usage' => { 'cache_creation_input_tokens' => 200, 'cache_read_input_tokens' => 5000 },
        'total_input_tokens' => 5210, 'total_output_tokens' => 300, 'context_window_size' => 1_000_000
      },
      'cost' => { 'total_cost_usd' => 0.42 },
      'model' => { 'display_name' => 'Claude Sonnet 5' },
      'prompt_cache' => { 'warm' => true, 'expires_at' => Time.now.to_i + 300 }
    }
    out = render(data)
    assert_includes out, 'ctx'
    assert_includes out, '$0.42'
    assert_includes out, '⛃'
  end

  # --- render: hist:turn actually reflects the dragged-history ratio ---
  def test_render_hist_turn_ratio_math
    # ctx (turn_in+turn_out) = 10_000; turn (tool_in+turn_out) = 300 -> (10000-300)/300 = 32 (floor)
    data = {
      'context_window' => {
        'current_usage' => { 'cache_creation_input_tokens' => 100, 'cache_read_input_tokens' => 9_700 },
        'total_input_tokens' => 9_800, 'total_output_tokens' => 200, 'context_window_size' => 1_000_000
      },
      'cost' => { 'total_cost_usd' => 0.42 },
      'model' => { 'display_name' => 'Claude Sonnet 5' }
    }
    assert_includes render(data), "hist:turn #{RED}32:1#{RESET}"
  end

  # --- render: cache hit/miss coloring ---
  def test_render_cache_hit_is_blue
    data = {
      'context_window' => {
        'current_usage' => { 'cache_creation_input_tokens' => 200, 'cache_read_input_tokens' => 5000 },
        'total_input_tokens' => 5210, 'total_output_tokens' => 300, 'context_window_size' => 1_000_000
      },
      'cost' => { 'total_cost_usd' => 0.42 },
      'model' => { 'display_name' => 'Claude Sonnet 5' },
      'prompt_cache' => { 'warm' => true, 'expires_at' => Time.now.to_i + 300 }
    }
    out = render(data)
    assert_includes out, "#{BLUE}⛃"
    refute_includes out, "#{RED}⛃"
  end

  def test_render_cache_miss_is_plain_red_not_bold
    data = {
      'context_window' => {
        'current_usage' => { 'cache_creation_input_tokens' => 4000, 'cache_read_input_tokens' => 0 },
        'total_input_tokens' => 4000, 'total_output_tokens' => 300, 'context_window_size' => 1_000_000
      },
      'cost' => { 'total_cost_usd' => 0.42 },
      'model' => { 'display_name' => 'Claude Sonnet 5' },
      'prompt_cache' => { 'warm' => false, 'expires_at' => Time.now.to_i + 300 }
    }
    out = render(data)
    assert_includes out, "#{RED}⛃"
    refute_includes out, "#{BOLD_RED}⛃"
  end

  def test_render_cache_color_falls_back_to_token_heuristic_without_warm_key
    # prompt_cache present (so the expiry clock renders) but with no explicit
    # 'warm' key -- color falls back to comparing cache_read vs cache_creation
    data = {
      'context_window' => {
        'current_usage' => { 'cache_creation_input_tokens' => 200, 'cache_read_input_tokens' => 5000 },
        'total_input_tokens' => 5210, 'total_output_tokens' => 300, 'context_window_size' => 1_000_000
      },
      'cost' => { 'total_cost_usd' => 0.42 },
      'model' => { 'display_name' => 'Claude Sonnet 5' },
      'prompt_cache' => { 'expires_at' => Time.now.to_i + 300 }
    }
    out = render(data)
    assert_includes out, "#{BLUE}⛃"
  end

  def test_render_shows_cache_expiry_as_clock_time
    expires_at = Time.now.to_i + 300
    data = {
      'context_window' => {
        'current_usage' => { 'cache_creation_input_tokens' => 200, 'cache_read_input_tokens' => 5000 },
        'total_input_tokens' => 5210, 'total_output_tokens' => 300, 'context_window_size' => 1_000_000
      },
      'cost' => { 'total_cost_usd' => 0.42 },
      'model' => { 'display_name' => 'Claude Sonnet 5' },
      'prompt_cache' => { 'warm' => true, 'expires_at' => expires_at }
    }
    assert_includes render(data), "⛃ #{FMT_CLOCK[expires_at, false]}"
  end

  def test_render_shows_expired_when_cache_already_past
    data = {
      'context_window' => {
        'current_usage' => { 'cache_creation_input_tokens' => 5000, 'cache_read_input_tokens' => 0 },
        'total_input_tokens' => 5000, 'total_output_tokens' => 200, 'context_window_size' => 1_000_000
      },
      'cost' => { 'total_cost_usd' => 0.50 },
      'model' => { 'display_name' => 'Claude Sonnet 5' },
      'prompt_cache' => { 'warm' => false, 'expires_at' => Time.now.to_i - 10 }
    }
    assert_includes render(data), 'EXPIRED'
  end

  def test_render_omits_cache_line_when_absent
    data = {
      'context_window' => {
        'current_usage' => { 'cache_creation_input_tokens' => 200, 'cache_read_input_tokens' => 5000 },
        'total_input_tokens' => 5210, 'total_output_tokens' => 300, 'context_window_size' => 1_000_000
      },
      'cost' => { 'total_cost_usd' => 0.42 },
      'model' => { 'display_name' => 'Claude Sonnet 5' }
    }
    refute_includes render(data), '⛃'
  end

  # --- render: rate limits end-to-end, including the API-maxed collapse ---
  def test_render_includes_rate_limits
    data = {
      'context_window' => {
        'current_usage' => { 'cache_creation_input_tokens' => 200, 'cache_read_input_tokens' => 5000 },
        'total_input_tokens' => 5210, 'total_output_tokens' => 300, 'context_window_size' => 1_000_000
      },
      'cost' => { 'total_cost_usd' => 0.42 },
      'model' => { 'display_name' => 'Claude Sonnet 5' },
      'rate_limits' => {
        'five_hour' => { 'used_percentage' => 42, 'resets_at' => Time.now.to_i + 4 * 3_600 + 56 * 60 },
        'seven_day' => { 'used_percentage' => 5, 'resets_at' => Time.now.to_i + 5 * 86_400 + 22 * 3_600 },
      }
    }
    assert_includes render(data), '5h 42%  6d 5%'
  end

  def test_render_shows_api_when_seven_day_maxed
    data = {
      'context_window' => {
        'current_usage' => { 'cache_creation_input_tokens' => 200, 'cache_read_input_tokens' => 5000 },
        'total_input_tokens' => 5210, 'total_output_tokens' => 300, 'context_window_size' => 1_000_000
      },
      'cost' => { 'total_cost_usd' => 0.42 },
      'model' => { 'display_name' => 'Claude Sonnet 5' },
      'rate_limits' => {
        'five_hour' => { 'used_percentage' => 30, 'resets_at' => Time.now.to_i + 8_000 },
        'seven_day' => { 'used_percentage' => 100, 'resets_at' => Time.new(2026, 9, 27, 10, 40, 0).to_i },
      }
    }
    out = render(data)
    assert_includes out, 'API 9/27 10:40am'
    refute_includes out, '30%' # 5h percentage is dropped once 7d is the blocker
  end
end
