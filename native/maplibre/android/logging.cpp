// MapLibre's log on Android: logcat, tag "mlnb" (stderr of an app goes nowhere).
#include <mln/util/enum.hpp>
#include <mln/util/logging.hpp>

#include <android/log.h>

namespace mln {

void Log::platformRecord(EventSeverity severity, const std::string& msg) {
    int priority = ANDROID_LOG_INFO;
    switch (severity) {
        case EventSeverity::Debug:
            priority = ANDROID_LOG_DEBUG;
            break;
        case EventSeverity::Info:
            priority = ANDROID_LOG_INFO;
            break;
        case EventSeverity::Warning:
            priority = ANDROID_LOG_WARN;
            break;
        case EventSeverity::Error:
            priority = ANDROID_LOG_ERROR;
            break;
        default:
            break;
    }
    __android_log_write(priority, "mlnb", msg.c_str());
}

} // namespace mln
