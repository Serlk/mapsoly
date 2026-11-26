// Scripted camera run: the segments of spike/maplibre/mapsoly_bench.hpp, restartable.
// One CSV row per rendered map frame, same leading columns as the standalone spike so
// spike/maplibre/analyze.py reads it:
//   boot_ms,t_ms,seg,interval_ms,frame_ms,enc_ms,rend_ms,drawcalls,full,repaint,zoom,lat,lon,gpuwait_ms,seq
#pragma once

#include <mln/map/camera.hpp>
#include <mln/map/map.hpp>
#include <mln/map/map_observer.hpp>
#include <mln/gfx/rendering_stats.hpp>
#include <mln/util/geo.hpp>

#include <chrono>
#include <cstdio>
#include <ctime>
#include <string>
#include <vector>

class BenchScript {
public:
    using Clock = std::chrono::steady_clock;

    BenchScript() {
        const double LAT = 55.752, LON = 37.616; // central Moscow
        segs.push_back({"load_center_z14", Kind::Jump, 2.5, 0, 0, 0, LAT, LON, 14});
        segs.push_back({"pan14_cold", Kind::Move, 8, LAT, LON, 14, LAT + 0.03, LON + 0.20, 14});
        segs.push_back({"pan14_warm", Kind::Move, 8, LAT + 0.03, LON + 0.20, 14, LAT, LON, 14});
        segs.push_back({"zoomout_cold", Kind::Move, 4, LAT, LON, 14, LAT, LON, 11});
        segs.push_back({"zoomin_cold", Kind::Move, 6, LAT, LON, 11, LAT, LON, 16});
        segs.push_back({"zoomout_warm", Kind::Move, 6, LAT, LON, 16, LAT, LON, 11});
        segs.push_back({"zoomin_warm", Kind::Move, 4, LAT, LON, 11, LAT, LON, 14});
        segs.push_back({"pan12_cold", Kind::Move, 7, LAT + 0.10, LON - 0.35, 12, LAT - 0.10, LON + 0.35, 12});
        segs.push_back({"pan12_warm", Kind::Move, 7, LAT - 0.10, LON + 0.35, 12, LAT + 0.10, LON - 0.35, 12});
        segs.push_back({"nav_pitch_rot", Kind::Move, 7, LAT - 0.01, LON - 0.03, 15.5, LAT + 0.01, LON + 0.03, 15.5, 0, 180, 50});
        segs.push_back({"jump_zelenograd_z14", Kind::Jump, 0.5, 0, 0, 0, 55.991, 37.214, 14});
        segs.push_back({"jump_podolsk_z13", Kind::Jump, 0.5, 0, 0, 0, 55.431, 37.545, 13});
        segs.push_back({"jump_kremlin_z16", Kind::Jump, 2.5, 0, 0, 0, 55.7520, 37.6175, 16});
    }

    bool active() const { return running; }
    bool done() const { return finished; }

    void start(const std::string& framesCsv) {
        if (out) std::fclose(out);
        out = std::fopen(framesCsv.c_str(), "w");
        if (out)
            std::fprintf(out, "boot_ms,t_ms,seg,interval_ms,frame_ms,enc_ms,rend_ms,drawcalls,full,repaint,zoom,lat,lon,gpuwait_ms,seq\n");
        t0 = Clock::now();
        seg = 0;
        segStarted = segFull = haveLast = false;
        loadMs = -1;
        running = true;
        finished = false;
    }

    // Called before each render opportunity. Returns true if it moved the camera.
    bool drive(mln::Map& map) {
        if (!running) return false;
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
                curLat = s.lat1;
                curLon = s.lon1;
                curZoom = s.z1;
                return true;
            }
        }
        const double el = ms(now - segStart) / 1000.0;
        if (s.kind == Kind::Jump) {
            if (segFull && loadMs < 0) {
                loadMs = ms(fullAt - segStart);
                std::fprintf(stderr, "BENCH load %s %.0fms (since bench start %.0fms)\n", s.name, loadMs, ms(fullAt - t0));
            }
            if ((loadMs >= 0 && ms(now - fullAt) / 1000.0 >= s.dur) || el > 20.0) next();
            return false; // the map invalidates itself while tiles arrive
        }
        double f = el / s.dur;
        if (f >= 1.0) f = 1.0;
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
        lastFull = st.mode == mln::MapObserver::RenderMode::Full;
        lastRepaint = st.needsRepaint;
        if (st.renderingStats) {
            lastEnc = st.renderingStats->encodingTime * 1000.0;
            lastRend = st.renderingStats->renderingTime * 1000.0;
            lastDraw = st.renderingStats->numDrawCalls;
        }
    }

    // Called after a frame was rendered and published.
    void frameDone(double frameMs, double gpuWaitMs, unsigned long long seqNo) {
        if (!running || !out) return;
        const auto now = Clock::now();
        const double interval = haveLast ? ms(now - lastFrame) : 0.0;
        lastFrame = now;
        haveLast = true;
        if (lastFull && !segFull) {
            segFull = true;
            fullAt = now;
        }
        timespec ts{};
        clock_gettime(CLOCK_BOOTTIME, &ts); // same clock as /proc/uptime (sampler.sh)
        const long long boot = ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
        const char* name = seg < segs.size() ? segs[seg].name : "end";
        std::fprintf(out, "%lld,%.2f,%s,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%.3f,%.5f,%.5f,%.3f,%llu\n", boot, ms(now - t0), name,
                     interval, frameMs, lastEnc, lastRend, lastDraw, lastFull ? 1 : 0, lastRepaint ? 1 : 0, curZoom,
                     curLat, curLon, gpuWaitMs, seqNo);
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

    static double ms(Clock::duration d) { return std::chrono::duration<double, std::milli>(d).count(); }

    void next() {
        ++seg;
        segStarted = false;
        loadMs = -1;
    }

    void finish() {
        running = false;
        finished = true;
        std::fprintf(stderr, "BENCH done t=%.0fms\n", ms(Clock::now() - t0));
        if (out) {
            std::fclose(out);
            out = nullptr;
        }
    }

    bool running = false, finished = false;
    std::FILE* out = nullptr;
    std::vector<Seg> segs;
    std::size_t seg = 0;
    bool segStarted = false, segFull = false, haveLast = false;
    Clock::time_point t0, segStart, fullAt, lastFrame;
    double loadMs = -1;
    bool lastFull = false, lastRepaint = false;
    double lastEnc = 0, lastRend = 0;
    int lastDraw = 0;
    double curLat = 0, curLon = 0, curZoom = 0;
};
