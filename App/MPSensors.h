#pragma once
#include <CoreFoundation/CoreFoundation.h>

CF_IMPLICIT_BRIDGING_ENABLED
CF_ASSUME_NONNULL_BEGIN

/// Reads every HID temperature sensor (Apple Silicon) and returns
/// a dictionary of { sensor product name : temperature in °C }.
CFDictionaryRef _Nullable MPCopyTemperatureSensors(void) CF_RETURNS_RETAINED;

/// Reads fan speeds from the SMC. Writes up to `max` entries and returns the number of
/// fans found (0 on fanless Macs or on error).
int MPReadFans(double *actualRPM, double *maxRPM, int max);

/// Fan mode of fan 0: 1 = manual, 0 = automatic, -1 = unknown.
int MPReadFanMode(void);

/// Root only. Puts every fan in manual mode with `rpm` as target (clamped to each
/// fan's [min, max]). Returns 0 on success.
int MPSetFanManual(double rpm);

/// Root only. Hands every fan back to automatic (system) control. Returns 0 on success.
int MPSetFanAuto(void);

CF_ASSUME_NONNULL_END
CF_IMPLICIT_BRIDGING_DISABLED
