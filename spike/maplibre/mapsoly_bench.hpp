// Scripted camera benchmark for MapLibre Native's GLFW example app (mapsoly spike).
// Header-only; hooked into platform/glfw/glfw_view.cpp by glfw_bench.patch.
//
// Environment:
//   MLN_BENCH=1            enable the script (otherwise the app behaves as upstream)
//   MLN_BENCH_OUT=file.csv per-frame log (default ./bench.csv)
//   MLN_BENCH_VSYNC=0|1    swap interval / present mode (default 1 = vsync)
//   MLN_BENCH_SCALE=x      time scale of the script (default 1.0)
//
// One CSV row per rendered frame:
//   boot_ms,t_ms,seg,interval_ms,frame_ms,enc_ms,rend_ms,drawcalls,full,repaint,zoom,lat,lon
//   interval_ms = time between completions of consecutive frames (what the user sees)
//   frame_ms    = wall time of render() incl. buffer swap / vsync wait
//   enc_ms/rend_ms = MapLibre's own RenderingStats (CPU encode / render time)
#pragma once

#include <mln/map/camera.hpp>
#include <mln/map/map.hpp>
#include <mln/map/map_observer.hpp>
#include <mln/gfx/rendering_stats.hpp>
#include <mln/util/geo.hpp>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <string>
#include <vector>

class MapsolyBench {
public:
    using Clock = std::chrono::steady_clock;

    static MapsolyBench& get() {
        static MapsolyBench b;
        return b;
    }

    bool active() const { return enabled && !finished; }
    bool isEnabled() const { return enabled; }
    bool vsync() const { return useVsync; }
    bool done() const { return enabled && finished; }

    // Called before each loop iteration. Returns true if a frame must be rendered.
    bool drive(mln::Map& map) {
        if (!active()) return false;
        const auto now = Clock::now();
        if (seg >= segs.size()) {
            finish();
            return false;
        }
        Seg& s = segs[seg];
        if (!segStarted) {
            segStarted = true;
            segStart = now;
            segFull = false;
            std::fprintf(stderr, "BENCH seg %s t=%.0fms\n", s.name, ms(now - t0));
            if (s.kind == Kind::Jump) {
                map.jumpTo(mln::CameraOptions().withCenter(mln::LatLng{s.lat1, s.lon1}).withZoom(s.z1).withBearing(0.0).withPitch(0.0));
                return true;
            }
        }
        const double el = ms(now - segStart) / 1000.0;
        if (s.kind == Kind::Jump) {
            // wait until the map reports a complete frame, then hold a little
            if (segFull && loadMs < 0) {
                loadMs = ms(fullAt - segStart);
                std::fprintf(stderr, "BENCH load %s %.0fms (since process start %.0fms)\n", s.name, loadMs, ms(fullAt - t0));
                loads.push_back(std::string(s.name) + "," + std::to_string(loadMs));
            }
            if ((loadMs >= 0 && ms(now - fullAt) / 1000.0 >= s.dur) || el > 20.0) {
                next();
            }
            return false; // the map invalidates itself while tiles arrive
        }
        double f = el / (s.dur * scale);
        if (f >= 1.0) {
            f = 1.0;
        }
        const double lat = s.lat0 + (s.lat1 - s.lat0) * f;
        const double lon = s.lon0 + (s.lon1 - s.lon0) * f;
        const double z = s.z0 + (s.z1 - s.z0) * f;
        const double brg = s.b0 + (s.b1 - s.b0) * f;
        map.jumpTo(mln::CameraOptions().withCenter(mln::LatLng{lat, lon}).withZoom(z).withBearing(brg).withPitch(s.pitch));
        curLat = lat;
        curLon = lon;
        curZoom = z;
        if (f >= 1.0) next();
        return true;
    }

    void onFrameStatus(const mln::MapObserver::RenderFrameStatus& st) {
        if (!enabled) return;
        lastFull = st.mode == mln::MapObserver::RenderMode::Full;
        lastRepaint = st.needsRepaint;
        if (st.renderingStats) {
            lastEnc = st.renderingStats->encodingTime * 1000.0;
            lastRend = st.renderingStats->renderingTime * 1000.0;
            lastDraw = st.renderingStats->numDrawCalls;
        }
    }

