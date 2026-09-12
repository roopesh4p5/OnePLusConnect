#ifndef CGVirtualDisplayShim_h
#define CGVirtualDisplayShim_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a live virtual display.
typedef void *OPCVirtualDisplayHandle;

/// Returns true when the private CGVirtualDisplay classes are present on this macOS build.
bool OPCVirtualDisplayIsAvailable(void);

/// Creates a virtual display. `modeWidths`/`modeHeights`/`modeRefreshRates` describe the
/// modes offered to macOS (count = modeCount). The first mode is the preferred one.
/// Returns NULL on failure; `errorOut` (may be NULL) receives a static description.
OPCVirtualDisplayHandle OPCVirtualDisplayCreate(const char *name,
                                                uint32_t maxWidth,
                                                uint32_t maxHeight,
                                                double widthMillimeters,
                                                double heightMillimeters,
                                                uint32_t serialNumber,
                                                const uint32_t *modeWidths,
                                                const uint32_t *modeHeights,
                                                const double *modeRefreshRates,
                                                int modeCount,
                                                bool hiDPI,
                                                const char **errorOut);

/// Returns the CGDirectDisplayID for the virtual display (0 if unknown).
uint32_t OPCVirtualDisplayGetID(OPCVirtualDisplayHandle handle);

/// Applies a new mode list to an existing virtual display.
bool OPCVirtualDisplayApplyModes(OPCVirtualDisplayHandle handle,
                                 const uint32_t *modeWidths,
                                 const uint32_t *modeHeights,
                                 const double *modeRefreshRates,
                                 int modeCount,
                                 bool hiDPI);

/// Destroys the virtual display and releases the handle.
void OPCVirtualDisplayDestroy(OPCVirtualDisplayHandle handle);

#ifdef __cplusplus
}
#endif

#endif /* CGVirtualDisplayShim_h */
