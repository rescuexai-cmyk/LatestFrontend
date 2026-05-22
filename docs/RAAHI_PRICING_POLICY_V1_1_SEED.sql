-- Raahi Pricing Policy v1.1 SQL Seed
-- PostgreSQL compatible
-- Source: docs/RAAHI_PRICING_POLICY_V1_1_CITY_STARTER_VALUES.md

BEGIN;

-- -------------------------------------------------------------------
-- 1) Master dimensions
-- -------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pricing_cities (
  city_code TEXT PRIMARY KEY,
  city_name TEXT NOT NULL,
  city_tier TEXT NOT NULL,
  currency_code TEXT NOT NULL DEFAULT 'INR',
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS pricing_categories (
  category_code TEXT PRIMARY KEY,
  category_name TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- -------------------------------------------------------------------
-- 2) Global pricing config
-- -------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pricing_global_config (
  config_key TEXT PRIMARY KEY,
  config_value TEXT NOT NULL,
  value_type TEXT NOT NULL DEFAULT 'string',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- -------------------------------------------------------------------
-- 3) Category defaults (cross-city)
-- -------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pricing_category_defaults (
  category_code TEXT PRIMARY KEY REFERENCES pricing_categories(category_code),
  platform_fee_pct NUMERIC(5,2) NOT NULL,
  wait_rate_per_min NUMERIC(10,2) NOT NULL,
  pickup_comp_per_km NUMERIC(10,2) NOT NULL,
  target_accept_rate NUMERIC(5,4) NOT NULL,
  k_surge NUMERIC(6,4) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- -------------------------------------------------------------------
-- 4) City policy knobs
-- -------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pricing_city_policy (
  city_code TEXT PRIMARY KEY REFERENCES pricing_cities(city_code),
  surge_cap_normal NUMERIC(4,2) NOT NULL,
  surge_cap_event NUMERIC(4,2) NOT NULL,
  surge_step_5min NUMERIC(4,2) NOT NULL,
  promo_budget_rule TEXT NOT NULL,
  offpeak_no_surge_window TEXT NOT NULL,
  quote_lock_seconds INTEGER NOT NULL DEFAULT 75,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- -------------------------------------------------------------------
-- 5) City + category rate cards
-- -------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pricing_rate_cards (
  city_code TEXT NOT NULL REFERENCES pricing_cities(city_code),
  category_code TEXT NOT NULL REFERENCES pricing_categories(category_code),
  base_fare NUMERIC(10,2) NOT NULL,
  per_km_rate NUMERIC(10,2) NOT NULL,
  per_min_rate NUMERIC(10,2) NOT NULL,
  min_trip_payout NUMERIC(10,2) NOT NULL,
  hourly_guarantee NUMERIC(10,2) NOT NULL,
  eta_target_min INTEGER NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (city_code, category_code)
);

-- -------------------------------------------------------------------
-- 6) City promo and rider benefit guardrails
-- -------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pricing_city_guardrails (
  city_code TEXT PRIMARY KEY REFERENCES pricing_cities(city_code),
  weekly_promo_budget_rule TEXT NOT NULL,
  first_n_rides_discount_pct NUMERIC(5,2) NOT NULL,
  first_n_rides_discount_cap NUMERIC(10,2) NOT NULL,
  first_n_rides_count INTEGER NOT NULL,
  per_ride_discount_cap_pct NUMERIC(5,2) NOT NULL,
  per_ride_discount_cap_abs NUMERIC(10,2) NOT NULL,
  max_discounted_rides_per_user_week INTEGER NOT NULL,
  max_discount_per_user_week NUMERIC(10,2) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- -------------------------------------------------------------------
-- 7) Seed: master dimensions
-- -------------------------------------------------------------------

INSERT INTO pricing_cities (city_code, city_name, city_tier, currency_code, is_active)
VALUES
  ('prayagraj', 'Prayagraj', 'tier_2', 'INR', TRUE),
  ('delhi', 'Delhi', 'tier_1', 'INR', TRUE),
  ('bangalore', 'Bangalore', 'tier_1_plus', 'INR', TRUE)
ON CONFLICT (city_code) DO UPDATE SET
  city_name = EXCLUDED.city_name,
  city_tier = EXCLUDED.city_tier,
  currency_code = EXCLUDED.currency_code,
  is_active = EXCLUDED.is_active,
  updated_at = NOW();

