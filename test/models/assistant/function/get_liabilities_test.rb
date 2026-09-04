require "test_helper"

class Assistant::Function::GetLiabilitiesTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:loan)
    @loan = @account.loan
    @fn = Assistant::Function::GetLiabilities.new(@user)
  end

  def loan_payload
    @fn.call[:liabilities].find { |l| l[:id] == @account.id }
  end

  test "has correct name and is not strict" do
    assert_equal "get_liabilities", @fn.name
    refute @fn.to_definition[:strict]
  end

  test "lists only liability accounts" do
    types = @fn.call[:liabilities].map { |l| l[:type] }.uniq

    assert types.any?
    assert_empty types - %w[Loan CreditCard OtherLiability]
  end

  test "returns a fixed-rate loan's terms and repayment schedule" do
    @account.update!(balance: 10_000)
    @loan.update!(rate_type: "fixed", interest_rate: 3.5, term_months: 360,
                  apr: 4.1, insurance_monthly_amount: 12)

    payload = loan_payload

    assert_equal 3.5, payload[:terms][:interest_rate].to_f
    assert_equal 4.1, payload[:terms][:apr].to_f, "the TAEG is reported separately from the nominal rate"
    assert payload[:schedule][:monthly_payment].present?
    assert_equal 12, payload[:schedule][:insurance_monthly_amount].to_f
    assert_equal(
      payload[:schedule][:monthly_payment].to_f + 12,
      payload[:schedule][:total_monthly_cost].to_f,
      "the total cost must include the insurance premium"
    )
    assert payload[:schedule][:remaining_payments].positive?
    assert payload[:schedule][:payoff_date].present?
  end

  test "explains why a variable-rate loan has no schedule and names the field to fill" do
    @loan.update!(rate_type: "variable", scheduled_payment: nil)

    payload = loan_payload

    assert_nil payload[:schedule]&.dig(:monthly_payment)
    assert_match(/fixed-rate/, payload[:unavailable][:monthly_payment])
    assert_match(/Actual monthly payment/, payload[:unavailable][:monthly_payment])
  end

  test "produces a full schedule for a variable-rate loan once the payment is recorded" do
    @account.update!(balance: 10_000)
    @loan.update!(rate_type: "variable", interest_rate: 6, scheduled_payment: 500)

    payload = loan_payload

    assert_equal 500, payload[:schedule][:monthly_payment].to_f
    assert payload[:schedule][:remaining_payments].between?(20, 24)
    assert_not payload[:unavailable]&.key?(:monthly_payment)
  end

  test "says so when the payment can never amortize the balance" do
    @account.update!(balance: 100_000)
    @loan.update!(rate_type: "variable", interest_rate: 12, scheduled_payment: 100)

    assert_match(/never amortizes/, loan_payload[:unavailable][:remaining_payments])
  end

  test "flags a missing APR without inventing one" do
    @loan.update!(apr: nil)

    payload = loan_payload

    assert_not payload[:terms].key?(:apr)
    assert_match(/TAEG/, payload[:unavailable][:apr])
  end

  test "reports credit card terms" do
    card = @fn.call[:liabilities].find { |l| l[:id] == accounts(:credit_card).id }

    assert_equal 18.99, card[:terms][:apr].to_f
    assert_equal 100.0, card[:terms][:minimum_payment].to_f
    assert_nil card[:schedule], "a card has no amortization schedule"
  end

  test "totals debt per currency" do
    totals = @fn.call[:totals_by_currency]

    assert totals.key?(@account.currency)
    assert totals[@account.currency][:formatted].present?
    assert totals[@account.currency][:account_count].positive?
  end

  test "excludes accounts the user cannot access" do
    result = Assistant::Function::GetLiabilities.new(users(:family_member)).call

    assert_not_includes result[:liabilities].map { |l| l[:id] }, accounts(:investment).id
  end
end
