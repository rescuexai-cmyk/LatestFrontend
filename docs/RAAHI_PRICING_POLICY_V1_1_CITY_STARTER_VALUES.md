# Raahi Pricing Policy v1.1 (City-Wise Starter Values)

Version: v1.1  
Depends on: `docs/RAAHI_PRICING_POLICY_V1.md`  
Purpose: Give backend a ship-ready starter config for **Prayagraj**, **Delhi**, and **Bangalore**.

---

## 1) Rollout Notes

- Use these as launch defaults for 2-4 weeks.
- Recalibrate weekly using actual conversion, fulfillment, earnings/hour, and cancellation.
- Keep v1 fairness guardrails active (surge cap/smoothing, driver floors, promo caps).

---

## 2) City Tier Assumption

- **Tier 2**: Prayagraj (price sensitive, lower ticket size)
- **Tier 1**: Delhi (high demand volatility, traffic-heavy)
- **Tier 1+**: Bangalore (high traffic + strong premium demand)

---

## 3) Category IDs

- `bike_rescue`
- `auto`
- `cab_mini`
- `cab_xl`
- `cab_premium`

---

## 4) City Starter Rate Cards (Base / Km / Min)

### Prayagraj (INR)

| Category | Base | Per Km | Per Min |
|---|---:|---:|---:|
| bike_rescue | 18 | 5.5 | 0.9 |
| auto | 24 | 8.0 | 1.4 |
| cab_mini | 38 | 11.5 | 1.9 |
| cab_xl | 72 | 17.0 | 2.8 |
| cab_premium | 95 | 23.0 | 3.8 |

### Delhi (INR)

| Category | Base | Per Km | Per Min |
|---|---:|---:|---:|
| bike_rescue | 24 | 7.0 | 1.2 |
| auto | 32 | 10.0 | 1.9 |
| cab_mini | 52 | 14.0 | 2.5 |
| cab_xl | 94 | 21.0 | 3.6 |
| cab_premium | 130 | 29.0 | 4.8 |

### Bangalore (INR)

| Category | Base | Per Km | Per Min |
|---|---:|---:|---:|
| bike_rescue | 25 | 7.2 | 1.3 |
| auto | 35 | 10.8 | 2.0 |
| cab_mini | 56 | 14.8 | 2.7 |
| cab_xl | 102 | 22.0 | 3.8 |
| cab_premium | 142 | 31.0 | 5.0 |

---

## 5) Driver Protection Values (Trip Floor + Hourly Guarantee)

### Prayagraj

| Category | Min Trip Payout | Hourly Guarantee |
|---|---:|---:|
| bike_rescue | 42 | 170 |
| auto | 62 | 210 |
| cab_mini | 92 | 270 |
| cab_xl | 132 | 330 |
| cab_premium | 170 | 400 |

### Delhi

| Category | Min Trip Payout | Hourly Guarantee |
|---|---:|---:|
| bike_rescue | 55 | 210 |
| auto | 78 | 260 |
| cab_mini | 112 | 340 |
| cab_xl | 162 | 420 |
| cab_premium | 210 | 520 |

### Bangalore

| Category | Min Trip Payout | Hourly Guarantee |
|---|---:|---:|
| bike_rescue | 58 | 220 |
| auto | 82 | 275 |
| cab_mini | 118 | 360 |
| cab_xl | 170 | 440 |
| cab_premium | 220 | 540 |

---

## 6) Waiting, Pickup Compensation, and Platform Fee

### Waiting charge (after 3-min grace)

| Category | Wait Rate / min |
|---|---:|
| bike_rescue | 1.0 |
| auto | 1.5 |
| cab_mini | 2.0 |
| cab_xl | 2.5 |
| cab_premium | 3.0 |

### Pickup compensation (deadhead)

- `pickupGraceKm = 1.5` for all categories

| Category | Pickup Comp / extra km |
|---|---:|
| bike_rescue | 3 |
| auto | 4 |
| cab_mini | 5 |
| cab_xl | 6 |
| cab_premium | 7 |

### Platform fee %

