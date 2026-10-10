#include <stdint.h>
#include <stddef.h>
int32_t hyotan_codex_start(uint16_t port, const char *token_file);
// Actual listener port, zero before successful startup.
uint16_t hyotan_codex_port(void);
// Moves the running server to a new loopback listener (iOS reclaims a suspended
// app's listening socket). Returns the new port, or zero.
uint16_t hyotan_codex_rebind(void);
int32_t hyotan_codex_install_operation_harness(int32_t directory_fd, const char *root, const char *owner, uint64_t generation);
size_t hyotan_codex_error(char *buffer, size_t capacity);
// Latest panic source location (file:line) and the number of panics in this process.
size_t hyotan_codex_panic_site(char *buffer, size_t capacity);
uint32_t hyotan_codex_panic_count(void);