    void frameDone(double frameMs) {
        if (!enabled || !out) return;
        const auto now = Clock::now();
        const double interval = haveLast ? ms(now - lastFrame) : 0.0;
        lastFrame = now;
        haveLast = true;
        if (lastFull && !segFull) {
            segFull = true;
            fullAt = now;
        }
        timespec ts{};
        clock_gettime(CLOCK_BOOTTIME, &ts); // same clock as /proc/uptime (used by sampler.sh)
        const long long epoch = ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
        const char* name = finished ? "end" : (seg < segs.size() ? segs[seg].name : "end");
        std::fprintf(out, "%lld,%.2f,%s,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%.3f,%.5f,%.5f\n", static_cast<long long>(epoch),
                     ms(now - t0), name, interval, frameMs, lastEnc, lastRend, lastDraw, lastFull ? 1 : 0,
                     lastRepaint ? 1 : 0, curZoom, curLat, curLon);
    }

private:
    enum class Kind { Move, Jump };
    struct Seg {
        const char* name;
        Kind kind;
        double dur; // Move: seconds; Jump: hold seconds after the first complete frame
        double lat0, lon0, z0, lat1, lon1, z1;
        double b0 = 0, b1 = 0, pitch = 0;
    };

    MapsolyBench() {
        t0 = Clock::now();
        const char* e = std::getenv("MLN_BENCH");
        enabled = e && *e && *e != '0';
        if (!enabled) return;
        const char* v = std::getenv("MLN_BENCH_VSYNC");
        useVsync = !(v && *v == '0');
        const char* sc = std::getenv("MLN_BENCH_SCALE");
        if (sc) scale = std::atof(sc);
        const char* o = std::getenv("MLN_BENCH_OUT");
        out = std::fopen(o ? o : "bench.csv", "w");
        if (out) std::fprintf(out, "boot_ms,t_ms,seg,interval_ms,frame_ms,enc_ms,rend_ms,drawcalls,full,repaint,zoom,lat,lon\n");

        const double LAT = 55.752, LON = 37.616; // central Moscow
        // 1. first complete frame, hold 2.5 s (screenshot window)
        segs.push_back({"load_center_z14", Kind::Jump, 2.5, 0, 0, 0, LAT, LON, 14});
        // 2. pan at z14: ~0.20 deg lon in 8 s = ~580 logical px/s (finger-drag speed), out = cold, back = warm
        segs.push_back({"pan14_cold", Kind::Move, 8, LAT, LON, 14, LAT + 0.03, LON + 0.20, 14});
        segs.push_back({"pan14_warm", Kind::Move, 8, LAT + 0.03, LON + 0.20, 14, LAT, LON, 14});
        // 3. zoom sweep 14 -> 11 -> 16 at the centre, twice (cold, warm)
        segs.push_back({"zoomout_cold", Kind::Move, 4, LAT, LON, 14, LAT, LON, 11});
        segs.push_back({"zoomin_cold", Kind::Move, 6, LAT, LON, 11, LAT, LON, 16});
        segs.push_back({"zoomout_warm", Kind::Move, 6, LAT, LON, 16, LAT, LON, 11});
        segs.push_back({"zoomin_warm", Kind::Move, 4, LAT, LON, 11, LAT, LON, 14});
        // 4. fast pan at z12 across the whole city and back
        segs.push_back({"pan12_cold", Kind::Move, 7, LAT + 0.10, LON - 0.35, 12, LAT - 0.10, LON + 0.35, 12});
        segs.push_back({"pan12_warm", Kind::Move, 7, LAT - 0.10, LON + 0.35, 12, LAT + 0.10, LON - 0.35, 12});
        // 5. navigation-like: pitched 50 deg, rotating, moving at z15.5
        segs.push_back({"nav_pitch_rot", Kind::Move, 7, LAT - 0.01, LON - 0.03, 15.5, LAT + 0.01, LON + 0.03, 15.5, 0, 180, 50});
        // 6. jumps to never-visited areas: time to a complete frame
        segs.push_back({"jump_zelenograd_z14", Kind::Jump, 0.5, 0, 0, 0, 55.991, 37.214, 14});
        segs.push_back({"jump_podolsk_z13", Kind::Jump, 0.5, 0, 0, 0, 55.431, 37.545, 13});
        segs.push_back({"jump_kremlin_z16", Kind::Jump, 2.5, 0, 0, 0, 55.7520, 37.6175, 16});
    }

    static double ms(Clock::duration d) { return std::chrono::duration<double, std::milli>(d).count(); }

    void next() {
        ++seg;
        segStarted = false;
        loadMs = -1;
    }

    void finish() {
        finished = true;
        std::fprintf(stderr, "BENCH done t=%.0fms\n", ms(Clock::now() - t0));
        if (out) {
            std::fclose(out);
            out = nullptr;
        }
    }

    bool enabled = false, finished = false, useVsync = true;
    double scale = 1.0;
    std::FILE* out = nullptr;
    std::vector<Seg> segs;
    std::vector<std::string> loads;
    std::size_t seg = 0;
    bool segStarted = false, segFull = false, haveLast = false;
    Clock::time_point t0, segStart, fullAt, lastFrame;
    double loadMs = -1;
    bool lastFull = false, lastRepaint = false;
    double lastEnc = 0, lastRend = 0;
    int lastDraw = 0;
    double curLat = 0, curLon = 0, curZoom = 0;
};
