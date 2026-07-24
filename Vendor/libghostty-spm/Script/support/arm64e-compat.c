#include "ghostty.h"

#include <stdbool.h>
#include <stdint.h>

#if defined(__arm64e__)
#include <pthread.h>
#include <ptrauth.h>
#include <stdatomic.h>
#include <stdlib.h>

enum {
  ghostty_block_has_copy_dispose = 1 << 25,
  ghostty_objc_isa_discriminator = 0x6AE1,
};

typedef struct {
  uintptr_t reserved;
  uintptr_t size;
  void *copy_helper;
  void *dispose_helper;
} ghostty_block_descriptor_s;

typedef struct {
  void *isa;
  int flags;
  int reserved;
  void *invoke;
  ghostty_block_descriptor_s *descriptor;
} ghostty_block_s;

static atomic_flag ghostty_descriptor_lock = ATOMIC_FLAG_INIT;

static void *ghostty_sign_function_pointer(void *pointer,
                                           uintptr_t discriminator) {
  void *raw = ptrauth_strip(pointer, ptrauth_key_function_pointer);
  return ptrauth_sign_unauthenticated(
      raw, ptrauth_key_function_pointer, discriminator);
}

static void *ghostty_sign_objc_isa_pointer(void *pointer,
                                           uintptr_t discriminator) {
  void *raw = ptrauth_strip(pointer, ptrauth_key_objc_isa_pointer);
  return ptrauth_sign_unauthenticated(
      raw, ptrauth_key_objc_isa_pointer, discriminator);
}

static void ghostty_prepare_block_descriptor(ghostty_block_descriptor_s *descriptor) {
  while (atomic_flag_test_and_set_explicit(&ghostty_descriptor_lock,
                                            memory_order_acquire)) {
  }

  descriptor->copy_helper = ghostty_sign_function_pointer(
      descriptor->copy_helper,
      (uintptr_t)&descriptor->copy_helper);
  descriptor->dispose_helper = ghostty_sign_function_pointer(
      descriptor->dispose_helper,
      (uintptr_t)&descriptor->dispose_helper);

  atomic_flag_clear_explicit(&ghostty_descriptor_lock, memory_order_release);
}

const void *ghostty_arm64e_sign_function(const void *pointer) {
  return ghostty_sign_function_pointer((void *)pointer, 0);
}

void ghostty_arm64e_prepare_block(void *raw_block) {
  ghostty_block_s *block = raw_block;

  if ((block->flags & ghostty_block_has_copy_dispose) != 0) {
    ghostty_prepare_block_descriptor(block->descriptor);
  }

  block->isa = ghostty_sign_objc_isa_pointer(
      block->isa,
      ptrauth_blend_discriminator(&block->isa, ghostty_objc_isa_discriminator));
  block->invoke = ghostty_sign_function_pointer(
      block->invoke,
      (uintptr_t)&block->invoke);

#if __has_feature(ptrauth_signed_block_descriptors)
  block->descriptor = ptrauth_sign_unauthenticated(
      ptrauth_strip(block->descriptor, ptrauth_key_block_descriptor_pointer),
      ptrauth_key_block_descriptor_pointer,
      ptrauth_blend_discriminator(&block->descriptor, 0xC0BB));
#endif
}

__attribute__((visibility("hidden"))) int pa_pthread_cr(
    pthread_t *thread,
    const pthread_attr_t *attributes,
    void *(*start_routine)(void *),
    void *argument) {
  start_routine = ghostty_sign_function_pointer((void *)start_routine, 0);
  return pthread_create(thread, attributes, start_routine, argument);
}

__attribute__((visibility("hidden"))) void pa_qs(
    void *base,
    size_t count,
    size_t size,
    int (*comparator)(const void *, const void *)) {
  comparator = ghostty_sign_function_pointer((void *)comparator, 0);
  qsort(base, count, size, comparator);
}

extern ghostty_app_t ghostty_arm64e_core_app_new(
    const ghostty_runtime_config_s *,
    ghostty_config_t);
extern ghostty_surface_t ghostty_arm64e_core_surface_new(
    ghostty_app_t,
    const ghostty_surface_config_s *);

GHOSTTY_API ghostty_app_t ghostty_app_new(
    const ghostty_runtime_config_s *config,
    ghostty_config_t ghostty_config) {
  ghostty_runtime_config_s raw = *config;
  raw.wakeup_cb = ptrauth_strip(raw.wakeup_cb, ptrauth_key_function_pointer);
  raw.action_cb = ptrauth_strip(raw.action_cb, ptrauth_key_function_pointer);
  raw.read_clipboard_cb =
      ptrauth_strip(raw.read_clipboard_cb, ptrauth_key_function_pointer);
  raw.confirm_read_clipboard_cb =
      ptrauth_strip(raw.confirm_read_clipboard_cb, ptrauth_key_function_pointer);
  raw.write_clipboard_cb =
      ptrauth_strip(raw.write_clipboard_cb, ptrauth_key_function_pointer);
  raw.close_surface_cb =
      ptrauth_strip(raw.close_surface_cb, ptrauth_key_function_pointer);
  return ghostty_arm64e_core_app_new(&raw, ghostty_config);
}

GHOSTTY_API ghostty_surface_t ghostty_surface_new(
    ghostty_app_t app,
    const ghostty_surface_config_s *config) {
  ghostty_surface_config_s raw = *config;
  raw.receive_buffer =
      ptrauth_strip(raw.receive_buffer, ptrauth_key_function_pointer);
  raw.receive_resize =
      ptrauth_strip(raw.receive_resize, ptrauth_key_function_pointer);
  return ghostty_arm64e_core_surface_new(app, &raw);
}

#else

const void *ghostty_arm64e_sign_function(const void *pointer) {
  return pointer;
}

void ghostty_arm64e_prepare_block(void *block) {
  (void)block;
}

#endif
