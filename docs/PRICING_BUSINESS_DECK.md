# Raahi Pricing Strategy Deck (Investor/Partner)

## Slide 1: Executive Summary

- Raahi pricing is built for **trust, conversion, and reliability**
- Backend-first pricing with client fallback safeguards booking continuity
- Transparent fare breakdown is a product differentiator versus opaque competitor experiences
- Surge is explainable, controllable, and visibly communicated to users

## Slide 2: Pricing Objectives

- Maximize booking conversion through clear upfront fares
- Protect margins with dynamic pricing during demand-supply imbalance
- Improve retention through transparent post-ride receipts
- Reduce failed sessions via resilient fallback pricing path

## Slide 3: Current Pricing Architecture

- **Primary path:** backend pricing API (`/api/pricing/calculate`)
  - Returns `baseFare`, `distanceFare`, `timeFare`, `totalFare`, surge signals, optional breakdown
- **Fallback path:** on-device local fare estimation
  - Prevents hard booking failures during transient backend/network issues
- **UI layer:** standard fare breakdown model rendered across booking and receipt flows

## Slide 4: Fare Composition Model

- Base fare
- Distance fare (km-based)
- Time fare (minute-based)
- Surge (multiplier + amount)
- Add-ons: tolls, airport fee, parking, waiting, extra stops
- Discounts/promotions
- GST/tax

**Value proposition:** high explainability with line-item accountability.

## Slide 5: Dynamic Pricing (Surge) Framework

- Input signal exposed to app:
  - `surge_active` (bool)
  - `surge_multiplier` (numeric)
  - optional `surgeAmount`
- UX behavior:
  - Surge visible before booking
  - Surge line item visible in breakdown
- Strategic effect:
  - Balances demand with available drivers
  - Reduces unfulfilled requests during peak periods

## Slide 6: Category Pricing Strategy

Backend total fare is adapted to category-level offers:

- Bike Rescue: `0.6x`
- Auto: `0.8x`
- Cab Mini: `1.0x`
- Cab XL: `1.3x`
- Premium: `1.8x`

This creates a clear value ladder from economy to premium while preserving predictable pricing progression.

## Slide 7: Competitive Comparison (Positioning)

### Raahi vs Uber/Ola/Rapido (product-pricing behavior)

- **Transparency**
  - Raahi: explicit breakdown + surge visibility
  - Uber/Ola: strong upfront pricing, variable breakdown depth by flow/region
  - Rapido: simpler flow, typically lighter breakdown detail

- **Resilience**
  - Raahi: backend + fallback dual path
  - Competitors: generally backend-only with mature infra

- **Explainability**
  - Raahi: line-item explainability is a key differentiator for user trust

## Slide 8: Revenue and Unit-Economics Levers

- Surge multiplier policy tuning by city/time/zone
- Category multiplier tuning for margin mix optimization
- Waiting/parking/extra-stop recovery to reduce unbilled ops costs
- Promo governance with controlled discount burn
- Minimum fare enforcement for short-ride viability

## Slide 9: Partner Narrative (Supply-Side)

- Drivers benefit from dynamic peak compensation
- Transparent passenger pricing reduces disputes
- Better fare confidence improves acceptance rates
- Structured category ladder helps route higher-value demand to premium supply

## Slide 10: Risk and Mitigation

- **Risk:** surge perception as unfair  
  **Mitigation:** clear pre-booking disclosure, reason tags, caps by policy

- **Risk:** backend pricing downtime  
  **Mitigation:** client fallback estimation and graceful continuity

- **Risk:** fare mismatch disputes  
  **Mitigation:** receipt-level component breakdown and support auditability

## Slide 11: KPI Framework

- Conversion rate (search -> booking)
- Driver acceptance rate
- Fulfillment rate during peak windows
- Average fare and contribution margin by category
- Surge session conversion vs non-surge conversion
- Dispute rate tied to fare complaints
- Repeat rate / retention after surge rides

## Slide 12: Next Roadmap Enhancements

- Surge reason codes (rain, event, peak demand, low supply)
- City-wise guardrails and multiplier caps
- Real-time price confidence indicator
- A/B testing of category multipliers
- Elastic discounting based on rider LTV and demand state

## Appendix: Technical Notes

- Source references:
  - `docs/PRICING_AND_SURGE_DOCUMENTATION.md`
  - `lib/features/ride/presentation/screens/find_trip_screen.dart`
  - `lib/core/widgets/fare_breakdown_widget.dart`
  - `lib/core/services/maps_service.dart`
  - `lib/core/models/ride.dart`

