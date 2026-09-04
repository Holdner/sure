require "test_helper"

class Assistant::Function::SimulateScenariosTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @account.update!(balance: 3_000, currency: "USD")
    @family.recurring_transactions.destroy_all
    @fn = Assistant::Function::SimulateScenarios.new(@user)
  end

  def call(scenarios, **params)
    @fn.call({
      "account_ids" => [ @account.id ],
      "horizon_days" => 90,
      "scenarios" => scenarios
    }.merge(params.transform_keys(&:to_s)))
  end

  def find(result, label)
    result[:comparison].find { |row| row[:label] == label }
  end

  test "has correct name and requires scenarios" do
    assert_equal "simulate_scenarios", @fn.name
    assert_includes @fn.params_schema[:required], "scenarios"
  end

  test "always includes the current trajectory as the baseline" do
    result = call([])

    assert_equal 1, result[:comparison].size
    assert_equal "current", result[:comparison].first[:label]
    assert_equal 0, result[:comparison].first[:low_point_delta_vs_current]
  end

  test "a one-off purchase lowers the low point by its amount" do
    result = call([
      { "label" => "buy now", "movements" => [ { "date" => (Date.current + 5).to_s, "amount" => 800 } ] }
    ])

    buy = find(result, "buy now")

    assert_in_delta(-800, buy[:low_point_delta_vs_current], 0.01)
    assert_equal 1, buy[:movements_applied]
  end

  test "deferring the same purchase is compared against buying now" do
    result = call([
      { "label" => "now", "movements" => [ { "date" => (Date.current + 3).to_s, "amount" => 2_500 } ] },
      { "label" => "in three months", "movements" => [ { "date" => (Date.current + 95).to_s, "amount" => 2_500 } ] }
    ])

    assert_operator find(result, "in three months")[:low_point][:balance],
                    :>,
                    find(result, "now")[:low_point][:balance],
                    "a purchase past the horizon cannot hurt the window"
  end

  test "models a monthly commitment with repeat_monthly" do
    result = call([
      { "label" => "subscription",
        "movements" => [ { "date" => (Date.current + 2).to_s, "amount" => 100, "repeat_monthly" => 3 } ] }
    ])

    assert_equal 3, find(result, "subscription")[:movements_applied]
    assert_in_delta(-300, find(result, "subscription")[:low_point_delta_vs_current], 0.01)
  end

  test "money arriving raises the low point" do
    @account.update!(balance: -200)

    result = call([
      { "label" => "bonus", "movements" => [ { "date" => (Date.current + 4).to_s, "amount" => 1_000, "direction" => "in" } ] }
    ])

    assert_operator find(result, "bonus")[:low_point_delta_vs_current], :>, 0
  end

  test "reports thresholds crossed on the way even when the ending balance looks fine" do
    @account.depository.update!(overdraft_limit: 400)

    result = call([
      { "label" => "big early spend",
        "movements" => [
          { "date" => (Date.current + 2).to_s, "amount" => 6_000 },
          { "date" => (Date.current + 40).to_s, "amount" => 6_000, "direction" => "in" }
        ] }
    ])

    scenario = find(result, "big early spend")

    assert_includes scenario[:thresholds_crossed].map { |t| t[:threshold_label] }, "overdraft_limit"
    assert_operator scenario[:low_point][:balance], :<, -400
  end

  test "ignores a movement with an unparseable date instead of failing the call" do
    result = call([
      { "label" => "bad input", "movements" => [ { "date" => "not-a-date", "amount" => 500 } ] }
    ])

    assert_equal 0, find(result, "bad input")[:movements_applied]
    assert_equal 0, find(result, "bad input")[:low_point_delta_vs_current]
  end

  test "treats a negative amount as a magnitude and uses direction for the sign" do
    result = call([
      { "label" => "sloppy", "movements" => [ { "date" => (Date.current + 5).to_s, "amount" => -800 } ] }
    ])

    assert_in_delta(-800, find(result, "sloppy")[:low_point_delta_vs_current], 0.01)
  end

  test "caps the number of scenarios" do
    scenarios = 8.times.map do |i|
      { "label" => "s#{i}", "movements" => [ { "date" => (Date.current + 2).to_s, "amount" => 10 } ] }
    end

    result = call(scenarios)

    assert_equal Assistant::Function::SimulateScenarios::MAX_SCENARIOS + 1, result[:comparison].size
  end

  test "carries assumptions and warnings once, not per scenario" do
    result = call([ { "label" => "x", "movements" => [] } ])

    assert result[:assumptions].present?
    assert result[:warnings].present?
    assert_not result[:comparison].first.key?(:assumptions)
  end
end
