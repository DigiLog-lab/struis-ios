#include <stdbool.h>
#include <stdint.h>

bool hyotan_rg_interrupt(void);
int32_t hyotan_rg_run(int32_t argc, const char *const *argv,
                     int32_t stdin_fd, int32_t stdout_fd, int32_t stderr_fd,
                     bool terminal_input);
