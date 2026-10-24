/* libco aarch64 backend for bsnes, adapted for iOS by Attic.
 *
 * Upstream keeps the context-switch routine as machine code in a data array and
 * makes that page executable with mprotect(). iOS does not allow executable data,
 * so here the routine is ordinary assembly in the text section. It also saves
 * d8-d15, which the AArch64 calling convention requires callees to preserve.
 * The context layout is unchanged otherwise, so bsnes save states stay compatible.
 * (libco is ISC-licensed, see libco/libco.h.) */

#define LIBCO_C
#include "libco.h"
#include "settings.h"

#include <assert.h>
#include <stdlib.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

static thread_local unsigned long co_active_buffer[64];
static thread_local cothread_t co_active_handle = 0;

/* x0 = thread to switch to, x1 = thread to save into. Offsets 0-175 match upstream. */
__asm__(
  ".text\n"
  ".p2align 2\n"
#if defined(__APPLE__)
  ".private_extern _co_swap_attic\n"
  "_co_swap_attic:\n"
#else
  ".hidden co_swap_attic\n"
  "co_swap_attic:\n"
#endif
  "  stp x8,  x9,  [x1]\n"
  "  stp x10, x11, [x1, #16]\n"
  "  stp x12, x13, [x1, #32]\n"
  "  stp x14, x15, [x1, #48]\n"
  "  str x19, [x1, #72]\n"
  "  stp x20, x21, [x1, #80]\n"
  "  stp x22, x23, [x1, #96]\n"
  "  stp x24, x25, [x1, #112]\n"
  "  stp x26, x27, [x1, #128]\n"
  "  stp x28, x29, [x1, #144]\n"
  "  mov x16, sp\n"
  "  stp x16, x30, [x1, #160]\n"
  "  stp d8,  d9,  [x1, #176]\n"
  "  stp d10, d11, [x1, #192]\n"
  "  stp d12, d13, [x1, #208]\n"
  "  stp d14, d15, [x1, #224]\n"

  "  ldp d8,  d9,  [x0, #176]\n"
  "  ldp d10, d11, [x0, #192]\n"
  "  ldp d12, d13, [x0, #208]\n"
  "  ldp d14, d15, [x0, #224]\n"
  "  ldp x8,  x9,  [x0]\n"
  "  ldp x10, x11, [x0, #16]\n"
  "  ldp x12, x13, [x0, #32]\n"
  "  ldp x14, x15, [x0, #48]\n"
  "  ldr x19, [x0, #72]\n"
  "  ldp x20, x21, [x0, #80]\n"
  "  ldp x22, x23, [x0, #96]\n"
  "  ldp x24, x25, [x0, #112]\n"
  "  ldp x26, x27, [x0, #128]\n"
  "  ldp x28, x29, [x0, #144]\n"
  "  ldp x16, x17, [x0, #160]\n"
  "  mov sp, x16\n"
  "  br x17\n"
);

void co_swap_attic(cothread_t to, cothread_t from);

cothread_t co_active() {
  if(!co_active_handle) co_active_handle = &co_active_buffer;
  return co_active_handle;
}

cothread_t co_derive(void* memory, unsigned int size, void (*entrypoint)(void)) {
  unsigned long* handle;
  if(!co_active_handle) co_active_handle = &co_active_buffer;

  if((handle = (unsigned long*)memory)) {
    unsigned int offset = (size & ~15);
    unsigned long* p = (unsigned long*)((unsigned char*)handle + offset);
    unsigned int i;
    for(i = 22; i < 30; i++) handle[i] = 0;  /* d8-d15 */
    handle[19] = (unsigned long)p;           /* x29 (frame pointer) */
    handle[20] = (unsigned long)p;           /* x30 (stack pointer) */
    handle[21] = (unsigned long)entrypoint;  /* x31 (link register) */
  }

  return handle;
}

cothread_t co_create(unsigned int size, void (*entrypoint)(void)) {
  void* memory = malloc(size);
  if(!memory) return (cothread_t)0;
  return co_derive(memory, size, entrypoint);
}

void co_delete(cothread_t handle) {
  free(handle);
}

void co_switch(cothread_t handle) {
  cothread_t co_previous_handle = co_active_handle;
  co_swap_attic(co_active_handle = handle, co_previous_handle);
}

int co_serializable() {
  return 1;
}

#ifdef __cplusplus
}
#endif
