# Raahi Pricing Policy v1 (Implementation Spec)

Owner: Pricing + Marketplace  
Scope: India launch cities, bike/auto/cab categories  
Goal: **Driver earns competitively well** while **rider sees fair and predictable pricing**

---

## 1) Design Principles

- **Dual objective:** maximize completed rides, not just fare.
- **Driver-first floor:** no viable trip should underpay drivers vs local alternatives.
- **Rider fairness:** bounded surge, smooth changes, transparent reasons.
- **Budget discipline:** incentives and promos controlled by weekly caps.

---

## 2) Definitions

Per ride request in zone `z`, time window `t` (15 min):

- `D`: estimated trip distance (km)
- `T`: estimated trip duration (min)
- `P`: estimated pickup distance driver->rider (km)
- `cat`: category (`bike_rescue`, `auto`, `cab_mini`, `cab_xl`, `cab_premium`)
- `base_z_cat`, `per_km_z_cat`, `per_min_z_cat`: city-zone-category rate card
- `S`: surge multiplier (dynamic)
- `A`: acceptance factor multiplier
- `W`: waiting charge
- `X`: extras (toll, parking, airport, extra stops)
- `Disc`: rider discount amount
- `GST`: tax component (if shown separately in receipts)

Marketplace metrics:

- `demandRate`: requests/min in zone window
- `supplyRate`: active available drivers/min
- `etaP90`: p90 pickup ETA (min)
- `cancelRider`, `cancelDriver`: cancellation rates
- `acceptRate`: driver acceptance rate

---

## 3) Base Fare Formula

### 3.1 Pre-surge fare

```text
PreFare = base_z_cat + (per_km_z_cat * D) + (per_min_z_cat * T)
```

### 3.2 Dynamic components

```text
GrossFare = (PreFare * S * A) + W + X
RiderFareBeforeDiscount = round_to_1_rupee(max(MinRiderFare_z_cat, GrossFare))
RiderFinalFare = max(MinPayable, RiderFareBeforeDiscount - Disc)
```

Recommended:
- `MinPayable = ₹20`
- rounding to nearest ₹1 for display clarity

---

## 4) Surge Engine (Exact)

## 4.1 Supply-demand pressure index

```text
imbalance = demandRate / max(supplyRate, 0.1)
etaPressure = clamp(etaP90 / etaTarget_z_cat, 0.8, 2.0)
cancelPressure = clamp((cancelRider + cancelDriver) / cancelTarget, 0.8, 1.5)

pressureIndex = 0.6*imbalance + 0.25*etaPressure + 0.15*cancelPressure
```

Default targets:
- `etaTarget`: bike 6m, auto 7m, mini 8m, xl 9m, premium 9m
- `cancelTarget = 0.12`

## 4.2 Raw surge

```text
S_raw = 1.0 + k_cat * max(0, pressureIndex - 1.0)
```

Category sensitivity (`k_cat`):
- bike 0.28
- auto 0.26
- mini 0.24
- xl 0.22
- premium 0.20

## 4.3 Surge cap + smoothing (fairness guardrails)

```text
S_cap_normal = 1.8
S_cap_event = 2.2   (explicit event flag only)

S_capped = min(S_raw, S_cap)
S_new = clamp(S_capped, S_prev - 0.10, S_prev + 0.10)   // <=10% change per 5 min
```

Display surge reason based on dominant pressure:
- low supply
- high demand
- heavy traffic
- weather/event

---

## 5) Acceptance Feedback Multiplier (Real-time)

Penalize fare if acceptance is already strong; raise if acceptance is poor.

```text
gap = targetAccept_cat - acceptRate
A = clamp(1.0 + alpha_cat * gap, 0.92, 1.12)
```

Targets:
- bike 0.78
- auto 0.75
- mini 0.72
- xl 0.70
- premium 0.70

`alpha_cat = 0.35` for all categories initially.

This closes the loop between pricing and driver willingness.

---

## 6) Driver Earnings Policy (Competitive Guarantee)

## 6.1 Driver payout formula

```text
PlatformFee = platformFeePct_cat * RiderFinalFare
DriverPayoutRaw = RiderFinalFare - PlatformFee + DriverIncentive + TollPassThrough + ParkingPassThrough
DriverPayout = max(TripFloorPayout_z_cat, DriverPayoutRaw)
```

Initial platform fee:
- bike 12%
- auto 14%
- mini 16%
- xl 16%
- premium 18%

## 6.2 Trip floor payout (must be competitive)

```text
TripFloorPayout_z_cat = max(
  floorBase_z_cat + floorPerKm_z_cat * D + floorPerMin_z_cat * T,
  cityMinTripPayout_cat
)
```

Launch defaults (example):
- bike: `cityMinTripPayout ₹45`
- auto: `₹65`
- mini: `₹95`
- xl: `₹140`
- premium: `₹180`

## 6.3 Hourly guarantee (launch zones)

