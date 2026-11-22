#include "MPSensors.h"
#include <stdio.h>

// Private IOKit HID event-system API (same approach as Stats / iStat Menus).
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);

#define kIOHIDEventTypeTemperature 15

static IOHIDEventSystemClientRef sharedClient(void) {
    static IOHIDEventSystemClientRef client = NULL;
    if (client) return client;
    client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return NULL;
    int page = 0xff00, usage = 5; // AppleVendor / TemperatureSensor
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { p, u };
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match); CFRelease(p); CFRelease(u);
    return client;
}

CFDictionaryRef MPCopyTemperatureSensors(void) {
    IOHIDEventSystemClientRef client = sharedClient();
    if (!client) return NULL;
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return NULL;

    CFMutableDictionaryRef out = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef name = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (!name) continue;
        if (CFGetTypeID(name) == CFStringGetTypeID()) {
            IOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, kIOHIDEventTypeTemperature, 0, 0);
            if (ev) {
                double t = IOHIDEventGetFloatValue(ev, kIOHIDEventTypeTemperature << 16);
                CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &t);
                CFDictionarySetValue(out, name, n);
                CFRelease(n);
                CFRelease(ev);
            }
        }
        CFRelease(name);
    }
    CFRelease(services);
    return out;
}

// MARK: - SMC (fan speeds)

#include <IOKit/IOKitLib.h>
#include <string.h>

typedef struct { char major, minor, build, reserved; UInt16 release; } SMCVersion;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyInfoData;
typedef struct {
    UInt32 key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    char result, status, data8;
    UInt32 data32;
    unsigned char bytes[32];
} SMCKeyData;

enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCGetKeyInfo = 9 };

static io_connect_t smcConnection(void) {
    static io_connect_t conn = 0;
    static int tried = 0;
    if (conn || tried) return conn;
    tried = 1;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 0;
    if (IOServiceOpen(svc, mach_task_self(), 0, &conn) != KERN_SUCCESS) conn = 0;
    IOObjectRelease(svc);
    return conn;
}

static UInt32 fourCC(const char *s) {
    return ((UInt32)s[0] << 24) | ((UInt32)s[1] << 16) | ((UInt32)s[2] << 8) | (UInt32)s[3];
}

static int smcCall(SMCKeyData *in, SMCKeyData *out) {
    size_t size = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(smcConnection(), kSMCHandleYPCEvent, in, sizeof(SMCKeyData), out, &size);
}

/// Reads a numeric SMC key ("flt ", "fpe2" or "ui8 "). Returns 0 on success.
static int smcReadNumber(const char *key, double *value) {
    if (!smcConnection()) return -1;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourCC(key);
    in.data8 = kSMCGetKeyInfo;
    if (smcCall(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    SMCKeyInfoData info = out.keyInfo;

    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourCC(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = kSMCReadKey;
    if (smcCall(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;

    if (info.dataType == fourCC("flt ") && info.dataSize == 4) {
        float f; memcpy(&f, out.bytes, 4); *value = f;
    } else if (info.dataType == fourCC("fpe2") && info.dataSize == 2) { // Intel Macs
        *value = ((out.bytes[0] << 8) | out.bytes[1]) / 4.0;
    } else if (info.dataType == fourCC("ui8 ")) {
        *value = out.bytes[0];
    } else {
        return -1;
    }
    return 0;
}

int MPReadFans(double *actualRPM, double *maxRPM, int max) {
    double n = 0;
    if (smcReadNumber("FNum", &n) != 0) return 0;
    int count = (int)n < max ? (int)n : max;
    for (int i = 0; i < count; i++) {
        char key[5];
        snprintf(key, sizeof key, "F%dAc", i);
        if (smcReadNumber(key, &actualRPM[i]) != 0) actualRPM[i] = 0;
        snprintf(key, sizeof key, "F%dMx", i);
        if (smcReadNumber(key, &maxRPM[i]) != 0) maxRPM[i] = 0;
    }
    return count;
}

// MARK: - SMC writes (fan control, root only)

enum { kSMCWriteKey = 6 };

static int smcWrite(const char *key, const void *data, UInt32 size) {
    if (!smcConnection()) return -1;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourCC(key);
    in.data8 = kSMCGetKeyInfo;
    if (smcCall(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    if (out.keyInfo.dataSize != size) return -1;

    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourCC(key);
    in.keyInfo.dataSize = size;
    in.data8 = kSMCWriteKey;
    memcpy(in.bytes, data, size);
    if (smcCall(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    return 0;
}

static int fanCount(void) {
    double n = 0;
    return smcReadNumber("FNum", &n) == 0 ? (int)n : 0;
}

int MPReadFanMode(void) {
    double m = -1;
    return smcReadNumber("F0md", &m) == 0 ? (int)m : -1;
}

int MPSetFanManual(double rpm) {
    int n = fanCount();
    if (n == 0) return -1;
    for (int i = 0; i < n; i++) {
        char key[5];
        double lo = 0, hi = 0;
        snprintf(key, sizeof key, "F%dMn", i); smcReadNumber(key, &lo);
        snprintf(key, sizeof key, "F%dMx", i); smcReadNumber(key, &hi);
        float target = (float)rpm;
        if (lo > 0 && target < lo) target = (float)lo;
        if (hi > 0 && target > hi) target = (float)hi;
        unsigned char manual = 1;
        snprintf(key, sizeof key, "F%dmd", i);
        if (smcWrite(key, &manual, 1) != 0) return -1;
        snprintf(key, sizeof key, "F%dTg", i);
        if (smcWrite(key, &target, 4) != 0) return -1;
    }
    return 0;
}

int MPSetFanAuto(void) {
    int n = fanCount(), rc = 0;
    for (int i = 0; i < n; i++) {
        char key[5];
        unsigned char automatic = 0;
        snprintf(key, sizeof key, "F%dmd", i);
        if (smcWrite(key, &automatic, 1) != 0) rc = -1;
    }
    return rc;
}