INSERT INTO pricing_categories (category_code, category_name, is_active)
VALUES
  ('bike_rescue', 'Bike Rescue', TRUE),
  ('auto', 'Auto', TRUE),
  ('cab_mini', 'Cab Mini', TRUE),
  ('cab_xl', 'Cab XL', TRUE),
  ('cab_premium', 'Cab Premium', TRUE)
ON CONFLICT (category_code) DO UPDATE SET
  category_name = EXCLUDED.category_name,
  is_active = EXCLUDED.is_active,
  updated_at = NOW();

-- -------------------------------------------------------------------
-- 8) Seed: global config
-- -------------------------------------------------------------------

INSERT INTO pricing_global_config (config_key, config_value, value_type)
VALUES
  ('waitGraceMin', '3', 'integer'),
  ('pickupGraceKm', '1.5', 'numeric'),
  ('quoteLockSeconds', '75', 'integer'),
  ('acceptanceAlpha', '0.35', 'numeric'),
  ('cancelTarget', '0.12', 'numeric')
ON CONFLICT (config_key) DO UPDATE SET
  config_value = EXCLUDED.config_value,
  value_type = EXCLUDED.value_type,
  updated_at = NOW();

-- -------------------------------------------------------------------
-- 9) Seed: category defaults
-- -------------------------------------------------------------------

INSERT INTO pricing_category_defaults (
  category_code, platform_fee_pct, wait_rate_per_min, pickup_comp_per_km, target_accept_rate, k_surge
)
VALUES
  ('bike_rescue', 12.00, 1.00, 3.00, 0.7800, 0.2800),
  ('auto',        14.00, 1.50, 4.00, 0.7500, 0.2600),
  ('cab_mini',    16.00, 2.00, 5.00, 0.7200, 0.2400),
  ('cab_xl',      16.00, 2.50, 6.00, 0.7000, 0.2200),
  ('cab_premium', 18.00, 3.00, 7.00, 0.7000, 0.2000)
ON CONFLICT (category_code) DO UPDATE SET
  platform_fee_pct = EXCLUDED.platform_fee_pct,
  wait_rate_per_min = EXCLUDED.wait_rate_per_min,
  pickup_comp_per_km = EXCLUDED.pickup_comp_per_km,
  target_accept_rate = EXCLUDED.target_accept_rate,
  k_surge = EXCLUDED.k_surge,
  updated_at = NOW();

-- -------------------------------------------------------------------
-- 10) Seed: city policy
-- -------------------------------------------------------------------

INSERT INTO pricing_city_policy (
  city_code, surge_cap_normal, surge_cap_event, surge_step_5min,
  promo_budget_rule, offpeak_no_surge_window, quote_lock_seconds, is_active
)
VALUES
  ('prayagraj', 1.60, 2.00, 0.08, 'min(7%_weekly_GMV,250000)',  'Mon-Fri 11:00-16:00', 75, TRUE),
  ('delhi',     1.80, 2.20, 0.10, 'min(8%_weekly_GMV,1800000)', 'Tue-Thu 11:30-15:30', 75, TRUE),
  ('bangalore', 1.80, 2.20, 0.10, 'min(8%_weekly_GMV,2200000)', 'Tue-Thu 11:00-15:00', 75, TRUE)
ON CONFLICT (city_code) DO UPDATE SET
  surge_cap_normal = EXCLUDED.surge_cap_normal,
  surge_cap_event = EXCLUDED.surge_cap_event,
  surge_step_5min = EXCLUDED.surge_step_5min,
  promo_budget_rule = EXCLUDED.promo_budget_rule,
  offpeak_no_surge_window = EXCLUDED.offpeak_no_surge_window,
  quote_lock_seconds = EXCLUDED.quote_lock_seconds,
  is_active = EXCLUDED.is_active,
  updated_at = NOW();

-- -------------------------------------------------------------------
-- 11) Seed: rate cards by city+category
-- -------------------------------------------------------------------

