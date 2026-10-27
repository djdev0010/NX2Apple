// nvdrv (the NVIDIA driver service): the host takes over NVN entirely and has no use for it; only the SDK movie library's hardware decoder (subsdk0's NVOMX → NvRmChannelOpen) opens /dev/nvhost-* directly.
// The original NvOsDrvOpen first connects to the nvdrv service; the host has no service process and the SDK aborts on the spot (Engage aborted when Unity created a decoder at startup).
// Takeover: opening a device always fails (fd = -1), and ioctls / mappings / event queries all return an error, so the decoder takes its own failure path
#include "hle.h"

#define NV_ERR 3   // NvError: non-zero means failure (3 = not initialized)

HLE_FORCE("NvOsDrvOpen", "nvdrv open device: the host has no nvdrv, returns −1", int, h_nvos_Open, const char *path) {
    static int red; if (!red++) LOG("[RED] nvdrv: cannot open %s (the host has no nvdrv; only hardware movie decoding uses it)", path ? path : "(null)");
    return -1;
}
HLE_FORCE("NvOsDrvClose", "nvdrv close device; nothing to do", void, h_nvos_Close, int fd) { (void)fd; }
HLE_FORCE("NvOsDrvIoctl", "nvdrv ioctl: returns an error", int, h_nvos_Ioctl, int fd, uint32_t req, void *arg, size_t n) { (void)fd; (void)req; (void)arg; (void)n; return NV_ERR; }
HLE_FORCE("NvOsDrvIoctl2", "nvdrv ioctl2: returns an error", int, h_nvos_Ioctl2, int fd, uint32_t req, void *arg, size_t n) { (void)fd; (void)req; (void)arg; (void)n; return NV_ERR; }
HLE_FORCE("NvOsDrvIoctl3", "nvdrv ioctl3: returns an error", int, h_nvos_Ioctl3, int fd, uint32_t req, void *arg, size_t n) { (void)fd; (void)req; (void)arg; (void)n; return NV_ERR; }
HLE_FORCE("NvOsDrvMapSharedMem", "nvdrv shared memory map: returns an error", int, h_nvos_MapShared, int fd) { (void)fd; return NV_ERR; }
HLE_FORCE("_Z17NvOsDrvQueryEventijPN2nn2os15SystemEventTypeE", "nvdrv query event: returns an error", int, h_nvos_QueryEvent, int fd, uint32_t id, void *ev) { (void)fd; (void)id; (void)ev; return NV_ERR; }

// The SDK's graphics memory figures come from nvdrv's GetStatus (command 6) and DumpGraphicsMemoryInfo (command 9) on the service object nv::InitializeGraphics connects;
// with no nvdrv that object stays null, and SDK 3.5.1 reads it (sdk+0x24a51c, a null read when Hyrule Warriors: Definitive Edition asks before InitializeGraphics for its debug print).
// nv::MemoryInfo is four 64-bit sizes; the host's GPU memory is Metal's, so the driver has nothing to report
HLE_FORCE("_ZN2nv21GetGraphicsMemoryInfoEPNS_10MemoryInfoE", "nvdrv graphics memory status: the host has no nvdrv, reports zeros", void, h_nv_GetGfxMemInfo, int64_t *info) { if (info) memset(info, 0, 4 * sizeof *info); }
HLE_FORCE("_ZN2nv22DumpGraphicsMemoryInfoEv", "nvdrv graphics memory dump to the driver log; nothing to do", void, h_nv_DumpGfxMemInfo, void) { }
