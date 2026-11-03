// SMART 진단: NVMe SMART 로그(512바이트)를 관리자 권한 없이 읽어 NVMe 규격 위치대로 풀어 본다.
// 사용법: smart_probe   (SMART를 지원하는 디스크마다 한 번 읽어 출력)
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

static uint64_t le64(const unsigned char *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}
static int high_nonzero(const unsigned char *p) {
    for (int i = 8; i < 16; i++) if (p[i]) return 1;
    return 0;
}
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static int is_capable(io_registry_entry_t e) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, CFSTR("NVMe SMART Capable"), kCFAllocatorDefault, 0);
    if (!v) return 0;
    int ok = 0;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) ok = CFBooleanGetValue((CFBooleanRef)v);
    else if (CFGetTypeID(v) == CFNumberGetTypeID()) { int n = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n); ok = n != 0; }
    CFRelease(v);
    return ok;
}

static void bsd_name(io_registry_entry_t e, char *out, size_t len) {
    snprintf(out, len, "?");
    CFTypeRef v = IORegistryEntrySearchCFProperty(e, kIOServicePlane, CFSTR("BSD Name"), kCFAllocatorDefault, kIORegistryIterateRecursively);
    if (v) {
        if (CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString((CFStringRef)v, out, len, kCFStringEncodingUTF8);
        CFRelease(v);
    }
}

static void read_one(io_registry_entry_t dev, const char *name) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    uint64_t t0 = now_ns();
    kern_return_t kr = IOCreatePlugInInterfaceForService(dev, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || !plugin) { printf("%s\tplugin_error\t0x%x\n", name, kr); return; }
    IONVMeSMARTInterface **smart = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (hr != S_OK || !smart) { printf("%s\tquery_error\t0x%x\n", name, (unsigned)hr); IODestroyPlugInInterface(plugin); return; }
    unsigned char b[512];
    memset(b, 0, sizeof b);
    uint64_t t1 = now_ns();
    IOReturn r = (*smart)->SMARTReadData(smart, (struct nvme_smart_log *)b);
    uint64_t t2 = now_ns();
    printf("%s\tread_result\t0x%x\n", name, r);
    printf("%s\topen_us\t%.0f\n", name, (t1 - t0) / 1e3);
    printf("%s\tread_us\t%.0f\n", name, (t2 - t1) / 1e3);
    if (r == kIOReturnSuccess) {
        printf("%s\tcritical_warning\t0x%02x\n", name, b[0]);
        printf("%s\ttemperature_K\t%u\n", name, b[1] | (b[2] << 8));
        printf("%s\tavailable_spare_pct\t%u\n", name, b[3]);
        printf("%s\tspare_threshold_pct\t%u\n", name, b[4]);
        printf("%s\tpercentage_used\t%u\n", name, b[5]);
        const char *names[] = {"data_units_read", "data_units_written", "host_read_commands", "host_write_commands",
                               "controller_busy_minutes", "power_cycles", "power_on_hours", "unsafe_shutdowns",
                               "media_errors", "error_log_entries"};
        for (int i = 0; i < 10; i++) {
            const unsigned char *p = b + 32 + 16 * i;
            printf("%s\t%s\t%llu%s\n", name, names[i], (unsigned long long)le64(p), high_nonzero(p) ? " (+상위 64비트)" : "");
        }
        printf("%s\twarning_temp_minutes\t%u\n", name, b[192] | (b[193] << 8) | (b[194] << 16) | ((unsigned)b[195] << 24));
        printf("%s\tcritical_temp_minutes\t%u\n", name, b[196] | (b[197] << 8) | (b[198] << 16) | ((unsigned)b[199] << 24));
        for (int i = 0; i < 8; i++) {
            unsigned v = b[200 + 2 * i] | (b[201 + 2 * i] << 8);
            if (v) printf("%s\ttemp_sensor_%d_K\t%u\n", name, i + 1, v);
        }
    }
    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
}

int main(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) != KERN_SUCCESS) return 1;
    io_registry_entry_t drv;
    int found = 0;
    while ((drv = IOIteratorNext(it))) {
        char name[64];
        bsd_name(drv, name, sizeof name);
        io_registry_entry_t parent = 0;
        if (IORegistryEntryGetParentEntry(drv, kIOServicePlane, &parent) == KERN_SUCCESS) {
            if (is_capable(parent)) { found++; read_one(parent, name); }
            else printf("%s\tsmart_capable\tno\n", name);
            IOObjectRelease(parent);
        }
        IOObjectRelease(drv);
    }
    IOObjectRelease(it);
    printf("-\tcapable_disks\t%d\n", found);
    return 0;
}
