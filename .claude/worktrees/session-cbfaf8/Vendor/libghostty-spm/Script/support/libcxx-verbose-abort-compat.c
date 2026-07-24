// libc++'s std::__1::__libcpp_verbose_abort is only exported by the Apple
// system libc++.1.dylib since iOS 16.3 / macOS 13.3 / tvOS 16.3. Zig's
// bundled libc++ headers reference it unconditionally (no Apple availability
// markup), so apps linking libghostty.a crash at launch on older OS versions
// with dyld "Symbol missing". Shipping the definition inside the archive
// resolves the reference at static link time instead.
//
// Header-free on purpose: zig cc has no Apple sysroot in this build.

__attribute__((noreturn)) void abort(void);

__attribute__((visibility("hidden"), noreturn))
void libghostty_libcpp_verbose_abort(const char *format, ...) __asm__("__ZNSt3__122__libcpp_verbose_abortEPKcz");

void libghostty_libcpp_verbose_abort(const char *format, ...) {
    (void)format;
    abort();
}
