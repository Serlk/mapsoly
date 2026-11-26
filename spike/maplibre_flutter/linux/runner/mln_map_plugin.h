#ifndef RUNNER_MLN_MAP_PLUGIN_H_
#define RUNNER_MLN_MAP_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

// Registers the "mapsoly/mln_map" method channel on the view's engine.
void mln_map_plugin_register(FlView* view);

G_END_DECLS

#endif  // RUNNER_MLN_MAP_PLUGIN_H_
