#!/usr/bin/env ruby
require 'minitest/autorun'
require 'minitest/mock'
require 'tempfile'
require_relative 'statusline'

class StatuslineTest < Minitest::Test
  # render picks a layout from COLUMNS: large (174+) unless a test says otherwise
  def setup
    @columns = ENV['COLUMNS']
    ENV['COLUMNS'] = '200'
  end

  def teardown
    ENV['COLUMNS'] = @columns
  end

  def plain(str)
    str.gsub(ANSI, '')
  end

  # 7d pace coloring depends on the day, so rate-limit tests pin the clock.
  # Monday 11am with a 5d22h reset: the window started Sunday 9am, so one
  # weekday half-day has passed (10% allowance) and 5% is on pace (uncolored).
  def on_pace_monday
    now = Time.local(2026, 9, 28, 11)
    Time.stub(:now, now) { yield now.to_i }
  end

  # --- calc_tier: the last lower bound at or below the value ---
  TIERS = { 0 => :good, 80_000 => :multi_hop, 200_000 => :degraded }.freeze

  def test_calc_tier_first_tier_covers_zero_up_to_the_next_bound
    assert_equal :good, calc_tier(0, TIERS)
    assert_equal :good, calc_tier(79_999, TIERS)
  end

  def test_calc_tier_a_bound_belongs_to_the_tier_it_starts
    assert_equal :multi_hop, calc_tier(80_000, TIERS)
    assert_equal :degraded, calc_tier(200_000, TIERS)
  end

  def test_calc_tier_past_the_last_bound_stays_in_the_last_tier
    assert_equal :degraded, calc_tier(5_000_000, TIERS)
  end

  def test_calc_tier_nil_below_the_first_bound
    assert_nil calc_tier(-1, TIERS)
  end

  def test_calc_tier_negative_bounds_and_unsorted_input
    pace = { 10 => :ahead, -10 => :behind, 0 => :on_pace }
    assert_equal :behind, calc_tier(-5, pace)
    assert_equal :on_pace, calc_tier(5, pace)
    assert_equal :ahead, calc_tier(10, pace)
  end

  # --- paint: no color means plain text ---
  def test_paint_nil_color_is_plain
    assert_equal 'x', paint(nil, 'x')
    assert_equal 'x', paint('', 'x')
    assert_equal "#{RED}x#{RESET}", paint(RED, 'x')
  end

  # --- ctx_tier: the model's zones by name, :compact past 85% of the window ---
  def ctx_tier_for(ctx, model = 'Claude Sonnet 5', window = 1_000_000)
    ClaudeSession.new('context_window' => { 'total_input_tokens' => ctx, 'context_window_size' => window },
                      'model' => { 'display_name' => model }).ctx_tier
  end

  def test_ctx_tier_sonnet_zones
    assert_equal :good, ctx_tier_for(50_000)
    assert_equal :multi_hop, ctx_tier_for(100_000)
    assert_equal :degraded, ctx_tier_for(250_000)
    assert_equal :fried, ctx_tier_for(450_000)
  end

  def test_ctx_tier_opus_zones
    assert_equal :good, ctx_tier_for(100_000, 'Claude Opus 5.5')
    assert_equal :degraded, ctx_tier_for(400_000, 'Claude Opus 5.5')
  end

  def test_ctx_tier_unknown_model_uses_fallback_zones
    assert_equal :good, ctx_tier_for(10_000, 'gpt-4')
    assert_equal :fried, ctx_tier_for(160_000, 'gpt-4')
  end

  def test_ctx_tier_compact_starts_at_85_percent
    assert_equal :fried, ctx_tier_for(849_999)
    assert_equal :compact, ctx_tier_for(850_000)
    assert_equal :compact, ctx_tier_for(860_000)
  end

  def test_ctx_tier_compact_is_a_ceiling_over_later_zones
    # Opus degraded starts at 350k, but compact (340k of a 400k window) comes first
    assert_equal :compact, ctx_tier_for(345_000, 'Claude Opus 5.5', 400_000)
    session = ClaudeSession.new('context_window' => { 'context_window_size' => 400_000 },
                                'model' => { 'display_name' => 'Claude Opus 5.5' })
    assert_equal %i[good multi_hop compact], session.ctx_tiers.values
  end

  def test_ctx_tier_without_a_window_size_has_no_compact
    assert_equal %i[good multi_hop degraded fried], ClaudeSession.new('model' => { 'display_name' => 'Claude Opus 5.5' }).ctx_tiers.values
    assert_equal :fried, ctx_tier_for(5_000_000, 'Claude Opus 5.5', 0)
  end

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

  # --- THEME: a fried context is plain red, only :compact is bold ---
  def test_theme_colors_for_the_context_tiers
    assert_equal GREEN, THEME[:good]
    assert_equal RED, THEME[:fried]
    assert_equal BOLD_RED, THEME[:compact]
  end

  def test_ctx_icon_is_bold_red_once_compact
    data = { 'context_window' => { 'total_input_tokens' => 860_000, 'context_window_size' => 1_000_000 },
             'model' => { 'display_name' => 'Opus 5.5' } }
    assert_includes render(data), "#{BOLD_RED}▣"
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
    on_pace_monday do |now|
      data = { 'rate_limits' => {
        'five_hour' => { 'used_percentage' => 42, 'resets_at' => now + 4 * 3_600 + 56 * 60 },
        'seven_day' => { 'used_percentage' => 5, 'resets_at' => now + 5 * 86_400 + 22 * 3_600 },
      } }
      assert_equal '◷ 5h 42%  ◷ 6d  5%', plain(rate_limit_str(ClaudeSession.new(data)))
    end
  end

  def test_rate_limit_nil_when_no_rate_limits_present
    assert_nil rate_limit_str(ClaudeSession.new({}))
  end

  # --- rate_limit_str: maxed collapses the whole field to "API <clock>" ---
  def test_rate_limit_five_hour_maxed_shows_time_only
    data = { 'rate_limits' => {
      'five_hour' => { 'used_percentage' => 100, 'resets_at' => Time.new(2026, 9, 24, 21, 50, 0).to_i },
      'seven_day' => { 'used_percentage' => 40, 'resets_at' => Time.now.to_i + 4 * 86_400 },
    } }
    assert_equal "#{RED}API 09:50pm#{RESET}", rate_limit_str(ClaudeSession.new(data))
  end

  def test_rate_limit_seven_day_maxed_shows_full_date_even_if_today
    data = { 'rate_limits' => {
      'five_hour' => { 'used_percentage' => 30, 'resets_at' => Time.now.to_i + 8_000 },
      'seven_day' => { 'used_percentage' => 103, 'resets_at' => Time.new(2026, 9, 24, 22, 0, 0).to_i },
    } }
    assert_equal "#{RED}API 9/24 10:00pm#{RESET}", rate_limit_str(ClaudeSession.new(data))
  end

  def test_rate_limit_both_maxed_seven_day_wins
    five_resets  = Time.now.to_i + 600
    seven_resets = Time.new(2026, 9, 27, 19, 40, 0).to_i
    data = { 'rate_limits' => {
      'five_hour' => { 'used_percentage' => 100, 'resets_at' => five_resets },
      'seven_day' => { 'used_percentage' => 100, 'resets_at' => seven_resets },
    } }
    out = rate_limit_str(ClaudeSession.new(data))
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
    assert_includes out, '▣'
    assert_includes out, '$0.42'
    assert_includes out, '⛁'
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
    assert_includes out, "#{BLUE}▲200"
    refute_includes out, "#{RED}▲"
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
    assert_includes out, "#{RED}▲4.0k"
    refute_includes out, "#{BOLD_RED}▲"
    assert_includes out, "⛁ #{GREEN}" # ⛁ is colored by expiry time, not by the miss
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
    assert_includes out, "#{BLUE}▲200"
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
    assert_includes render(data), "⛁ #{GREEN}#{FMT_CLOCK[expires_at, false]}"
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
    out = render(data)
    assert_includes out, "#{RED}EXPIRED"
    assert_includes out, "#{GREEN}▣" # the bar keeps its zone color; only the clock is red
    refute_includes out, "#{RED}▰"
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
    refute_includes render(data), '⛁'
  end

  # --- render: rate limits end-to-end, including the API-maxed collapse ---
  def test_render_includes_rate_limits
    on_pace_monday do |now|
      data = {
        'context_window' => {
          'current_usage' => { 'cache_creation_input_tokens' => 200, 'cache_read_input_tokens' => 5000 },
          'total_input_tokens' => 5210, 'total_output_tokens' => 300, 'context_window_size' => 1_000_000
        },
        'cost' => { 'total_cost_usd' => 0.42 },
        'model' => { 'display_name' => 'Claude Sonnet 5' },
        'rate_limits' => {
          'five_hour' => { 'used_percentage' => 42, 'resets_at' => now + 4 * 3_600 + 56 * 60 },
          'seven_day' => { 'used_percentage' => 5, 'resets_at' => now + 5 * 86_400 + 22 * 3_600 },
        }
      }
      assert_includes plain(render(data)), '◷ 5h  ▰▰▱▱▱  ◷ 6d  ▰▱▱▱▱'
    end
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

  # --- turn_usage: ▲▼ summed over the whole turn from the transcript ---
  def transcript(*entries)
    f = Tempfile.new(['transcript', '.jsonl'])
    entries.each { |e| f.puts(e.to_json) }
    f.close
    (@tempfiles ||= []) << f
    f.path
  end

  def prompt(id, sidechain: false)
    { 'type' => 'user', 'promptId' => id, 'isSidechain' => sidechain }
  end

  def reply(id, new_in, read, out, uncached: 2)
    { 'type' => 'assistant', 'message' => { 'id' => id, 'usage' => {
      'input_tokens' => uncached, 'cache_creation_input_tokens' => new_in,
      'cache_read_input_tokens' => read, 'output_tokens' => out } } }
  end

  def test_turn_usage_sums_prompt_and_tool_round_trips
    path = transcript(
      prompt('p1'), reply('m1', 300, 40_000, 100),
      prompt('p1'), reply('m2', 5_000, 40_300, 200), # tool result
      prompt('p1'), reply('m3', 700, 45_300, 50)
    )
    turn = turn_usage('transcript_path' => path, 'prompt_id' => 'p1')
    assert_equal({ up: 6_006, down: 350, warm: true, tools: 0 }, turn)
  end

  def test_turn_usage_counts_tool_calls_across_split_entries
    call = ->(id, tool) { reply(id, 1, 1, 1).tap { |r| r['message']['content'] = [{ 'type' => 'tool_use', 'id' => tool }] } }
    path = transcript(
      prompt('p1'), call['m1', 't1'], call['m1', 't2'],        # two parallel calls in one response
      prompt('p1'), call['m2', 't3'], call['m2', 't3'],        # duplicate entry of the same call
      prompt('p1'), reply('m3', 1, 1, 1)                        # final answer, no tools
    )
    assert_equal 3, turn_usage('transcript_path' => path, 'prompt_id' => 'p1')[:tools]
  end

  def test_turn_usage_counts_a_response_split_over_entries_once
    path = transcript(prompt('p1'), reply('m1', 300, 40_000, 100), reply('m1', 300, 40_000, 100))
    assert_equal 302, turn_usage('transcript_path' => path, 'prompt_id' => 'p1')[:up]
  end

  def test_turn_usage_ignores_other_prompts_and_sidechains
    path = transcript(
      prompt('p0'), reply('m0', 9_000, 0, 900),
      prompt('p1'), reply('m1', 300, 40_000, 100),
      prompt('p1', sidechain: true), reply('m2', 8_000, 0, 800).merge('isSidechain' => true),
      prompt('p2'), reply('m3', 7_000, 0, 700)
    )
    assert_equal({ up: 302, down: 100, warm: true, tools: 0 }, turn_usage('transcript_path' => path, 'prompt_id' => 'p1'))
  end

  def test_turn_usage_cold_first_send_is_not_masked_by_warm_tool_calls
    path = transcript(
      prompt('p1'), reply('m1', 40_000, 0, 100),      # cache expired before the prompt
      prompt('p1'), reply('m2', 500, 40_000, 200)     # tool round-trip seconds later: warm
    )
    refute turn_usage('transcript_path' => path, 'prompt_id' => 'p1')[:warm]
  end

  def test_turn_usage_nil_without_transcript_or_matching_prompt
    assert_nil turn_usage({})
    assert_nil turn_usage('transcript_path' => '/nonexistent.jsonl', 'prompt_id' => 'p1')
    assert_nil turn_usage('transcript_path' => transcript(prompt('p0'), reply('m0', 1, 1, 1)), 'prompt_id' => 'p1')
  end

  def test_turn_usage_skips_line_cut_off_by_the_tail_seek
    path = transcript(prompt('p1'), reply('m1', 300, 40_000, 100))
    File.write(path, "{\"type\":\"assist\n" + File.read(path))
    assert_equal 302, turn_usage('transcript_path' => path, 'prompt_id' => 'p1')[:up]
  end

  def test_render_uses_turn_totals_and_first_send_color
    data = {
      'context_window' => {
        'current_usage' => { 'cache_creation_input_tokens' => 500, 'cache_read_input_tokens' => 40_000 },
        'total_input_tokens' => 40_502, 'total_output_tokens' => 200, 'context_window_size' => 1_000_000
      },
      'model' => { 'display_name' => 'Claude Sonnet 5' },
      'transcript_path' => transcript(prompt('p1'), reply('m1', 40_000, 0, 100), prompt('p1'), reply('m2', 500, 40_000, 200)),
      'prompt_id' => 'p1'
    }
    out = render(data)
    assert_includes out, "#{RED}▲40k"
    assert_includes out, "▼300#{RESET} ⚒0"
  end

  def test_render_falls_back_to_last_request_without_transcript
    data = {
      'context_window' => {
        'current_usage' => { 'cache_creation_input_tokens' => 500, 'cache_read_input_tokens' => 40_000 },
        'total_input_tokens' => 40_502, 'total_output_tokens' => 200, 'context_window_size' => 1_000_000
      },
      'model' => { 'display_name' => 'Claude Sonnet 5' },
      'prompt_id' => 'p1'
    }
    out = render(data)
    assert_includes out, "▲500"
    assert_includes out, "▼200#{RESET} ⚒0"
  end

  # --- layouts: chosen by COLUMNS alone ---
  def layout_data
    {
      'context_window' => { 'total_input_tokens' => 210_000, 'context_window_size' => 1_000_000 },
      'cost' => { 'total_cost_usd' => 1.5 },
      'model' => { 'display_name' => 'Sonnet 5' },
      'rate_limits' => {
        'five_hour' => { 'used_percentage' => 40, 'resets_at' => Time.now.to_i + 7_000 },
        'seven_day' => { 'used_percentage' => 20, 'resets_at' => Time.now.to_i + 200_000 },
      }
    }
  end

  def test_large_layout_shows_everything
    ENV['COLUMNS'] = '174'
    out = plain(render(layout_data))
    assert_includes out, '▰▰▰▰▰▱▱▱▱▱▱▱ 210.0k'
    assert_includes out, '▲0 ▼0 ⚒0'
    assert_includes out, '$1.50'
    assert_includes out, '⬢ Sonnet'
    assert_equal 174 - RIGHT_MARGIN, out.length # right group is pushed to the edge
  end

  def test_medium_layout_has_bars_only
    ENV['COLUMNS'] = '173'
    out = plain(render(layout_data))
    assert_includes out, '▣ ▰▰▰▰▰▱▱▱▱▱▱▱  ◷ 2h  ▰▰▱▱▱  ◷ 3d  ▰▱▱▱▱'
    %w[210.0k ▲ ▼ ⚒ $1.50 ⬢].each { |hidden| refute_includes out, hidden }
    assert out.length < 80, 'right group stays next to the left, not at the edge'
  end

  def test_medium_starts_at_82_columns
    ENV['COLUMNS'] = '82'
    assert_includes plain(render(layout_data)), '▰▰▰▰▰▱▱▱▱▱▱▱'
  end

  def test_small_layout_has_size_and_percentages_only
    ENV['COLUMNS'] = '81'
    out = plain(render(layout_data))
    assert_includes out, '▣ 210.0k'
    assert_includes out, '◷ 2h 40%  ◷ 3d 20%'
    %w[▰ ▲ $1.50 ⬢].each { |hidden| refute_includes out, hidden }
    assert_equal 81 - RIGHT_MARGIN, out.length
  end

  def test_small_percentage_spacing_follows_digit_count
    ENV['COLUMNS'] = '81'
    data = layout_data
    data['rate_limits']['five_hour']['used_percentage'] = 5
    assert_includes plain(render(data)), '◷ 2h  5%  ◷ 3d 20%'
  end

  def test_cost_and_model_are_muted
    out = render(layout_data)
    assert_includes out, "#{MUTED}$1.50#{RESET}"
    assert_includes out, "#{MUTED}Sonnet#{RESET}"
  end

  # --- cache clock: green, turquoise under CACHE_LOW_SECS, red once expired ---
  def cache_expiring(at)
    ClaudeSession.new('prompt_cache' => { 'expires_at' => at })
  end

  def test_cache_clock_says_expired_once_past
    assert_includes cache_str(cache_expiring(Time.now.to_i - 5)), "#{RED}EXPIRED"
  end

  def test_cache_clock_turns_turquoise_under_two_minutes
    soon = Time.now.to_i + 60
    assert_includes cache_str(cache_expiring(soon)), "#{TURQUOISE}#{FMT_CLOCK[soon, false]}"
  end

  def test_cache_clock_is_green_with_time_left
    later = Time.now.to_i + 600
    assert_includes cache_str(cache_expiring(later)), "#{GREEN}#{FMT_CLOCK[later, false]}"
  end

  def test_ctx_icon_takes_the_zone_color
    data = layout_data # 210k on Sonnet is the yellow zone
    assert_includes render(data), "#{YELLOW}▣"
  end

  # --- render: whole-line snapshots ---
  # Everything on screen for one fixed input: Opus, 120k ctx, warm cache, 5h at
  # 40% (3h left, on pace), 7d at 5% (Monday 11am). Colors show as {name} tags.
  # These pin the output across refactors of how the line is built.
  SNAPSHOT_COLORS = {
    BLUE => 'blue', YELLOW => 'yellow', RED => 'red', BOLD_RED => 'bold_red', PURPLE => 'purple',
    GREEN => 'green', BRIGHT_GREEN => 'bright_green', DIM_GREEN => 'dim_green', MUTED => 'muted',
    TURQUOISE => 'turquoise', RESET => ''
  }.freeze

  def tagged(str)
    str.gsub(/\e\[[0-9;]*m/) { |c| SNAPSHOT_COLORS.key?(c) ? (SNAPSHOT_COLORS[c].empty? ? '' : "{#{SNAPSHOT_COLORS[c]}}") : c.inspect }
  end

  def snapshot_line(columns)
    ENV['COLUMNS'] = columns.to_s
    on_pace_monday do |now|
      data = {
        'workspace' => { 'current_dir' => Dir.tmpdir }, # not a git repo
        'context_window' => {
          'current_usage' => { 'cache_creation_input_tokens' => 200, 'cache_read_input_tokens' => 5000 },
          'total_input_tokens' => 120_000, 'total_output_tokens' => 300, 'context_window_size' => 1_000_000
        },
        'cost' => { 'total_cost_usd' => 0.42 },
        'model' => { 'display_name' => 'Opus 5.5' }, 'effort' => { 'level' => 'xhigh' },
        'prompt_cache' => { 'warm' => true, 'expires_at' => now + 300 },
        'rate_limits' => {
          'five_hour' => { 'used_percentage' => 40, 'resets_at' => now + 3 * 3600 },
          'seven_day' => { 'used_percentage' => 5, 'resets_at' => now + 5 * 86_400 + 22 * 3600 }
        }
      }
      tagged(render(data))
    end
  end

  def test_snapshot_large
    expected = '{green}▣ {green}▰{green}▰{green}▱{blue}▱{blue}▱{blue}▱{blue}▱{yellow}▱{yellow}▱{yellow}▱{yellow}▱{yellow}▱{red}▱{red}▱' \
               '{green} 120.3k ⛁ {green}11:05am <gap> {blue}▲200 {purple}▼300 ⚒0  {muted}$0.42  ' \
               '◷ 3h  {green}▰{green}▰{dim_green}▱{dim_green}▱{dim_green}▱  ◷ 6d  {green}▰{dim_green}▱{dim_green}▱{dim_green}▱{dim_green}▱  ⬢ {muted}Opus {red}⇑'
    assert_equal expected, snapshot_line(174).sub(/ {10,}/, ' <gap> ')
  end

  def test_snapshot_medium
    expected = '{green}▣ {green}▰{green}▰{green}▱{blue}▱{blue}▱{blue}▱{blue}▱{yellow}▱{yellow}▱{yellow}▱{yellow}▱{yellow}▱{red}▱{red}▱ ' \
               '⛁ {green}11:05am  ◷ 3h  {green}▰{green}▰{dim_green}▱{dim_green}▱{dim_green}▱  ◷ 6d  {green}▰{dim_green}▱{dim_green}▱{dim_green}▱{dim_green}▱'
    assert_equal expected, snapshot_line(100)
  end

  def test_snapshot_small
    expected = '{green}▣{green} 120.3k ⛁ {green}11:05am         ◷ 3h {green}40%  ◷ 6d {green} 5%'
    assert_equal expected, snapshot_line(50)
  end

  # --- ClaudeSession: the value object the displays read from ---
  def test_claude_session_reads_plain_fields
    session = ClaudeSession.new(layout_data)
    assert_equal 210_000, session.ctx
    assert_equal 1_000_000, session.window_size
    assert_in_delta 21, session.ctx_percent, 0.01
    assert_equal 1.5, session.cost
    assert_equal 'Sonnet 5', session.model_name
    assert_equal 40, session.five_pct
    assert session.limits?
  end

  def test_claude_session_defaults_when_data_is_empty
    session = ClaudeSession.new({})
    assert_equal 0, session.ctx
    assert_equal 0, session.ctx_percent
    assert_equal 0, session.five_pct
    refute session.limits?
    assert_nil session.turn
    assert_nil session.cache_expires_at
  end

  def test_claude_session_expected_pace_is_a_percent
    on_pace_monday do |now|
      session = ClaudeSession.new('rate_limits' => { 'five_hour' => { 'used_percentage' => 10, 'resets_at' => now + 9_000 } })
      assert_in_delta 50, session.five_expected, 0.01
    end
  end

  # --- ClaudeSession turn: from the transcript when readable, else the last request ---
  def turn_session(*requests, cache: nil)
    file = Tempfile.new(['transcript', '.jsonl'])
    file.puts({ 'type' => 'user', 'promptId' => 'p1' }.to_json)
    requests.each_with_index do |(usage, tool), i|
      content = tool ? [{ 'type' => 'tool_use', 'id' => "tool#{i}" }] : []
      file.puts({ 'type' => 'assistant', 'promptId' => 'p1',
                  'message' => { 'id' => "m#{i}", 'usage' => usage, 'content' => content } }.to_json)
    end
    file.flush
    @transcripts = (@transcripts || []) << file # keep it alive for the test
    data = { 'transcript_path' => file.path, 'prompt_id' => 'p1',
             'context_window' => { 'total_output_tokens' => 9, 'current_usage' => { 'cache_creation_input_tokens' => 7 } } }
    data['prompt_cache'] = cache if cache
    ClaudeSession.new(data)
  end

  def test_turn_sums_every_request_in_the_prompt
    session = turn_session(
      [{ 'input_tokens' => 5, 'cache_creation_input_tokens' => 100, 'cache_read_input_tokens' => 1000, 'output_tokens' => 50 }, true],
      [{ 'input_tokens' => 3, 'cache_creation_input_tokens' => 0, 'cache_read_input_tokens' => 1100, 'output_tokens' => 20 }, false]
    )
    assert_equal 108, session.turn_up
    assert_equal 70, session.turn_down
    assert_equal 1, session.turn_tools
  end

  def test_turn_cache_tier_is_decided_by_the_first_send
    hit  = turn_session([{ 'cache_creation_input_tokens' => 100, 'cache_read_input_tokens' => 1000 }, false])
    miss = turn_session([{ 'cache_creation_input_tokens' => 4000, 'cache_read_input_tokens' => 0 }, false])
    assert_equal :cache_hit, hit.turn_cache_tier
    assert_equal :cache_miss, miss.turn_cache_tier
  end

  def test_turn_falls_back_to_the_last_request_without_a_transcript
    session = ClaudeSession.new('context_window' => { 'total_output_tokens' => 9, 'current_usage' => { 'cache_creation_input_tokens' => 7 } },
                                'prompt_cache' => { 'warm' => false, 'expires_at' => 1 })
    assert_equal 7, session.turn_up
    assert_equal 9, session.turn_down
    assert_equal 0, session.turn_tools
    assert_equal :cache_miss, session.turn_cache_tier
  end

  def test_turn_cache_tier_nil_when_nothing_is_known
    assert_nil ClaudeSession.new({}).turn_cache_tier
  end

  # --- ClaudeSession limit tiers: :wall at 90%, else by points past the pace ---
  # five_tier for `pct` used when `expected_pct` of the 5h window has elapsed.
  # The pace is computed lazily, so the tier is read while the clock is pinned.
  def five_tier_at(pct, expected_pct)
    on_pace_monday do |now|
      resets = now + ((100 - expected_pct) / 100.0 * 18_000).round
      ClaudeSession.new('rate_limits' => { 'five_hour' => { 'used_percentage' => pct, 'resets_at' => resets } }).five_tier
    end
  end

  def test_five_tier_behind_on_pace_and_ahead
    assert_equal :behind, five_tier_at(20, 40)
    assert_equal :on_pace, five_tier_at(40, 40)
    assert_equal :on_pace, five_tier_at(49, 40)
    assert_equal :ahead, five_tier_at(51, 40)
  end

  def test_five_tier_wall_wins_over_pace
    assert_equal :wall, five_tier_at(90, 95)
    assert_equal :wall, five_tier_at(95, 40)
    assert_equal :ahead, five_tier_at(89, 40)
  end

  def test_limit_tier_without_a_pace_is_on_pace
    assert_equal :on_pace, ClaudeSession.new('rate_limits' => { 'five_hour' => { 'used_percentage' => 50 } }).five_tier
  end

  # --- ClaudeSession cache tier: :warm, :cooling under CACHE_LOW_SECS, :expired ---
  def cache_tier_in(seconds_left)
    on_pace_monday do |now|
      ClaudeSession.new('prompt_cache' => { 'expires_at' => now + seconds_left }).cache_tier
    end
  end

  def test_cache_tier_names
    assert_equal :warm, cache_tier_in(600)
    assert_equal :warm, cache_tier_in(CACHE_LOW_SECS)
    assert_equal :cooling, cache_tier_in(CACHE_LOW_SECS - 1)
    assert_equal :cooling, cache_tier_in(1)
    assert_equal :expired, cache_tier_in(0)
    assert_equal :expired, cache_tier_in(-30)
  end

  def test_cache_tier_nil_without_a_cache
    assert_nil ClaudeSession.new({}).cache_tier
  end
end
