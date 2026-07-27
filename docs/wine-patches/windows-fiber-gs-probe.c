#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void *direct_get_current_fiber(void)
{
    void *fiber;
    __asm__ volatile("movq %%gs:0x20,%0" : "=r"(fiber));
    return fiber;
}

static uintptr_t runtime_generated_fiber_dereference(void)
{
    static const unsigned char code[] = {
        0x65, 0x48, 0x8b, 0x04, 0x25, 0x20, 0x00, 0x00, 0x00, /* mov gs:[20h], rax */
        0x48, 0x8b, 0x00,                                     /* mov [rax], rax */
        0xc3                                                    /* ret */
    };
    void *memory = VirtualAlloc(NULL, sizeof(code), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    DWORD old_protection;
    uintptr_t (*function)(void);
    uintptr_t result;

    if (!memory) return 0;
    memcpy(memory, code, sizeof(code));
    if (!VirtualProtect(memory, sizeof(code), PAGE_EXECUTE_READ, &old_protection))
    {
        VirtualFree(memory, 0, MEM_RELEASE);
        return 0;
    }
    FlushInstructionCache(GetCurrentProcess(), memory, sizeof(code));
    function = (uintptr_t (*)(void))memory;
    result = function();
    VirtualFree(memory, 0, MEM_RELEASE);
    return result;
}

int main(void)
{
    void *converted = ConvertThreadToFiber(NULL);
    void *direct = direct_get_current_fiber();
    uintptr_t expected_first;
    uintptr_t runtime_first;

    printf("converted=%p direct=%p match=%u\n", converted, direct, converted == direct);
    if (!converted || converted != direct) return 2;
    expected_first = *(uintptr_t *)direct;
    runtime_first = runtime_generated_fiber_dereference();
    printf("fiber_data_first=0x%llx runtime_first=0x%llx match=%u\n",
           (unsigned long long)expected_first, (unsigned long long)runtime_first,
           expected_first == runtime_first);
    if (expected_first != runtime_first) return 3;
    return 0;
}