Driver qualifies in guarantee zones if:
- online >= 45 min in hour
- acceptance >= 65%
- cancellation <= 15%
- completed >= 1 trip (or valid low-demand exception)

```text
HourlyTopUp = max(0, HourlyGuarantee_z_cat - NetEarningsThatHour)
```

Suggested starting guarantee:
- bike ₹180/hr
- auto ₹220/hr
- mini ₹280/hr
- xl ₹340/hr
- premium ₹420/hr

## 6.4 Pickup distance compensation (deadhead)

```text
if P > pickupGraceKm_cat:
  PickupComp = pickupCompPerKm_cat * (P - pickupGraceKm_cat)
else:
  PickupComp = 0
```

Defaults:
- grace `1.5 km` all categories
- comp/km: bike ₹3, auto ₹4, mini ₹5, xl ₹6, premium ₹7

---

## 7) Waiting-Time Fairness Loop

Grace period (no charge): `waitGraceMin = 3`

```text
ChargeableWaitMin = max(0, actualWaitMin - waitGraceMin)
W = waitRatePerMin_cat * ChargeableWaitMin
```

Defaults:
- bike ₹1.0/min
- auto ₹1.5/min
- mini ₹2.0/min
- xl ₹2.5/min
- premium ₹3.0/min

Split:
- 100% of waiting charge goes to driver payout.

---

## 8) Rider Benefits Policy (Acquisition + Retention)

## 8.1 New rider offer

- First 3 completed rides:
  - discount = `min(20% of fare, ₹60)`

## 8.2 Habit windows (off-peak)

- Fixed no-surge windows in selected zones (example 11:00-16:00 weekdays)
- Force `S = 1.0` if demand pressure < threshold

## 8.3 Loyalty tiers

- Bronze/Silver/Gold by 30-day completed rides.
- Benefits via discount credits/cashback, not hard fare distortion.

---

## 9) Promo Budget Limits (Hard Controls)

## 9.1 Weekly city budget

```text
PromoBudgetWeek_city <= min(8% of projected city GMV, fixed cap set by finance)
```

## 9.2 Per-ride cap

```text
Disc <= min(25% of RiderFareBeforeDiscount, ₹80)
```

## 9.3 User-level guardrail

- Max discounted rides/user/week: `5`
- Max discount/user/week: `₹250`
- Abuse checks: device + payment fingerprint + cancellation abuse flag

---

## 10) Price Lock Policy

- Quote lock duration: `75 seconds`
- During lock: rider sees same fare unless route changes materially (`>8%` distance delta)
- Post lock: requote allowed with reason label

---

## 11) Implementation Contract (Backend Response)

Required response payload from pricing service:

```json
{
  "success": true,
  "data": {
    "baseFare": 40,
    "distanceFare": 68,
    "timeFare": 24,
    "preFare": 132,
    "surgeMultiplier": 1.3,
    "acceptanceMultiplier": 1.04,
    "waitingCharge": 0,
    "extras": 20,
    "discountApplied": 30,
    "totalFare": 168,
    "currency": "INR",
    "surgeActive": true,
    "surgeReason": "high_demand",
    "lockExpiresAt": "2026-03-11T10:05:30Z",
    "driverPayoutEstimate": 136,
    "platformFeeAmount": 27,
    "incentiveAmount": 0,
    "breakdown": {
      "dynamicMultiplier": 1.3,
      "minimumFareApplied": false,
      "gstPercent": 5,
      "gstAmount": 8
    }
  }
}
```

---

## 12) Experimentation Plan (Must Have)

Run A/B by city-zone-category:
- Surge cap test: `1.6 vs 1.8`
- Acceptance alpha: `0.25 vs 0.35`
- Trip floor +₹10 in launch zones
- New rider discount cap `₹50 vs ₹60`

Promotion rule:
- Roll forward only if all are true:
  - conversion up (>= +2%)
  - driver earnings/hour non-decreasing
  - contribution margin not worse than threshold

---

## 13) KPI Thresholds (Operational)

Rider:
- search->book conversion >= 28%
- D30 repeat >= 32%
- fare complaints <= 1.5% of completed trips

Driver:
- acceptance >= 72% (city median)
- earnings/hour >= competitor benchmark -5% minimum, target +5%
- D30 driver retention >= 45%

Marketplace:
- fulfillment >= 90%
- p90 pickup ETA <= 9 min
- cancellation <= 14%

---

## 14) Rollout Sequence (8 Weeks)

- Week 1-2: surge cap + smoothing + reason labels + price lock
- Week 3-4: trip floor payout + waiting fairness + pickup compensation
- Week 5-6: acceptance multiplier + zone-time pressure engine
- Week 7-8: promo budget governor + loyalty tiers + A/B rollout

---

## 15) Non-Negotiables

- Never hide surge from rider.
- Never let qualified driver earn below trip floor.
- Never exceed promo budget guardrails.
- Always log explainable pricing inputs for auditability.

