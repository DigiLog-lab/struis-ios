#import <ios_system/ios_system.h>
#include <unistd.h>
#include <stdbool.h>
extern int hyotan_rg_run(int argc, const char *const *argv, int input, int output, int error, bool terminal_input);
__attribute__((visibility("default"))) int hyotan_rg_main(int argc, char **argv) {
    int input = dup(fileno(ios_stdin()));
    int output = dup(fileno(ios_stdout()));
    int error = dup(fileno(ios_stderr()));
    if (input < 0 || output < 0 || error < 0) {
        if (input >= 0) close(input);
        if (output >= 0) close(output);
        if (error >= 0) close(error);
        fprintf(ios_stderr(), "rg: cannot duplicate standard streams\n");
        return 2;
    }
    return hyotan_rg_run(argc, (const char *const *)argv, input, output, error, ios_isatty(fileno(ios_stdin())) != 0);
}
