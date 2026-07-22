#include <windows.h>
#include <stdint.h>
#include <stdio.h>

static void *direct_get_current_fiber(void)
{
    void *fiber;
    __asm__ volatile("movq %%gs:0x20,%0" : "=r"(fiber));
    return fiber;
}

int main(void)
{
    void *converted = ConvertThreadToFiber(NULL);
    void *direct = direct_get_current_fiber();

    printf("converted=%p direct=%p match=%u\n", converted, direct, converted == direct);
    if (!converted || converted != direct) return 2;
    printf("fiber_data_first=0x%llx\n", (unsigned long long)*(uintptr_t *)direct);
    return 0;
}
