// NVMe SMART 로그를 읽는 작은 C 함수예요. (Diagnostics/DiskProbe/smart_probe.c와 같은 방법)
// IOKit의 SMART 플러그인은 COM 방식 함수 표라서 Swift에서 직접 부르기 어려워 C로 둬요.
#ifndef SMARTBridge_h
#define SMARTBridge_h

#include <stdint.h>
#include <IOKit/IOKitLib.h>

/// 열어 둔 SMART 플러그인 (한 번 열어 두고 다시 써요. 여는 데 5~8 ms)
typedef struct MTSMARTHandle MTSMARTHandle;

/// SMART를 지원하는 장치(IOBlockStorageDriver의 부모)로 플러그인을 열어요. 실패하면 NULL이고 error에 이유 코드.
MTSMARTHandle *MTSMARTOpen(io_service_t device, int32_t *error);

/// SMART 로그 512바이트를 buffer에 읽어요. 성공하면 0(kIOReturnSuccess).
int32_t MTSMARTRead(MTSMARTHandle *handle, uint8_t *buffer);

/// 플러그인을 닫아요.
void MTSMARTClose(MTSMARTHandle *handle);

#endif