INSERT INTO pricing_rate_cards (
  city_code, category_code, base_fare, per_km_rate, per_min_rate,
  min_trip_payout, hourly_guarantee, eta_target_min, is_active
)
VALUES
  -- Prayagraj
  ('prayagraj', 'bike_rescue', 18.00,  5.50, 0.90,  42.00, 170.00,  6, TRUE),
  ('prayagraj', 'auto',        24.00,  8.00, 1.40,  62.00, 210.00,  7, TRUE),
  ('prayagraj', 'cab_mini',    38.00, 11.50, 1.90,  92.00, 270.00,  8, TRUE),
  ('prayagraj', 'cab_xl',      72.00, 17.00, 2.80, 132.00, 330.00,  9, TRUE),
  ('prayagraj', 'cab_premium', 95.00, 23.00, 3.80, 170.00, 400.00,  9, TRUE),

  -- Delhi
  ('delhi', 'bike_rescue', 24.00,  7.00, 1.20,  55.00, 210.00,  7, TRUE),
  ('delhi', 'auto',        32.00, 10.00, 1.90,  78.00, 260.00,  8, TRUE),
  ('delhi', 'cab_mini',    52.00, 14.00, 2.50, 112.00, 340.00,  9, TRUE),
  ('delhi', 'cab_xl',      94.00, 21.00, 3.60, 162.00, 420.00, 10, TRUE),
  ('delhi', 'cab_premium', 130.00, 29.00, 4.80, 210.00, 520.00, 10, TRUE),

  -- Bangalore
  ('bangalore', 'bike_rescue', 25.00,  7.20, 1.30,  58.00, 220.00,  7, TRUE),
  ('bangalore', 'auto',        35.00, 10.80, 2.00,  82.00, 275.00,  8, TRUE),
  ('bangalore', 'cab_mini',    56.00, 14.80, 2.70, 118.00, 360.00,  9, TRUE),
  ('bangalore', 'cab_xl',      102.00, 22.00, 3.80, 170.00, 440.00, 10, TRUE),
  ('bangalore', 'cab_premium', 142.00, 31.00, 5.00, 220.00, 540.00, 10, TRUE)
ON CONFLICT (city_code, category_code) DO UPDATE SET
  base_fare = EXCLUDED.base_fare,
  per_km_rate = EXCLUDED.per_km_rate,
  per_min_rate = EXCLUDED.per_min_rate,
  min_trip_payout = EXCLUDED.min_trip_payout,
  hourly_guarantee = EXCLUDED.hourly_guarantee,
  eta_target_min = EXCLUDED.eta_target_min,
  is_active = EXCLUDED.is_active,
  updated_at = NOW();

-- -------------------------------------------------------------------
-- 12) Seed: city guardrails
-- -------------------------------------------------------------------

INSERT INTO pricing_city_guardrails (
  city_code, weekly_promo_budget_rule,
  first_n_rides_discount_pct, first_n_rides_discount_cap, first_n_rides_count,
  per_ride_discount_cap_pct, per_ride_discount_cap_abs,
  max_discounted_rides_per_user_week, max_discount_per_user_week
)
VALUES
  ('prayagraj', 'min(7%_weekly_GMV,250000)', 20.00, 60.00, 3, 25.00, 80.00, 5, 250.00),
  ('delhi',     'min(8%_weekly_GMV,1800000)', 20.00, 60.00, 3, 25.00, 80.00, 5, 250.00),
  ('bangalore', 'min(8%_weekly_GMV,2200000)', 20.00, 60.00, 3, 25.00, 80.00, 5, 250.00)
ON CONFLICT (city_code) DO UPDATE SET
  weekly_promo_budget_rule = EXCLUDED.weekly_promo_budget_rule,
  first_n_rides_discount_pct = EXCLUDED.first_n_rides_discount_pct,
  first_n_rides_discount_cap = EXCLUDED.first_n_rides_discount_cap,
  first_n_rides_count = EXCLUDED.first_n_rides_count,
  per_ride_discount_cap_pct = EXCLUDED.per_ride_discount_cap_pct,
  per_ride_discount_cap_abs = EXCLUDED.per_ride_discount_cap_abs,
  max_discounted_rides_per_user_week = EXCLUDED.max_discounted_rides_per_user_week,
  max_discount_per_user_week = EXCLUDED.max_discount_per_user_week,
  updated_at = NOW();

COMMIT;

-- -------------------------------------------------------------------
-- Optional sanity checks
-- -------------------------------------------------------------------
-- SELECT city_code, category_code, base_fare, per_km_rate, per_min_rate
-- FROM pricing_rate_cards
-- ORDER BY city_code, category_code;

