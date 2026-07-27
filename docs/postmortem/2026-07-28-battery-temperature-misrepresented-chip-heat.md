# Battery Temperature Misrepresented Chip Heat

## What happened

Canaryd reported a battery temperature near 40°C while another monitor reported
CPU and GPU temperatures near 70°C. Canaryd could mark the system as normal even
when the chip sensors were hot.

## Root cause

The first thermal process monitor used the `AppleSmartBattery` temperature from
IORegistry. It treated that value as thermal pressure evidence. A battery sensor
does not measure CPU or GPU temperature.

The implementation did not have a user-level source for Apple Silicon chip
sensor data.

## Fix applied

- Added `macmon 0.8.0` as a pinned runtime sensor helper.
- Read three CPU and GPU temperature samples without `sudo`.
- Kept the highest CPU and GPU average in the sample window.
- Added thermal pressure at 70°C for either chip sensor.
- Kept battery temperature as a separate metric.
- Removed battery temperature from chip thermal pressure decisions.
- Added explicit fallback output when chip temperature is unavailable.
- Sent the warning on the first hot observation while keeping actions confirmed.
- Added a 15-minute warning cooldown per leading process.
- Replaced the suppressible banner with a 30-second foreground warning alert.
- Added banner fallback and warning delivery history.
- Fixed DETS event traversal so thermal history shows every event.
- Added a dedicated one-minute thermal agent.
- Kept the full health check at five minutes to limit clipboard probes.
- Added focused tests for parsing, version checks, thresholds, and labels.

## What we learned

- A temperature value must name its physical sensor.
- Battery temperature must not stand in for CPU or GPU temperature.
- A dependency version and its output schema must be verified together.
- A short sample window is more reliable than one instantaneous value.
- A five-minute interval can miss a short temperature spike.
