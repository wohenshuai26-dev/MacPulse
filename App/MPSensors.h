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

CF_ASSUME_NONNULL_END
CF_IMPLICIT_BRIDGING_DISABLED
