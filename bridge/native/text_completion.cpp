// The x64 Task completion is std::function<bool(Task*&, int&, int&)> at +0x50.
// Keep its code in a loaded dylib, so pending Tasks can finish after Frida detaches.
#include <atomic>
#include <cstddef>
#include <functional>
#include <new>

using Completion = std::function<bool(void*&, int&, int&)>;
static_assert(sizeof(Completion) == 0x30, "Unsupported libc++ function ABI");
static_assert(alignof(Completion) == 16, "Unsupported libc++ function alignment");

static std::atomic<unsigned> completed{0};
static std::atomic<int> error_type{0};
static std::atomic<int> error_code{0};

extern "C" unsigned wechat_x64_completion_abi() { return 1; }

extern "C" void wechat_x64_completion_init(void* task) {
    new (static_cast<char*>(task) + 0x50) Completion(
        [](void*&, int& type, int& code) noexcept {
            error_type.store(type);
            error_code.store(code);
            completed.fetch_add(1);
            return true; // service deletes Task via its virtual deleting destructor
        });
}

extern "C" unsigned wechat_x64_completion_count() { return completed.load(); }
extern "C" int wechat_x64_completion_error_type() { return error_type.load(); }
extern "C" int wechat_x64_completion_error_code() { return error_code.load(); }
