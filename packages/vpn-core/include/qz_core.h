// C ABI of the 轻舟 Rust core for mobile apps. See src/mobile.rs.
#ifndef QZ_CORE_H
#define QZ_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Handles one `{"channel":..., "payload":...}` JSON request against the
/// data directory `root`. Returns `{"ok":true,"data":...}` or
/// `{"ok":false,"error":{"code":...,"message":...}}`. Calls are serialized
/// internally and may block on file IO; do not call from the main thread.
/// The reply must be released with `qz_core_free`.
char *qz_core_call(const char *root, const char *request);

/// Releases a reply returned by `qz_core_call`. Accepts NULL.
void qz_core_free(char *reply);

#ifdef __cplusplus
}
#endif

#endif