| Category | Platform Fee % |
|---|---:|
| bike_rescue | 12 |
| auto | 14 |
| cab_mini | 16 |
| cab_xl | 16 |
| cab_premium | 18 |

---

## 7) Surge + Acceptance Parameters (Per City)

### Surge caps

| City | Normal Cap | Event Cap | 5-min max step |
|---|---:|---:|---:|
| Prayagraj | 1.6 | 2.0 | 0.08 |
| Delhi | 1.8 | 2.2 | 0.10 |
| Bangalore | 1.8 | 2.2 | 0.10 |

### ETA target (minutes)

| Category | Prayagraj | Delhi | Bangalore |
|---|---:|---:|---:|
| bike_rescue | 6 | 7 | 7 |
| auto | 7 | 8 | 8 |
| cab_mini | 8 | 9 | 9 |
| cab_xl | 9 | 10 | 10 |
| cab_premium | 9 | 10 | 10 |

### Acceptance targets

| Category | Target accept rate |
|---|---:|
| bike_rescue | 0.78 |
| auto | 0.75 |
| cab_mini | 0.72 |
| cab_xl | 0.70 |
| cab_premium | 0.70 |

`alpha` (acceptance multiplier sensitivity): `0.35` all categories (starter).

---

## 8) Rider Benefit Starter Values

### Acquisition

- First 3 rides: `min(20% of fare, ₹60)` discount.

### Off-peak no-surge windows

- Prayagraj: Mon-Fri `11:00-16:00`
- Delhi: Tue-Thu `11:30-15:30`
- Bangalore: Tue-Thu `11:00-15:00`

### Price lock

- `75 seconds` quote lock in all cities.

---

## 9) Promo Budget Controls (City-Wise)

| City | Weekly promo budget cap |
|---|---:|
| Prayagraj | min(7% projected weekly GMV, ₹2.5L) |
| Delhi | min(8% projected weekly GMV, ₹18L) |
| Bangalore | min(8% projected weekly GMV, ₹22L) |

Global per-ride and user guardrails:

- Per-ride discount cap: `min(25% fare, ₹80)`
- Max discounted rides/user/week: `5`
- Max discount/user/week: `₹250`

---

## 10) Backend Config (Copy-Paste JSON)

