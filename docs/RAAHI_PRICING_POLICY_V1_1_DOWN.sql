-- Raahi Pricing Policy v1.1 Rollback Script (DOWN)
-- Use only if you want to remove the pricing schema seeded by:
-- docs/RAAHI_PRICING_POLICY_V1_1_SEED.sql
--
-- PostgreSQL compatible

BEGIN;

-- Drop view first if present
DROP VIEW IF EXISTS pricing_effective_config_v;

-- Drop dependent tables in reverse dependency order
DROP TABLE IF EXISTS pricing_city_guardrails;
DROP TABLE IF EXISTS pricing_rate_cards;
DROP TABLE IF EXISTS pricing_city_policy;
DROP TABLE IF EXISTS pricing_category_defaults;
DROP TABLE IF EXISTS pricing_global_config;
DROP TABLE IF EXISTS pricing_categories;
DROP TABLE IF EXISTS pricing_cities;

COMMIT;

