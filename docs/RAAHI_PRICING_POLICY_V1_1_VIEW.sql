-- Raahi Pricing Policy v1.1 Runtime View
-- Creates a single denormalized view for easy runtime fetch.
--
-- Expected base tables:
-- pricing_cities
-- pricing_categories
-- pricing_global_config
-- pricing_category_defaults
-- pricing_city_policy
-- pricing_rate_cards
-- pricing_city_guardrails

CREATE OR REPLACE VIEW pricing_effective_config_v AS
SELECT
  c.city_code,
  c.city_name,
  c.city_tier,
  c.currency_code,
  c.is_active AS city_active,

  rc.category_code,
  cat.category_name,
  cat.is_active AS category_active,

  -- City policy knobs
  cp.surge_cap_normal,
  cp.surge_cap_event,
  cp.surge_step_5min,
  cp.promo_budget_rule,
  cp.offpeak_no_surge_window,
  cp.quote_lock_seconds,
  cp.is_active AS city_policy_active,

  -- Core rate card
  rc.base_fare,
  rc.per_km_rate,
  rc.per_min_rate,
  rc.min_trip_payout,
  rc.hourly_guarantee,
  rc.eta_target_min,
  rc.is_active AS rate_card_active,

  -- Category defaults
  cd.platform_fee_pct,
  cd.wait_rate_per_min,
  cd.pickup_comp_per_km,
  cd.target_accept_rate,
  cd.k_surge,

  -- Guardrails
  cg.weekly_promo_budget_rule,
  cg.first_n_rides_discount_pct,
  cg.first_n_rides_discount_cap,
  cg.first_n_rides_count,
  cg.per_ride_discount_cap_pct,
  cg.per_ride_discount_cap_abs,
  cg.max_discounted_rides_per_user_week,
  cg.max_discount_per_user_week,

  -- Global config projected as columns
  (SELECT config_value::int
   FROM pricing_global_config
   WHERE config_key = 'waitGraceMin') AS wait_grace_min,

  (SELECT config_value::numeric
   FROM pricing_global_config
   WHERE config_key = 'pickupGraceKm') AS pickup_grace_km,

  (SELECT config_value::int
   FROM pricing_global_config
   WHERE config_key = 'quoteLockSeconds') AS quote_lock_seconds_global,

  (SELECT config_value::numeric
   FROM pricing_global_config
   WHERE config_key = 'acceptanceAlpha') AS acceptance_alpha,

  (SELECT config_value::numeric
   FROM pricing_global_config
   WHERE config_key = 'cancelTarget') AS cancel_target,

  -- Effective flag for runtime filtering
  (
    c.is_active
    AND cat.is_active
    AND cp.is_active
    AND rc.is_active
  ) AS effective_active,

  NOW() AS generated_at

FROM pricing_rate_cards rc
JOIN pricing_cities c
  ON c.city_code = rc.city_code
JOIN pricing_categories cat
  ON cat.category_code = rc.category_code
JOIN pricing_city_policy cp
  ON cp.city_code = rc.city_code
JOIN pricing_category_defaults cd
  ON cd.category_code = rc.category_code
JOIN pricing_city_guardrails cg
  ON cg.city_code = rc.city_code;

-- Helpful index suggestions (run separately on base tables if needed):
-- CREATE INDEX IF NOT EXISTS idx_pricing_rate_cards_city_category ON pricing_rate_cards(city_code, category_code);
-- CREATE INDEX IF NOT EXISTS idx_pricing_city_policy_city ON pricing_city_policy(city_code);
-- CREATE INDEX IF NOT EXISTS idx_pricing_city_guardrails_city ON pricing_city_guardrails(city_code);