```json
{
  "version": "pricing_policy_v1_1",
  "currency": "INR",
  "global": {
    "waitGraceMin": 3,
    "pickupGraceKm": 1.5,
    "quoteLockSeconds": 75,
    "acceptanceAlpha": 0.35,
    "cancelTarget": 0.12
  },
  "categories": {
    "bike_rescue": { "platformFeePct": 12, "waitRatePerMin": 1.0, "pickupCompPerKm": 3, "targetAcceptRate": 0.78, "kSurge": 0.28 },
    "auto":        { "platformFeePct": 14, "waitRatePerMin": 1.5, "pickupCompPerKm": 4, "targetAcceptRate": 0.75, "kSurge": 0.26 },
    "cab_mini":    { "platformFeePct": 16, "waitRatePerMin": 2.0, "pickupCompPerKm": 5, "targetAcceptRate": 0.72, "kSurge": 0.24 },
    "cab_xl":      { "platformFeePct": 16, "waitRatePerMin": 2.5, "pickupCompPerKm": 6, "targetAcceptRate": 0.70, "kSurge": 0.22 },
    "cab_premium": { "platformFeePct": 18, "waitRatePerMin": 3.0, "pickupCompPerKm": 7, "targetAcceptRate": 0.70, "kSurge": 0.20 }
  },
  "cities": {
    "prayagraj": {
      "surgeCapNormal": 1.6,
      "surgeCapEvent": 2.0,
      "surgeStep5Min": 0.08,
      "promoBudgetRule": "min(7%_weekly_GMV,250000)",
      "offPeakNoSurgeWindow": "Mon-Fri 11:00-16:00",
      "rateCard": {
        "bike_rescue": { "base": 18, "perKm": 5.5, "perMin": 0.9, "minTripPayout": 42, "hourlyGuarantee": 170, "etaTargetMin": 6 },
        "auto":        { "base": 24, "perKm": 8.0, "perMin": 1.4, "minTripPayout": 62, "hourlyGuarantee": 210, "etaTargetMin": 7 },
        "cab_mini":    { "base": 38, "perKm": 11.5, "perMin": 1.9, "minTripPayout": 92, "hourlyGuarantee": 270, "etaTargetMin": 8 },
        "cab_xl":      { "base": 72, "perKm": 17.0, "perMin": 2.8, "minTripPayout": 132, "hourlyGuarantee": 330, "etaTargetMin": 9 },
        "cab_premium": { "base": 95, "perKm": 23.0, "perMin": 3.8, "minTripPayout": 170, "hourlyGuarantee": 400, "etaTargetMin": 9 }
      }
    },
    "delhi": {
      "surgeCapNormal": 1.8,
      "surgeCapEvent": 2.2,
      "surgeStep5Min": 0.10,
      "promoBudgetRule": "min(8%_weekly_GMV,1800000)",
      "offPeakNoSurgeWindow": "Tue-Thu 11:30-15:30",
      "rateCard": {
        "bike_rescue": { "base": 24, "perKm": 7.0, "perMin": 1.2, "minTripPayout": 55, "hourlyGuarantee": 210, "etaTargetMin": 7 },
        "auto":        { "base": 32, "perKm": 10.0, "perMin": 1.9, "minTripPayout": 78, "hourlyGuarantee": 260, "etaTargetMin": 8 },
        "cab_mini":    { "base": 52, "perKm": 14.0, "perMin": 2.5, "minTripPayout": 112, "hourlyGuarantee": 340, "etaTargetMin": 9 },
        "cab_xl":      { "base": 94, "perKm": 21.0, "perMin": 3.6, "minTripPayout": 162, "hourlyGuarantee": 420, "etaTargetMin": 10 },
        "cab_premium": { "base": 130, "perKm": 29.0, "perMin": 4.8, "minTripPayout": 210, "hourlyGuarantee": 520, "etaTargetMin": 10 }
      }
    },
    "bangalore": {
      "surgeCapNormal": 1.8,
      "surgeCapEvent": 2.2,
      "surgeStep5Min": 0.10,
      "promoBudgetRule": "min(8%_weekly_GMV,2200000)",
      "offPeakNoSurgeWindow": "Tue-Thu 11:00-15:00",
      "rateCard": {
        "bike_rescue": { "base": 25, "perKm": 7.2, "perMin": 1.3, "minTripPayout": 58, "hourlyGuarantee": 220, "etaTargetMin": 7 },
        "auto":        { "base": 35, "perKm": 10.8, "perMin": 2.0, "minTripPayout": 82, "hourlyGuarantee": 275, "etaTargetMin": 8 },
        "cab_mini":    { "base": 56, "perKm": 14.8, "perMin": 2.7, "minTripPayout": 118, "hourlyGuarantee": 360, "etaTargetMin": 9 },
        "cab_xl":      { "base": 102, "perKm": 22.0, "perMin": 3.8, "minTripPayout": 170, "hourlyGuarantee": 440, "etaTargetMin": 10 },
        "cab_premium": { "base": 142, "perKm": 31.0, "perMin": 5.0, "minTripPayout": 220, "hourlyGuarantee": 540, "etaTargetMin": 10 }
      }
    }
  }
}
```

---

## 11) First 14-Day Calibration Triggers

Increase category fare 4-8% in a city if:
- acceptance < target by >6 points AND
- fulfillment < 88%

Reduce rider-facing fare 3-5% if:
- conversion < city baseline by >4 points AND
- acceptance is healthy (>= target)

Increase hourly guarantee 8-12% if:
- online supply growth stalls for 3 consecutive days.

---

## 12) Launch Recommendation

- Start with Prayagraj values in one pilot zone first.
- Enable Delhi/Bangalore with stricter surge smoothing on day 1.
- Review KPI board daily for first 2 weeks; adjust only once per day to avoid oscillation.

