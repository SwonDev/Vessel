#include <cpuid.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static sigjmp_buf recovery_point;
static volatile sig_atomic_t trapped_signal;

static void handle_signal(int signal_number)
{
    trapped_signal = signal_number;
    siglongjmp(recovery_point, 1);
}

static uint64_t read_gs_base(void)
{
    uint64_t value;
    __asm__ volatile("rdgsbase %0" : "=r"(value));
    return value;
}

static void write_gs_base(uint64_t value)
{
    __asm__ volatile("wrgsbase %0" : : "r"(value) : "memory");
}

int main(void)
{
    struct sigaction action;
    unsigned int eax = 0;
    unsigned int ebx = 0;
    unsigned int ecx = 0;
    unsigned int edx = 0;
    uint64_t initial_base = 0;
    uint64_t verified_base = 0;

    memset(&action, 0, sizeof(action));
    action.sa_handler = handle_signal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_NODEFER;
    sigaction(SIGILL, &action, NULL);
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);

    __cpuid_count(7, 0, eax, ebx, ecx, edx);
    printf("cpuid_fsgsbase=%u\n", ebx & 1u);

    trapped_signal = 0;
    if (sigsetjmp(recovery_point, 1) != 0) {
        printf("rdgsbase=trapped signal=%d\n", trapped_signal);
        return EXIT_SUCCESS;
    }

    initial_base = read_gs_base();
    printf("rdgsbase=ok base=0x%llx\n", (unsigned long long)initial_base);

    trapped_signal = 0;
    if (sigsetjmp(recovery_point, 1) != 0) {
        printf("wrgsbase_same=trapped signal=%d\n", trapped_signal);
        return EXIT_SUCCESS;
    }

    write_gs_base(initial_base);
    verified_base = read_gs_base();
    printf("wrgsbase_same=ok preserved=%u\n", verified_base == initial_base);
    return EXIT_SUCCESS;
}
