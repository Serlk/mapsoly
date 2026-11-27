// Thread helpers for the Android build. platform/default's version needs
// pthread_getname_np (API 26; the app supports 24), and platform/android's attaches every
// thread to the Java VM, which nothing here needs.
#include <mln/platform/thread.hpp>
#include <mln/util/platform.hpp>

#include <pthread.h>
#include <sys/prctl.h>
#include <sys/resource.h>

#include <string>

namespace mln {
namespace platform {

std::string getCurrentThreadName() {
    char name[32] = "unknown";
    prctl(PR_GET_NAME, name);
    return name;
}

void setCurrentThreadName(const std::string& name) {
    pthread_setname_np(pthread_self(), name.substr(0, 15).c_str()); // kernel limit
}

// Android schedules by niceness within the app's cgroup: 19 is the lowest priority.
void makeThreadLowPriority() {
    setpriority(PRIO_PROCESS, 0, 19);
}

void setCurrentThreadPriority(double priority) {
    setpriority(PRIO_PROCESS, 0, static_cast<int>(priority));
}

void attachThread() {}

void detachThread() {}

void runTask(const std::function<void()>& task) {
    task();
}

} // namespace platform
} // namespace mln
