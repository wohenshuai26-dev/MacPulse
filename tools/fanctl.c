// fanctl — minimal SMC fan control for Apple Silicon (needs root to write).
//   fanctl get              show fan speed / mode / limits
//   fanctl set <rpm>        manual mode, target clamped to [min, max]
//   fanctl auto             back to automatic control
//   fanctl test <rpm>       set <rpm> for 10 s while printing speed, then auto
// Build: clang -framework IOKit -o fanctl tools/fanctl.c
#include <IOKit/IOKitLib.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct { char major, minor, build, reserved; UInt16 release; } SMCVersion;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyInfoData;
typedef struct {
    UInt32 key; SMCVersion vers; SMCPLimitData pLimitData; SMCKeyInfoData keyInfo;
    char result, status, data8; UInt32 data32; unsigned char bytes[32];
} SMCKeyData;

static io_connect_t conn;
static UInt32 cc(const char *s) { return ((UInt32)s[0] << 24) | ((UInt32)s[1] << 16) | ((UInt32)s[2] << 8) | (UInt32)s[3]; }
static kern_return_t call(SMCKeyData *in, SMCKeyData *out) {
    size_t sz = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(conn, 2, in, sizeof(SMCKeyData), out, &sz);
}
static int keyInfo(const char *key, SMCKeyInfoData *info) {
    SMCKeyData in = {0}, out = {0};
    in.key = cc(key); in.data8 = 9;
    if (call(&in, &out) != KERN_SUCCESS || out.result) return -1;
    *info = out.keyInfo; return 0;
}
static int readBytes(const char *key, unsigned char *b, SMCKeyInfoData *info) {
    if (keyInfo(key, info)) return -1;
    SMCKeyData in = {0}, out = {0};
    in.key = cc(key); in.keyInfo.dataSize = info->dataSize; in.data8 = 5;
    if (call(&in, &out) != KERN_SUCCESS || out.result) return -1;
    memcpy(b, out.bytes, 32); return 0;
}
static int writeBytes(const char *key, const void *b, UInt32 size) {
    SMCKeyInfoData info;
    if (keyInfo(key, &info) || info.dataSize != size) return -1;
    SMCKeyData in = {0}, out = {0};
    in.key = cc(key); in.keyInfo.dataSize = size; in.data8 = 6;
    memcpy(in.bytes, b, size);
    kern_return_t kr = call(&in, &out);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "write %s failed: 0x%x%s\n", key, kr, kr == kIOReturnNotPrivileged ? " (need sudo)" : ""); return -1; }
    if (out.result) { fprintf(stderr, "write %s rejected by SMC: %d\n", key, out.result); return -1; }
    return 0;
}
static float readFloat(const char *key) {
    unsigned char b[32]; SMCKeyInfoData i; float f = 0;
    if (!readBytes(key, b, &i)) memcpy(&f, b, 4);
    return f;
}
static int readMode(void) {
    unsigned char b[32]; SMCKeyInfoData i;
    return readBytes("F0md", b, &i) ? -1 : b[0];
}
static int setAuto(void) { unsigned char m = 0; return writeBytes("F0md", &m, 1); }
static int setRPM(float rpm) {
    float lo = readFloat("F0Mn"), hi = readFloat("F0Mx");
    if (rpm < lo) rpm = lo;
    if (rpm > hi) rpm = hi;
    unsigned char m = 1;
    if (writeBytes("F0md", &m, 1)) return -1;
    if (writeBytes("F0Tg", &rpm, 4)) return -1;
    printf("manual target %.0f RPM\n", rpm);
    return 0;
}
static void show(void) {
    printf("speed %.0f RPM  target %.0f  mode %s  range %.0f–%.0f\n", readFloat("F0Ac"), readFloat("F0Tg"),
           readMode() == 1 ? "manual" : "auto", readFloat("F0Mn"), readFloat("F0Mx"));
}
static void onSignal(int sig) { (void)sig; setAuto(); _exit(1); }

int main(int argc, char **argv) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn) != KERN_SUCCESS) { fprintf(stderr, "cannot open SMC\n"); return 1; }
    if (argc < 2 || !strcmp(argv[1], "get")) { show(); return 0; }
    if (!strcmp(argv[1], "auto")) { int r = setAuto(); show(); return r ? 1 : 0; }
    if (!strcmp(argv[1], "set") && argc > 2) { int r = setRPM(atof(argv[2])); show(); return r ? 1 : 0; }
    if (!strcmp(argv[1], "test") && argc > 2) {
        signal(SIGINT, onSignal); signal(SIGTERM, onSignal);
        show();
        if (setRPM(atof(argv[2]))) { setAuto(); return 1; }
        for (int i = 1; i <= 10; i++) { sleep(1); printf("  %2ds ", i); show(); }
        int r = setAuto();
        printf("restored automatic control\n");
        for (int i = 1; i <= 4; i++) { sleep(1); printf("  +%ds ", i); show(); }
        return r ? 1 : 0;
    }
    fprintf(stderr, "usage: fanctl get | set <rpm> | auto | test <rpm>\n");
    return 2;
}
