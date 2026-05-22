# Raahi Pricing and Surge Documentation

This document explains the current pricing implementation in the Raahi app, how surge is represented, and how the model compares with Rapido, Ola, and Uber.

## 1) Pricing Architecture (Current Build)

Raahi currently supports two pricing paths:

- **Primary (authoritative): Backend pricing API**
  - Endpoint call from app: `POST /api/pricing/calculate` via `apiClient.getRidePricing(...)`.
  - Expected backend response includes:
    - `baseFare`
    - `distanceFare`
    - `timeFare`
    - `totalFare`
    - `breakdown` (optional detailed pricing map)
    - `surge_active`
    - `surge_multiplier`

- **Fallback (client-side): Local estimation**
  - Used when backend pricing fails/timeouts.
  - Uses local rate cards to keep booking flow available.

## 2) Fare Components

The app supports these components in `FareBreakdown`:

- `baseFare`
- `distanceFare`
- `timeFare`
- `surgeMultiplier`
- `surgeAmount`
- `tolls`
- `airportFee`
- `waitingCharge`
- `parkingFees`
- `extraStopsCharge`
- `discount`
- `subtotal`
- `gstPercent`
- `gstAmount`
- `totalFare`
- `minimumFareApplied`

## 3) Core Fare Formula

### A) Local estimate formula (`maps_service.dart`)

```text
distanceKm = distanceMeters / 1000
durationMin = durationSeconds / 60

subtotal = baseFare + (distanceKm * perKmRate) + (durationMin * perMinRate)
taxes = subtotal * 0.05
total = subtotal + taxes
```

### B) Backend formula

Backend is treated as source of truth for booking and final totals. The app consumes backend-computed `totalFare` and optional detailed `breakdown`.

## 4) Rate Cards in Current App

### A) Local estimation rates (`maps_service.dart`)

- `bike`: base 5, per km 5, per min 0.5
- `economy`: base 10, per km 8, per min 1
- `comfort`: base 15, per km 12, per min 1.5
- `premium`: base 25, per km 18, per min 2
- `xl`: base 20, per km 15, per min 1.8

### B) Backend-derived ride options shown in `find_trip_screen.dart`

Backend returns a base `totalFare`, then app derives category fares:

- `bike_rescue`: `totalFare * 0.6`
- `auto`: `totalFare * 0.8`
- `cab_mini`: `totalFare * 1.0`
- `cab_xl`: `totalFare * 1.3`
- `cab_premium`: `totalFare * 1.8`

### C) Fallback category rates (`find_trip_screen.dart`)

- `bike_rescue`: base 20, per km 6, per min 1
- `auto`: base 25, per km 8, per min 1.5
- `cab_mini`: base 40, per km 12, per min 2
- `cab_xl`: base 80, per km 18, per min 3
- `cab_premium`: base 100, per km 25, per min 4
- `personal_driver`: base 150, per km 0, per min 3.5

## 5) Surge Pricing (How It Works)

### Current surge signals

The app expects and uses:

- `surge_active` (boolean)
- `surge_multiplier` (number, e.g. `1.3`, `1.8`)
- `breakdown.dynamicMultiplier` (detailed fare breakdown path)
- `surgeAmount` (explicit currency amount if backend sends it)

### UI behavior

- Surge chip is shown when multiplier is > 1.0.
- Fare breakdown displays:
  - `Surge (Nx)` line
  - `+₹surgeAmount` value

### Effective interpretation

```text
If surgeMultiplier <= 1.0: no surge line shown.
If surgeMultiplier > 1.0: surge is active and shown transparently.
```

> Note: exact surge computation logic (supply-demand model, zone logic, time windows) is backend-defined. The app displays what backend returns.

## 6) Receipt and History Pricing

On ride details/receipt screens, app renders backend `fareBreakdown` first. If certain keys are missing, safe defaults are used to avoid blank UI.

## 7) Comparison: Raahi vs Rapido, Ola, Uber

This is a product/engineering comparison of pricing behavior (not market-rate claims).

### Surge transparency

- **Raahi (current)**: Shows multiplier and can show absolute surge amount + detailed breakdown.
- **Uber**: Usually clear upfront total; surge reflected in upfront price and occasionally multiplier.
- **Ola**: Upfront fares with dynamic pricing; surcharge often visible but breakdown depth varies by flow.
- **Rapido**: Simpler category pricing, generally less detailed breakdown UI than full cab flows.

### Price explainability

- **Raahi**: Strong explainability due to explicit `FareBreakdown` model (base, distance, time, surge, tolls, waiting, GST, discounts).
- **Uber/Ola**: Strong in mature markets, but breakdown granularity visible to user can vary by product/region.
- **Rapido**: Usually simpler and faster flow; less detailed breakdown emphasis.

### Reliability of pricing

- **Raahi**: Dual-path resilience (backend pricing + client fallback) reduces booking failures when pricing API is unavailable.
- **Uber/Ola/Rapido**: Mature backend pricing stacks, generally no client fallback needed due to high backend reliability.

### Category scaling approach

- **Raahi**: Uses base fare output + category multipliers (`0.6x`, `0.8x`, `1.0x`, `1.3x`, `1.8x`) for clean and predictable scaling.
- **Uber/Ola/Rapido**: Category-specific models often include more market, city, and behavioral features.

## 8) Recommended Product Positioning Against Competitors

- Keep **transparent breakdown** as a core differentiator.
- Always show:
  - upfront fare
  - surge multiplier
  - surge amount
  - reason code (optional, backend-driven: peak demand / rain / event / low supply)
- Preserve dual-path fallback for reliability.
- Add a "Fare changed by X due to route/time changes" note for trust parity with top platforms.

## 9) Source References (Code)

- `lib/features/ride/presentation/screens/find_trip_screen.dart`
- `lib/core/widgets/fare_breakdown_widget.dart`
- `lib/core/services/maps_service.dart`
- `lib/core/models/ride.dart`
- `lib/features/home/presentation/widgets/ride_booking_card.dart`
- `lib/features/ride/presentation/screens/ride_details_screen.dart`

