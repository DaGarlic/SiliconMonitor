#include "csmc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

enum { kSMCUserClientMethod = 2, kCmdReadBytes = 5, kCmdWriteBytes = 6, kCmdReadIndex = 8, kCmdGetKeyInfo = 9 };

static io_connect_t conn = 0;

int smc_open(void) {
    if (conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? 0 : -1;
}

static kern_return_t call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(conn, kSMCUserClientMethod, in, sizeof(SMCKeyData), out, &outSize);
}

int smc_read(uint32_t key, uint8_t *out, uint32_t *size, uint32_t *type) {
    if (!conn) return -1;
    SMCKeyData in, res;
    memset(&in, 0, sizeof in); memset(&res, 0, sizeof res);
    in.key = key; in.data8 = kCmdGetKeyInfo;
    if (call(&in, &res) != KERN_SUCCESS || res.result != 0) return -1;
    uint32_t sz = res.keyInfo.dataSize;
    if (sz == 0 || sz > 32) return -1;
    *size = sz; *type = res.keyInfo.dataType;
    memset(&in, 0, sizeof in);
    in.key = key; in.keyInfo.dataSize = sz; in.data8 = kCmdReadBytes;
    memset(&res, 0, sizeof res);
    if (call(&in, &res) != KERN_SUCCESS || res.result != 0) return -1;
    memcpy(out, res.bytes, sz);
    return 0;
}

uint32_t smc_key_at(uint32_t index) {
    if (!conn) return 0;
    SMCKeyData in, res;
    memset(&in, 0, sizeof in); memset(&res, 0, sizeof res);
    in.data8 = kCmdReadIndex; in.data32 = index;
    if (call(&in, &res) != KERN_SUCCESS) return 0;
    return res.key;
}

int smc_write(uint32_t key, const uint8_t *bytes, uint32_t size) {
    if (!conn) return -1;
    SMCKeyData in, res;
    memset(&in, 0, sizeof in); memset(&res, 0, sizeof res);
    in.key = key; in.data8 = kCmdGetKeyInfo;
    if (call(&in, &res) != KERN_SUCCESS || res.result != 0) return -2;
    if (res.keyInfo.dataSize != size || size > 32) return -3;
    SMCKeyInfo info = res.keyInfo;
    memset(&in, 0, sizeof in); memset(&res, 0, sizeof res);
    in.key = key; in.keyInfo = info; in.data8 = kCmdWriteBytes;
    memcpy(in.bytes, bytes, size);
    if (call(&in, &res) != KERN_SUCCESS) return -4;
    return res.result;
}
