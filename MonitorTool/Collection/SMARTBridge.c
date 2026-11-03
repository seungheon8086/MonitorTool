// NVMe SMART 로그 읽기 (SMARTBridge.h 참고)
#include "SMARTBridge.h"

#include <stdlib.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

struct MTSMARTHandle {
    IOCFPlugInInterface **plugin;
    IONVMeSMARTInterface **smart;
};

MTSMARTHandle *MTSMARTOpen(io_service_t device, int32_t *error) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(device, kIONVMeSMARTUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || plugin == NULL) {
        if (error) *error = (int32_t)kr;
        return NULL;
    }
    IONVMeSMARTInterface **smart = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (hr != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plugin);
        if (error) *error = (int32_t)hr;
        return NULL;
    }
    MTSMARTHandle *handle = calloc(1, sizeof(MTSMARTHandle));
    if (handle == NULL) {
        (*smart)->Release(smart);
        IODestroyPlugInInterface(plugin);
        if (error) *error = -1;
        return NULL;
    }
    handle->plugin = plugin;
    handle->smart = smart;
    if (error) *error = 0;
    return handle;
}

int32_t MTSMARTRead(MTSMARTHandle *handle, uint8_t *buffer) {
    if (handle == NULL || buffer == NULL) return -1;
    memset(buffer, 0, 512);
    return (int32_t)(*handle->smart)->SMARTReadData(handle->smart, (struct nvme_smart_log *)buffer);
}

void MTSMARTClose(MTSMARTHandle *handle) {
    if (handle == NULL) return;
    (*handle->smart)->Release(handle->smart);
    IODestroyPlugInInterface(handle->plugin);
    free(handle);
}
