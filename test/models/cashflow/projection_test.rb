require "test_helper"

class Cashflow::ProjectionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @account.update!(balance: 1_000, currency: "USD")
    @family.recurring_transactions.destroy_all
  end

  # Scoped to the one account under test by default: the fixtures carry several
  # depository accounts, so an unscoped projection pools balances that have
  # nothing to do with the behaviour being asserted.
  def project(**options)
    options[:account_ids] = [ @account.id ] unless options.key?(:account_ids)
    Cashflow::Projection.new(@family, user: @user, **options)
  end

  def declare_series(name:, amount:, day:, bill_type: "bill")
    @family.recurring_transactions.create!(
      name: name,
      amount: amount,
      currency: "USD",
      account: @account,
      bill_type: bill_type,
      manual: true,
      status: "active",
      expected_day_of_month: day,
      anchor_date: Date.current.beginning_of_month + (day - 1),
      last_occurrence_date: Date.current - 1.month,
      next_expected_date: Date.current.beginning_of_month.next_month + (day - 1)
    )
  end

  test "produces one day per horizon day plus today" do
    projection = project(horizon_days: 30)

    assert_equal 31, projection.days.size
    assert_equal Date.current, projection.days.first.date
    assert_equal Date.current + 30, projection.days.last.date
  end

  test "clamps an absurd horizon rather than looping forever" do
    assert_equal Cashflow::Projection::MAX_HORIZON_DAYS, project(horizon_days: 99_999).horizon_days
    assert_equal 1, project(horizon_days: 0).horizon_days
  end

  # ---- the whole point: income is counted -----------------------------------

  test "adds declared income instead of only subtracting" do
    declare_series(name: "Salary", amount: -2_000, day: 28, bill_type: "income")

    projection = project(horizon_days: 60)
    inflow_total = projection.days.sum(&:inflows)

    assert projection.declared_income?
    assert inflow_total.positive?, "a declared salary must appear as an inflow"
  end

  test "warns loudly when no income is declared" do
    projection = project(horizon_days: 30)

    assert_not projection.declared_income?
    assert(projection.warnings.any? { |w| w.include?("NO incoming") })
  end

  test "a salary lifts the low point above what outflows alone would give" do
    declare_series(name: "Rent", amount: 1_500, day: 5)

    without_income = project(horizon_days: 60).low_point.balance

    declare_series(name: "Salary", amount: -3_000, day: 28, bill_type: "income")

    with_income = project(horizon_days: 60).low_point.balance

    assert_operator with_income, :>, without_income
  end

  # ---- low point and threshold crossings ------------------------------------

  test "reports the dated low point" do
    declare_series(name: "Big bill", amount: 5_000, day: 10)

    projection = project(horizon_days: 60)

    assert projection.low_point.balance.negative?
    assert projection.low_point.date.between?(Date.current, Date.current + 60)
  end

  test "flags the overdraft floor separately from zero" do
    @account.depository.update!(overdraft_limit: 400)
    declare_series(name: "Big bill", amount: 5_000, day: 10)

    projection = project(horizon_days: 60)
    labels = projection.breaches.map(&:label)

    assert_includes labels, "zero"
    assert_includes labels, "overdraft_limit"

    overdraft = projection.breaches.find { |b| b.label == "overdraft_limit" }

    assert_equal(-400, overdraft.threshold)
    assert overdraft.days_below.positive?
    assert overdraft.deepest_balance <= overdraft.threshold
  end

  test "omits a threshold that is never crossed" do
    @account.update!(balance: 500_000)

    projection = project(horizon_days: 30)

    assert_empty projection.breaches
  end

  test "accepts a caller-supplied threshold" do
    projection = project(horizon_days: 30, extra_thresholds: [ 999_999 ])

    assert_includes projection.breaches.map(&:label), "custom_1"
  end

  # ---- overdraft fees --------------------------------------------------------

  test "charges an intervention fee only on payments above the threshold while past the floor" do
    @account.update!(balance: -500)
    @account.depository.update!(
      overdraft_limit: 400,
      intervention_fee_amount: 8,
      intervention_fee_threshold: 20
    )
    declare_series(name: "Small payment", amount: 5, day: 3)
    declare_series(name: "Large payment", amount: 100, day: 4)

    projection = project(horizon_days: 40)
    fee_days = projection.days.select { |day| day.fees.positive? }

    assert fee_days.any?, "a payment above the threshold past the floor must be charged"
    assert_equal 8, fee_days.first.fees.to_f
  end

  test "charges no fee while the balance stays inside the arranged overdraft" do
    @account.update!(balance: 1_000)
    @account.depository.update!(
      overdraft_limit: 400,
      intervention_fee_amount: 8,
      intervention_fee_threshold: 20
    )
    declare_series(name: "Normal bill", amount: 100, day: 4)

    projection = project(horizon_days: 20)

    assert(projection.days.none? { |day| day.fees.positive? })
  end

  test "respects the monthly fee cap" do
    @account.update!(balance: -5_000)
    @account.depository.update!(
      overdraft_limit: 400,
      intervention_fee_amount: 8,
      intervention_fee_threshold: 20,
      intervention_fee_monthly_cap: 16
    )
    5.times { |i| declare_series(name: "Payment #{i}", amount: 100, day: i + 2) }

    projection = project(horizon_days: 25)
    total_fees = projection.days.sum(&:fees)

    assert_operator total_fees, :<=, 16
    assert total_fees.positive?
  end

  # ---- honesty about inputs ---------------------------------------------------

  test "never invents a foreign currency balance" do
    foreign = @family.accounts.create!(name: "Compte GBP", balance: 9_999, currency: "GBP", accountable: Depository.new)

    projection = project(horizon_days: 30, account_ids: [ @account.id, foreign.id ])

    assert_not_includes projection.accounts.map(&:name), "Compte GBP"
    assert_equal 1_000, projection.starting_balance, "the GBP balance must not be added at par"
    assert_match(/another currency/, projection.assumptions[:accounts_excluded_note])
  end

  test "states its assumptions" do
    projection = project(horizon_days: 30)
    assumptions = projection.assumptions

    assert_includes assumptions[:accounts_included], @account.name
    assert_equal 1_000, assumptions[:starting_balance]
    assert assumptions.key?(:daily_discretionary_spend)
    assert_equal false, assumptions[:declared_income]
  end

  test "the discretionary baseline never turns into phantom income" do
    declare_series(name: "Huge recurring", amount: 50_000, day: 5)

    assert_equal 0, project(horizon_days: 60).daily_discretionary_spend,
                 "recurring outflows exceeding median spend must floor at zero, not go negative"
  end

  test "applies caller adjustments as dated movements" do
    delta = Cashflow::Projection::Event.new(
      date: Date.current + 5,
      label: "New laptop",
      amount: 2_000,
      direction: :out,
      source: "scenario"
    )

    base = project(horizon_days: 30).low_point.balance
    adjusted = project(horizon_days: 30, adjustments: [ delta ]).low_point.balance

    assert_in_delta base - 2_000, adjusted, 0.01
  end

  test "survives a family with no visible depository account" do
    @account.update!(status: "disabled")

    projection = project(horizon_days: 30)

    assert_equal 0, projection.starting_balance
    assert(projection.warnings.any? { |w| w.include?("nothing to project") })
  end
end
