# libmapsoly_mln.so for Android: MapLibre Native's core (GLES 3 renderer) with the
# platform pieces chosen here, and the mlnb bridge on top. Driven by
# tool/build_maplibre_android.sh; see docs/map-engine.md ("Android").
#
# MapLibre's own Android platform (platform/android) is the Java SDK's native half: its
# run loop, HTTP, image decoding and text helpers call into Java classes of that SDK.
# This app has no such classes, so the core is built alone (MLN_WITH_CORE_ONLY) and
# gets the portable implementations the Linux build uses, plus a few small files of ours:
#   run loop, timers, async tasks   libuv            (platform/default, as on Linux)
#   file sources, PMTiles, SQLite   platform/default (as on Linux)
#   bidi, case mapping, collation   vendored ICU subset + nunicode
#   text shaping                    vendored HarfBuzz + FreeType (in the core)
#   images                          libpng only       (image.cpp: sprites and tiles are PNG)
#   HTTP                            http_file_source.cpp: plain HTTP to 127.0.0.1 only
#   logging, thread names           logging.cpp (logcat), thread.cpp
cmake_minimum_required(VERSION 3.25)
project(mapsoly_mln LANGUAGES C CXX)

set(MLN_SRC "" CACHE PATH "MapLibre Native source tree")
set(DEPS_PREFIX "" CACHE PATH "where libuv and libpng were installed for this ABI")
if(NOT EXISTS "${MLN_SRC}/CMakeLists.txt" OR NOT EXISTS "${DEPS_PREFIX}/include/uv.h")
    message(FATAL_ERROR "MLN_SRC and DEPS_PREFIX must be set (use tool/build_maplibre_android.sh)")
endif()

set(MLN_WITH_CORE_ONLY ON CACHE BOOL "" FORCE)
set(MLN_WITH_OPENGL ON CACHE BOOL "" FORCE)
set(MLN_WITH_WERROR OFF CACHE BOOL "" FORCE)
set(MLN_WITH_GLFW OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
# Sections of their own, so the linker can drop what the bridge never reaches.
add_compile_options(-ffunction-sections -fdata-sections)

add_subdirectory("${MLN_SRC}" mln EXCLUDE_FROM_ALL)

include("${MLN_SRC}/platform/default/sources.cmake")
include("${MLN_SRC}/vendor/icu.cmake")
include("${MLN_SRC}/vendor/nunicode.cmake")
include("${MLN_SRC}/vendor/sqlite.cmake")

target_sources(
    mbgl-core
    PRIVATE
        ${MLN_DEFAULT_FILE_SOURCE_SOURCES}
        ${MLN_DEFAULT_LIBUV_RUN_LOOP_SOURCES}
        ${MLN_DEFAULT_LOCALE_SOURCES}
        ${MLN_DEFAULT_UNICODE_SOURCES}
        ${MLN_DEFAULT_UTIL_SOURCES}
        ${MLN_SRC}/platform/default/src/mln/layermanager/layer_manager.cpp
        ${MLN_SRC}/platform/default/src/mln/storage/sqlite3.cpp
        ${MLN_SRC}/platform/default/src/mln/text/local_glyph_rasterizer.cpp
        ${MLN_SRC}/platform/default/src/mln/util/png_reader.cpp
        ${MLN_SRC}/platform/default/src/mln/util/png_writer.cpp
        ${MLN_SRC}/platform/default/src/mln/util/thread_local.cpp
        ${MLN_SRC}/platform/android/src/gl_functions.cpp
        ${CMAKE_CURRENT_LIST_DIR}/http_file_source.cpp
        ${CMAKE_CURRENT_LIST_DIR}/image.cpp
        ${CMAKE_CURRENT_LIST_DIR}/logging.cpp
        ${CMAKE_CURRENT_LIST_DIR}/thread.cpp
)
# Number formatting needs ICU's i18n library, which the vendored subset does not have.
set_source_files_properties(
    ${MLN_SRC}/platform/default/src/mln/i18n/number_format.cpp
    TARGET_DIRECTORY mbgl-core
    PROPERTIES COMPILE_DEFINITIONS MBGL_USE_BUILTIN_ICU
)
target_include_directories(
    mbgl-core
    PUBLIC ${MLN_SRC}/platform/default/include
    PRIVATE ${DEPS_PREFIX}/include
)
target_link_libraries(
    mbgl-core
    PRIVATE
        ${DEPS_PREFIX}/lib/libuv.a
        ${DEPS_PREFIX}/lib/libpng16.a
        mbgl-vendor-icu
        mbgl-vendor-nunicode
        mbgl-vendor-sqlite
        EGL
        GLESv3
        android
        log
        z
)

add_library(mapsoly_mln SHARED ${CMAKE_CURRENT_LIST_DIR}/../mlnb.cpp ${CMAKE_CURRENT_LIST_DIR}/jni.cpp)
set_target_properties(mapsoly_mln PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
# The bridge implements a renderer backend, so it includes MapLibre's private headers
# (src/mln/gl/...): it is compiled with the include paths and defines of the core itself.
target_include_directories(
    mapsoly_mln
    PRIVATE ${CMAKE_CURRENT_LIST_DIR}/.. $<TARGET_PROPERTY:mbgl-core,INCLUDE_DIRECTORIES>
)
target_compile_definitions(mapsoly_mln PRIVATE $<TARGET_PROPERTY:mbgl-core,COMPILE_DEFINITIONS>)
target_compile_options(
    mapsoly_mln
    PRIVATE -fvisibility=hidden -fno-rtti -Wall -Wextra -Wno-unused-parameter
)
target_link_libraries(mapsoly_mln PRIVATE mbgl-core EGL GLESv3 android log)
# Only the mlnb_* and JNI entry points are exported; unreachable code is dropped.
target_link_options(
    mapsoly_mln
    PRIVATE -Wl,--no-undefined -Wl,--gc-sections -Wl,-Bsymbolic -Wl,--exclude-libs,ALL
)
