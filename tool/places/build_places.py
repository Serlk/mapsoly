#!/usr/bin/env python3
"""Builds places.sqlite (offline search index + speed cameras) from a PBF.

    build_places.py <region.osm.pbf> <places.sqlite>

Runs inside the tool/docker/places image (pyosmium, shapely, numpy); see
tool/build_places.sh.  Schema and rules are documented in docs/places.md.
"""
import math
import os
import resource
import sqlite3
import struct
import sys
import time
from collections import Counter, defaultdict

import numpy as np
import osmium
import shapely

from ru_normalize import NORM_VERSION, normalize, normalize_housenumber, tokens

SCHEMA_VERSION = 1

KIND_LOCALITY, KIND_STREET, KIND_POI = 0, 1, 2

# ---------------------------------------------------------------- categories
# (code, Russian label, weight, unnamed objects allowed, synonyms, tags)
POI_CATS = [
    ('fuel', 'АЗС', 45, 1, 'азс заправка бензин топливо', ['amenity=fuel']),
    ('charging', 'Зарядная станция', 35, 1, 'зарядка электромобиль эзс',
     ['amenity=charging_station']),
    ('parking', 'Парковка', 20, 0, 'парковка стоянка', ['amenity=parking']),
    ('car_wash', 'Автомойка', 30, 1, 'мойка автомойка', ['amenity=car_wash']),
    ('car_repair', 'Автосервис', 30, 1, 'сто автосервис шиномонтаж ремонт',
     ['shop=car_repair', 'shop=tyres']),
    ('car_shop', 'Автомагазин', 25, 0, 'автозапчасти автосалон',
     ['shop=car', 'shop=car_parts']),
    ('pharmacy', 'Аптека', 40, 1, 'аптека', ['amenity=pharmacy']),
    ('hospital', 'Больница', 45, 1, 'больница госпиталь',
     ['amenity=hospital']),
    ('clinic', 'Поликлиника', 40, 1, 'поликлиника клиника медцентр врач',
     ['amenity=clinic', 'amenity=doctors']),
    ('dentist', 'Стоматология', 30, 0, 'стоматолог зубной',
     ['amenity=dentist']),
    ('vet', 'Ветклиника', 25, 0, 'ветеринар ветклиника',
     ['amenity=veterinary']),
    ('police', 'Полиция', 40, 1, 'полиция гибдд дпс', ['amenity=police']),
    ('fire_station', 'Пожарная часть', 25, 1, 'пожарные мчс',
     ['amenity=fire_station']),
    ('post', 'Почта', 35, 1, 'почта отделение', ['amenity=post_office']),
    ('bank', 'Банк', 35, 1, 'банк', ['amenity=bank']),
    ('atm', 'Банкомат', 25, 1, 'банкомат', ['amenity=atm']),
    ('cafe', 'Кафе', 35, 0, 'кафе кофейня', ['amenity=cafe']),
    ('restaurant', 'Ресторан', 35, 0, 'ресторан', ['amenity=restaurant']),
    ('fast_food', 'Фастфуд', 35, 0, 'фастфуд еда',
     ['amenity=fast_food', 'amenity=food_court']),
    ('bar', 'Бар', 30, 0, 'бар паб', ['amenity=bar', 'amenity=pub']),
    ('supermarket', 'Супермаркет', 40, 0, 'супермаркет продукты магазин',
     ['shop=supermarket']),
    ('convenience', 'Продукты', 30, 0, 'продукты магазин',
     ['shop=convenience']),
    ('mall', 'Торговый центр', 45, 0, 'тц трц торговый центр',
     ['shop=mall', 'shop=department_store']),
    ('marketplace', 'Рынок', 35, 0, 'рынок базар', ['amenity=marketplace']),
    ('shop', 'Магазин', 25, 0, 'магазин', ['shop=*']),
    ('hotel', 'Гостиница', 40, 0, 'отель гостиница хостел',
     ['tourism=hotel', 'tourism=hostel', 'tourism=guest_house',
      'tourism=motel', 'tourism=apartment']),
    ('camp', 'Кемпинг', 30, 0, 'кемпинг турбаза',
     ['tourism=camp_site', 'tourism=caravan_site', 'tourism=chalet']),
    ('attraction', 'Достопримечательность', 40, 0, '',
     ['tourism=attraction', 'tourism=viewpoint']),
    ('museum', 'Музей', 40, 0, 'музей галерея',
     ['tourism=museum', 'tourism=gallery']),
    ('zoo', 'Зоопарк', 40, 0, 'зоопарк', ['tourism=zoo']),
    ('theme_park', 'Парк развлечений', 35, 0, 'аттракционы',
     ['tourism=theme_park', 'leisure=water_park']),
    ('theatre', 'Театр', 35, 0, 'театр', ['amenity=theatre']),
    ('cinema', 'Кинотеатр', 35, 0, 'кино кинотеатр', ['amenity=cinema']),
    ('school', 'Школа', 30, 0, 'школа гимназия лицей', ['amenity=school']),
    ('kindergarten', 'Детский сад', 25, 0, 'детсад садик',
     ['amenity=kindergarten']),
    ('university', 'Вуз', 35, 0, 'университет институт колледж',
     ['amenity=university', 'amenity=college']),
    ('library', 'Библиотека', 25, 0, 'библиотека', ['amenity=library']),
    ('worship', 'Храм', 30, 0, 'церковь храм мечеть собор',
     ['amenity=place_of_worship']),
    ('townhall', 'Администрация', 35, 0, 'администрация мэрия',
     ['amenity=townhall']),
    ('government', 'Госучреждение', 30, 0, 'суд мфц',
     ['office=government', 'amenity=courthouse']),
    ('toilets', 'Туалет', 15, 1, 'туалет wc', ['amenity=toilets']),
    ('station', 'Ж/д станция', 50, 0, 'вокзал станция платформа жд',
     ['railway=station', 'railway=halt']),
    ('metro', 'Метро', 55, 0, 'метро станция', []),
    ('bus_station', 'Автовокзал', 45, 0, 'автовокзал автостанция',
     ['amenity=bus_station']),
    ('airport', 'Аэропорт', 60, 0, 'аэропорт аэродром',
     ['aeroway=aerodrome']),
    ('ferry', 'Паром', 35, 0, 'паром переправа', ['amenity=ferry_terminal']),
    ('park', 'Парк', 35, 0, 'парк сквер сад',
     ['leisure=park', 'leisure=garden']),
    ('stadium', 'Стадион', 35, 0, 'стадион', ['leisure=stadium']),
    ('sports', 'Спорт', 25, 0, 'спорт фитнес бассейн каток',
     ['leisure=sports_centre', 'leisure=fitness_centre',
      'leisure=ice_rink']),
    ('beach', 'Пляж', 30, 0, 'пляж', ['leisure=beach_resort']),
    ('monument', 'Памятник', 25, 0, 'памятник мемориал',
     ['historic=monument', 'historic=memorial']),
    ('historic', 'Историческое место', 30, 0, 'замок крепость форт руины',
     ['historic=*']),
    ('office', 'Офис', 20, 0, 'офис', ['office=*']),
    ('cemetery', 'Кладбище', 25, 0, 'кладбище',
     ['landuse=cemetery', 'amenity=grave_yard']),
]
# (code, label, weight); settlement types are used for locality assignment.
LOC_CATS = [
    ('city', 'Город', 100), ('town', 'Город', 85), ('village', 'Село', 65),
    ('hamlet', 'Деревня', 55), ('isolated_dwelling', 'Хутор', 40),
    ('allotments', 'СНТ', 45), ('suburb', 'Район города', 60),
    ('quarter', 'Квартал', 50), ('neighbourhood', 'Микрорайон', 50),
    ('locality', 'Урочище', 30), ('district', 'Район', 70),
    ('region', 'Регион', 90),
]
STREET_CATS = [('street', 'Улица', 50), ('area', 'Территория', 45)]
SETTLEMENT = {'city', 'town', 'village', 'hamlet', 'isolated_dwelling',
              'allotments'}
# Radius (km) of the pseudo-circle used for places mapped only as a node.
NODE_RADIUS_KM = {'city': 8.0, 'town': 4.0, 'village': 1.5, 'hamlet': 0.8,
                  'isolated_dwelling': 0.4, 'allotments': 0.5}

POI_KEYS = ('amenity', 'shop', 'tourism', 'leisure', 'railway', 'aeroway',
            'office', 'historic', 'landuse')
FILTER_KEYS = POI_KEYS + ('addr:housenumber', 'place', 'highway', 'boundary')
ALT_NAME_KEYS = ('name:ru', 'name:en', 'alt_name', 'old_name', 'short_name',
                 'official_name', 'loc_name')

DRIVABLE = {'motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary',
            'primary_link', 'secondary', 'secondary_link', 'tertiary',
            'tertiary_link', 'unclassified', 'residential', 'living_street'}
HW_SKIP_NAME = {'platform', 'corridor', 'proposed', 'bus_stop', 'elevator',
                'construction', 'razed', 'abandoned'}
HW_WEIGHT = {'motorway': 62, 'trunk': 62, 'primary': 60, 'secondary': 57,
             'tertiary': 54, 'residential': 50, 'unclassified': 50,
             'living_street': 50, 'pedestrian': 50}
MAXSPEED_ZONES = {'ru:urban': 60, 'ru:rural': 90, 'ru:motorway': 110,
                  'ru:living_street': 20}
SNAP_RADIUS_M = 50.0


def log(msg):
    print('[%6.1fs] %s' % (time.time() - T0, msg), flush=True)


T0 = time.time()


def parse_maxspeed(v):
    if not v:
        return None
    v = v.strip().lower()
    if v in MAXSPEED_ZONES:
        return MAXSPEED_ZONES[v]
    try:
        n = int(v)
    except ValueError:
        return None
    return n if 5 <= n <= 150 else None


def bearing(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def dist_m(lat1, lon1, lat2, lon2):
    kx = math.cos(math.radians((lat1 + lat2) / 2)) * 111320.0
    return math.hypot((lon2 - lon1) * kx, (lat2 - lat1) * 110540.0)


def ang_diff(a, b):
    d = abs(a - b) % 360.0
    return 360.0 - d if d > 180.0 else d


def namekey(name):
    """Order-independent key of a normalised name."""
    return ' '.join(sorted(tokens(name)))


class Builder:
    def __init__(self, pbf):
        self.pbf = pbf
        self.cat_ids = {}
        self.cats = []      # (id, code, label, kind, weight)
        self.poi_exact = {}
        self.poi_wild = {}
        self.poi_meta = {}  # cat id -> (label, weight, unnamed, synonyms)
        for kind, lst in ((KIND_LOCALITY, LOC_CATS), (KIND_STREET, STREET_CATS)):
            for code, label, w in lst:
                self._add_cat(code, label, kind, w)
        for code, label, w, unnamed, syn, tags in POI_CATS:
            cid = self._add_cat(code, label, KIND_POI, w)
            self.poi_meta[cid] = (label, w, unnamed, normalize(syn))
            for t in tags:
                k, v = t.split('=')
                if v == '*':
                    self.poi_wild[k] = cid
                else:
                    self.poi_exact[(k, v)] = cid
        # raw collections
        self.place_nodes = []   # (type, name, alts, lat, lon, population)
        self.place_polys = []   # (type, name, alts, geom, population)
        self.admin_polys = []   # (level, name, geom)
        self.addrs = []         # (lat, lon, hn, street, place, city, is_area)
        self.pois = []          # (lat, lon, cat, name, alts, street, hn)
        self.segs = []          # (name, alts, lat, lon, weight)
        self.cam_nodes = {}     # node id -> dict
        self.enf = []           # enforcement relations
        self.snap_pts = {}      # key -> (lat, lon)
        self.snap_cells = defaultdict(list)
        self.snap_best = {}     # key -> (dist, bearing, oneway, maxspeed)
        self.stats = Counter()
        self.wkb = osmium.geom.WKBFactory()

    def _add_cat(self, code, label, kind, w):
        cid = len(self.cats) + 1
        self.cats.append((cid, code, label, kind, w))
        self.cat_ids[code] = cid
        return cid

    # ------------------------------------------------------------ pre-passes
    def read_enforcement(self):
        need = set()
        fp = osmium.FileProcessor(self.pbf, osmium.osm.RELATION).with_filter(
            osmium.filter.TagFilter(('type', 'enforcement')))
        for r in fp:
            t = r.tags
            rec = {'id': r.id, 'type': t.get('enforcement') or 'unknown',
                   'maxspeed': parse_maxspeed(t.get('maxspeed')),
                   'device': [], 'from': [], 'to': []}
            for m in r.members:
                if m.role in ('device', 'from', 'to'):
                    if m.type == 'n':
                        rec[m.role].append(m.ref)
                        need.add(m.ref)
                    else:
                        self.stats['enforcement_way_members_skipped'] += 1
            self.enf.append(rec)
        self.enf_nodes = {}
        if need:
            fp = osmium.FileProcessor(self.pbf, osmium.osm.NODE).with_filter(
                osmium.filter.IdFilter(need))
            for n in fp:
                if n.location.valid():
                    self.enf_nodes[n.id] = (
                        n.location.lat, n.location.lon,
                        parse_maxspeed(n.tags.get('maxspeed')))
            for nid, (lat, lon, _) in self.enf_nodes.items():
                self._add_snap(('n', nid), lat, lon)
        log('enforcement relations: %d, member nodes: %d/%d'
            % (len(self.enf), len(self.enf_nodes), len(need)))

    def _add_snap(self, key, lat, lon):
        if key in self.snap_pts:
            return
        self.snap_pts[key] = (lat, lon)
        self.snap_cells[(int(lat * 100), int(lon * 100))].append(key)

    # -------------------------------------------------------------- main pass
    def read_main(self):
        fp = (osmium.FileProcessor(self.pbf)
              .with_locations('flex_mem')
              .with_areas(osmium.filter.KeyFilter(
                  *(POI_KEYS + ('addr:housenumber', 'place', 'boundary'))))
              .with_filter(osmium.filter.KeyFilter(*FILTER_KEYS)))
        hdr = fp.header
        self.src_date = (hdr.get('osmosis_replication_timestamp')
                         or hdr.get('timestamp') or '')
        self.bbox = None
        try:
            box = hdr.box()
            if box.valid():
                self.bbox = (box.bottom_left.lon, box.bottom_left.lat,
                             box.top_right.lon, box.top_right.lat)
        except Exception:  # header without a bounding box
            pass
        n = 0
        phase = 'n'
        newest = None
        for o in fp:
            n += 1
            if not n & 63:
                ts = o.timestamp
                if newest is None or ts > newest:
                    newest = ts
            if o.is_node():
                tags = o.tags
                loc = o.location
                if not loc.valid():
                    continue
                if tags.get('highway') == 'speed_camera':
                    self.cam_nodes[o.id] = {
                        'lat': loc.lat, 'lon': loc.lon,
                        'maxspeed': parse_maxspeed(tags.get('maxspeed')),
                        'direction': tags.get('direction'),
                        'type': tags.get('enforcement') or 'maxspeed'}
                    self._add_snap(('n', o.id), loc.lat, loc.lon)
                    continue
                self.feature(tags, loc.lat, loc.lon, None)
            elif o.is_way():
                if phase == 'n':
                    phase = 'w'
                    log('nodes done (%d objects), cameras: %d'
                        % (n, len(self.cam_nodes)))
                tags = o.tags
                hw = tags.get('highway')
                if hw:
                    self.highway(o, tags, hw)
            elif o.is_area():
                tags = o.tags
                try:
                    hexwkb = self.wkb.create_multipolygon(o)
                except RuntimeError:
                    self.stats['invalid_areas'] += 1
                    continue
                b = bytes.fromhex(hexwkb)
                npts = struct.unpack_from('<I', b, 18)[0]
                v = struct.unpack_from('<%dd' % (2 * npts), b, 22)
                xs, ys = v[0::2], v[1::2]
                self.feature(tags, (min(ys) + max(ys)) / 2,
                             (min(xs) + max(xs)) / 2, b)
        if not self.src_date and newest is not None:
            # No timestamp in the header (osmium extract drops it): use the
            # newest object seen (sampled), which is close to the dump date.
            self.src_date = newest.strftime('%Y-%m-%dT%H:%M:%SZ')
        log('main pass done: %d objects' % n)

    def highway(self, o, tags, hw):
        coords = None
        if self.snap_cells and hw in DRIVABLE:
            try:
                b = bytes.fromhex(self.wkb.create_linestring(o))
            except RuntimeError:
                b = None
            if b:
                npts = struct.unpack_from('<I', b, 5)[0]
                coords = struct.unpack_from('<%dd' % (2 * npts), b, 9)
                xs, ys = coords[0::2], coords[1::2]
                x0, x1 = int((min(xs) - 0.001) * 100), int((max(xs) + 0.001) * 100)
                y0, y1 = int((min(ys) - 0.001) * 100), int((max(ys) + 0.001) * 100)
                cells = self.snap_cells
                for cy in range(y0, y1 + 1):
                    for cx in range(x0, x1 + 1):
                        keys = cells.get((cy, cx))
                        if keys:
                            self.snap_way(keys, xs, ys, tags, hw)
        name = tags.get('name')
        if not name or hw in HW_SKIP_NAME:
            return
        if coords:
            m = (len(coords) // 4) * 2
            lon, lat = coords[m], coords[m + 1]
        else:
            nodes = o.nodes
            loc = nodes[len(nodes) // 2].location
            if not loc.valid():
                return
            lat, lon = loc.lat, loc.lon
        alts = self.alt_names(tags, name)
        ref = tags.get('ref')
        if ref:
            alts.append(ref)
        self.segs.append((sys.intern(name), tuple(alts), lat, lon,
                          HW_WEIGHT.get(hw.replace('_link', ''), 46)))

    def snap_way(self, keys, xs, ys, tags, hw):
        ow = tags.get('oneway')
        if ow in ('yes', 'true', '1'):
            oneway = 1
        elif ow in ('-1', 'reverse'):
            oneway = -1
        elif ow != 'no' and (hw in ('motorway', 'motorway_link')
                             or tags.get('junction') in ('roundabout', 'circular')):
            oneway = 1
        else:
            oneway = 0
        ms = None
        for key in keys:
            plat, plon = self.snap_pts[key]
            kx = math.cos(math.radians(plat)) * 111320.0
            ky = 110540.0
            best = self.snap_best.get(key)
            bd = best[0] if best else SNAP_RADIUS_M
            px, py = 0.0, 0.0
            ax, ay = (xs[0] - plon) * kx, (ys[0] - plat) * ky
            for i in range(1, len(xs)):
                bx, by = (xs[i] - plon) * kx, (ys[i] - plat) * ky
                dx, dy = bx - ax, by - ay
                l2 = dx * dx + dy * dy
                if l2 > 0:
                    t = ((px - ax) * dx + (py - ay) * dy) / l2
                    t = 0.0 if t < 0 else 1.0 if t > 1 else t
                    d = math.hypot(ax + t * dx, ay + t * dy)
                    if d < bd:
                        if ms is None:
                            ms = parse_maxspeed(tags.get('maxspeed')) or 0
                        bd = d
                        self.snap_best[key] = (
                            d, bearing(ys[i - 1], xs[i - 1], ys[i], xs[i]),
                            oneway, ms or None)
                ax, ay = bx, by

    @staticmethod
    def alt_names(tags, name):
        alts = []
        for k in ALT_NAME_KEYS:
            v = tags.get(k)
            if v and v != name:
                alts.append(v)
        return alts

    def feature(self, tags, lat, lon, geom):
        """Handles a node (geom None) or an area (geom = WKB bytes)."""
        hn = tags.get('addr:housenumber')
        street = None
        hnn = ''
        if hn:
            hnn = normalize_housenumber(hn)
            if hnn and len(hnn) <= 16:
                street = tags.get('addr:street')
                place = None if street else tags.get('addr:place')
                city = tags.get('addr:city')
                self.addrs.append((
                    lat, lon, sys.intern(hnn),
                    sys.intern(street) if street else None,
                    sys.intern(place) if place else None,
                    sys.intern(city) if city else None,
                    geom is not None))
            else:
                self.stats['bad_housenumbers'] += 1
        name = tags.get('name')
        pl = tags.get('place')
        if pl is None and geom is not None and name \
                and tags.get('landuse') == 'allotments':
            pl = 'allotments'
        if pl and name and pl in self.cat_ids:
            pop = 0
            try:
                pop = int((tags.get('population') or '0').replace(' ', ''))
            except ValueError:
                pass
            alts = tuple(self.alt_names(tags, name))
            if geom is None:
                self.place_nodes.append((pl, name, alts, lat, lon, pop))
            else:
                self.place_polys.append(
                    (pl, name, alts, shapely.from_wkb(geom), pop))
            return
        if geom is not None and name and tags.get('boundary') == 'administrative':
            lvl = tags.get('admin_level')
            if lvl in ('4', '6', '8'):
                self.admin_polys.append((int(lvl), name, shapely.from_wkb(geom)))
            return
        cid = None
        for k in POI_KEYS:
            v = tags.get(k)
            if v:
                cid = self.poi_exact.get((k, v))
                if cid is None and v not in ('no', 'vacant', 'yes'):
                    cid = self.poi_wild.get(k)
                if cid is not None:
                    if k == 'railway' and (tags.get('station') == 'subway'
                                           or tags.get('subway') == 'yes'):
                        cid = self.cat_ids['metro']
                    break
        if cid is None:
            return
        alts = self.alt_names(tags, name)
        for k in ('brand', 'operator'):
            v = tags.get(k)
            if v and v != name:
                alts.append(v)
        if not name:
            label, _, unnamed, _ = self.poi_meta[cid]
            if not unnamed:
                return
            brand = tags.get('brand') or tags.get('operator')
            name = '%s %s' % (label, brand) if brand else label
        self.pois.append((lat, lon, cid, name, tuple(alts),
                          street or tags.get('addr:street'), hnn))

    # ---------------------------------------------------------- post-process
    def resolve(self):
        """Builds place entities and assigns localities to all points."""
        ents = []   # dict(kind, cat, name, alts, lat, lon, w, loc, ctx)
        self.ents = ents
        # 1. settlement / named-place entities from nodes
        for typ, name, alts, lat, lon, pop in self.place_nodes:
            ents.append(self._loc_ent(typ, name, alts, lat, lon, pop))
        n_nodes = len(ents)
        nx = np.array([e['lon'] for e in ents], dtype=np.float64)
        ny = np.array([e['lat'] for e in ents], dtype=np.float64)
        nidx = PointIndex(nx, ny)
        nkeys = [namekey(e['name']) for e in ents]
        # 2. place polygons: attach to a same-named node inside, else new
        spolys = []  # (sort key, geom, entity index)
        for typ, name, alts, geom, pop in self.place_polys:
            k = namekey(name)
            ent = -1
            for i in nidx.within(geom):
                if nkeys[i] == k and (ents[i]['typ'] in SETTLEMENT) == (typ in SETTLEMENT):
                    ent = int(i)
                    break
            if ent < 0:
                p = geom.representative_point()
                ents.append(self._loc_ent(typ, name, alts, p.y, p.x, pop))
                ent = len(ents) - 1
            else:
                self.stats['place_poly_merged_with_node'] += 1
            if typ in SETTLEMENT:
                ents[ent]['poly'] = True
                spolys.append((geom.area, geom, ent))
        # 3. admin boundaries: districts/regions + city boundaries by name
        districts, regions = [], []
        for lvl, name, geom in self.admin_polys:
            k = namekey(name)
            for i in nidx.within(geom):
                e = ents[i]
                if nkeys[i] == k and e['typ'] in ('city', 'town') \
                        and not e.get('poly'):
                    e['poly'] = True
                    spolys.append((5.0, geom, int(i)))
                    self.stats['admin_boundary_as_city'] += 1
                    break
            if lvl in (4, 6):
                p = geom.representative_point()
                typ = 'region' if lvl == 4 else 'district'
                ents.append(self._loc_ent(typ, name, (), p.y, p.x, 0))
                (regions if lvl == 4 else districts).append(
                    (geom.area, geom, len(ents) - 1))
        log('places: %d nodes, %d polygons, %d admin; entities %d'
            % (n_nodes, len(self.place_polys), len(self.admin_polys), len(ents)))

        # 4. all points to resolve
        lat = [e['lat'] for e in ents]
        lon = [e['lon'] for e in ents]
        o_ent = 0
        o_addr = len(lat)
        lat += [a[0] for a in self.addrs]
        lon += [a[1] for a in self.addrs]
        o_poi = len(lat)
        lat += [p[0] for p in self.pois]
        lon += [p[1] for p in self.pois]
        o_seg = len(lat)
        lat += [s[2] for s in self.segs]
        lon += [s[3] for s in self.segs]
        x = np.array(lon, dtype=np.float64)
        y = np.array(lat, dtype=np.float64)
        del lat, lon
        idx = PointIndex(x, y)
        n = len(x)
        best = np.full(n, np.inf)
        loc = np.full(n, -1, dtype=np.int64)
        for key, geom, ent in spolys:
            ii = idx.within(geom)
            ii = ii[best[ii] > key]
            # an entity is not its own locality
            ii = ii[ii != ent]
            best[ii] = key
            loc[ii] = ent
        # pseudo-circles for settlements mapped only as nodes
        for i in range(n_nodes):
            e = ents[i]
            r = NODE_RADIUS_KM.get(e['typ'])
            if r is None or e.get('poly'):
                continue
            ii, d = idx.near(e['lon'], e['lat'], r)
            key = 10.0 + d / r
            m = (best[ii] > key) & (ii != i)
            ii = ii[m]
            best[ii] = key[m]
            loc[ii] = i
        dist = self._assign(idx, districts, n)
        reg = self._assign(idx, regions, n)
        log('localities assigned: %d of %d points' % (int((loc >= 0).sum()), n))

        # 5. context of locality entities
        for i, e in enumerate(ents):
            parts = []
            li, di, ri = int(loc[i]), int(dist[i]), int(reg[i])
            if e['typ'] in SETTLEMENT:
                e['loc'] = None
            else:
                e['loc'] = li if li >= 0 and e['typ'] not in ('district', 'region') else None
            if e['loc'] is None:
                for j in (di, ri):
                    if j >= 0 and j != i and ents[j]['name'] != e['name']:
                        parts.append(ents[j]['name'])
            e['ctx'] = ', '.join(parts) if parts else None
        self.o_addr, self.o_poi, self.o_seg = o_addr, o_poi, o_seg
        self.loc, self.dist, self.reg = loc, dist, reg
        # name -> settlement entities, for addr:city / addr:place correction
        self.by_name = defaultdict(list)
        for i, e in enumerate(ents):
            if e['typ'] in SETTLEMENT:
                self.by_name[namekey(e['name'])].append(i)
        self.ent_key = [namekey(e['name']) for e in ents]

    @staticmethod
    def _assign(idx, polys, n):
        best = np.full(n, np.inf)
        res = np.full(n, -1, dtype=np.int64)
        for area, geom, ent in polys:
            ii = idx.within(geom)
            ii = ii[best[ii] > area]
            best[ii] = area
            res[ii] = ent
        return res

    def _loc_ent(self, typ, name, alts, lat, lon, pop):
        cid = self.cat_ids[typ]
        w = self.cats[cid - 1][4]
        if pop > 0:
            w = min(120, w + int(math.log10(pop) * 3))
        return {'kind': KIND_LOCALITY, 'cat': cid, 'typ': typ, 'name': name,
                'alts': alts, 'lat': lat, 'lon': lon, 'w': w, 'loc': None,
                'ctx': None, 'addr': None}

    def nearest_named(self, key, lat, lon, max_km):
        best, bd = -1, max_km * 1000.0
        for i in self.by_name.get(key, ()):
            e = self.ents[i]
            d = dist_m(lat, lon, e['lat'], e['lon'])
            if d < bd:
                best, bd = i, d
        return best

    def group_key(self, i):
        """Grouping scope of point i: locality, else district, else region."""
        li = int(self.loc[i])
        if li >= 0:
            return li
        di = int(self.dist[i])
        if di >= 0:
            return di
        return int(self.reg[i])

    def build_streets(self):
        ents = self.ents
        groups = {}   # (namekey, scope) -> [names Counter, alts set, pts]
        for j, (name, alts, lat, lon, w) in enumerate(self.segs):
            k = (namekey(name), self.group_key(self.o_seg + j))
            g = groups.get(k)
            if g is None:
                g = groups[k] = [Counter(), set(), []]
            g[0][name] += 1
            g[1].update(alts)
            g[2].append((lat, lon, w))
        self.street_ent = {}
        cid = self.cat_ids['street']
        for k, (names, alts, pts) in groups.items():
            mlat = sum(p[0] for p in pts) / len(pts)
            mlon = sum(p[1] for p in pts) / len(pts)
            p = min(pts, key=lambda q: (q[0] - mlat) ** 2 + ((q[1] - mlon) * 0.6) ** 2)
            name = names.most_common(1)[0][0]
            alts.update(n for n in names if n != name)
            ents.append({'kind': KIND_STREET, 'cat': cid, 'typ': 'street',
                         'name': name, 'alts': tuple(sorted(alts)),
                         'lat': p[0], 'lon': p[1],
                         'w': max(q[2] for q in pts),
                         'loc': k[1] if k[1] >= 0 else None, 'ctx': None,
                         'addr': None})
            self.street_ent[k] = len(ents) - 1
        self.stats['street_segments'] = len(self.segs)
        self.stats['streets_from_highways'] = len(groups)
        self.segs = None
        log('streets: %d groups' % len(groups))

    def build_houses(self, db):
        ents = self.ents
        loc = self.loc
        cid_street = self.cat_ids['street']
        cid_area = self.cat_ids['area']
        rows = []
        st = self.stats
        keycache = {}
        # reversed: areas (buildings) come last in the file and should win
        for j in range(len(self.addrs) - 1, -1, -1):
            lat, lon, hn, street, place, city, _ = self.addrs[j]
            i = self.o_addr + j
            li = int(loc[i])
            if city:
                ck = keycache.get(city)
                if ck is None:
                    ck = keycache[city] = namekey(city)
                if li < 0 or self.ent_key[li] != ck:
                    alt = self.nearest_named(ck, lat, lon, 30.0)
                    if alt >= 0 and (li < 0 or not ents[li].get('poly')):
                        li = alt
                        st['addr_city_overrides'] += 1
            scope = li if li >= 0 else self.group_key(i)
            nm = street or place
            if nm:
                nk = keycache.get(nm)
                if nk is None:
                    nk = keycache[nm] = namekey(nm)
            if street:
                holder = self.street_ent.get((nk, scope))
                if holder is None:
                    ents.append({'kind': KIND_STREET, 'cat': cid_street,
                                 'typ': 'street', 'name': street, 'alts': (),
                                 'lat': lat, 'lon': lon, 'w': 48,
                                 'loc': scope if scope >= 0 else None,
                                 'ctx': None, 'addr': None})
                    holder = self.street_ent[(nk, scope)] = len(ents) - 1
                    st['streets_from_addresses'] += 1
            elif place:
                if li >= 0 and self.ent_key[li] == nk:
                    holder = li
                else:
                    holder = self.nearest_named(nk, lat, lon, 15.0)
                    if holder < 0:
                        holder = self.street_ent.get((nk, scope))
                    if holder is None or holder < 0:
                        ents.append({'kind': KIND_STREET, 'cat': cid_area,
                                     'typ': 'area', 'name': place, 'alts': (),
                                     'lat': lat, 'lon': lon, 'w': 45,
                                     'loc': scope if scope >= 0 else None,
                                     'ctx': None, 'addr': None})
                        holder = self.street_ent[(nk, scope)] = len(ents) - 1
                        st['addr_places_created'] += 1
            elif li >= 0:
                holder = li
                st['addr_without_street_on_locality'] += 1
            else:
                st['addr_dropped_no_street_no_locality'] += 1
                continue
            rows.append((holder, hn, round(lat * 1e5), round(lon * 1e5)))
        self.addrs = None
        db.execute('CREATE TEMP TABLE house_raw(ent INTEGER, hn TEXT, '
                   'lat INTEGER, lon INTEGER)')
        db.executemany('INSERT INTO house_raw VALUES (?,?,?,?)', rows)
        st['addresses_tagged'] = len(rows)
        log('addresses resolved: %d' % len(rows))

    def build_pois(self):
        ents = self.ents
        for j, (lat, lon, cid, name, alts, street, hn) in enumerate(self.pois):
            i = self.o_poi + j
            li = int(self.loc[i])
            addr = None
            if street:
                addr = street + (', ' + display_hn(hn) if hn else '')
            ents.append({'kind': KIND_POI, 'cat': cid, 'typ': 'poi',
                         'name': name, 'alts': alts, 'lat': lat, 'lon': lon,
                         'w': self.poi_meta[cid][1],
                         'loc': li if li >= 0 else None, 'ctx': None,
                         'addr': addr, 'street': street})
        self.stats['pois'] = len(self.pois)
        self.pois = None

    def write_places(self, db):
        """Writes place/place_fts/house. Place ids are assigned in order of
        decreasing weight, so FTS results (rowid order) come most important
        first and a LIMIT keeps the best ones."""
        ents = self.ents
        order = sorted(range(len(ents)), key=lambda i: -ents[i]['w'])
        new_id = [0] * len(ents)
        for rank, i in enumerate(order):
            new_id[i] = rank + 1
        prows, frows = [], []
        counts = Counter()
        for i in order:
            e = ents[i]
            pid = new_id[i]
            counts[e['kind']] += 1
            lat5, lon5 = round(e['lat'] * 1e5), round(e['lon'] * 1e5)
            prows.append((pid, e['kind'], e['cat'], e['name'],
                          '; '.join(e['alts']) if e['alts'] else None,
                          new_id[e['loc']] if e['loc'] is not None else None,
                          e['ctx'], e['addr'], lat5, lon5, e['w']))
            ntoks = tokens(e['name'])
            seen = set(ntoks)
            alt = []
            extra = list(e['alts'])
            if e['kind'] == KIND_POI:
                extra.append(self.poi_meta[e['cat']][3])
                extra.append(self.poi_meta[e['cat']][0])
            for a in extra:
                for t in tokens(a):
                    if t not in seen:
                        seen.add(t)
                        alt.append(t)
            ctx = []
            cseen = set()
            parts = []
            if e['loc'] is not None:
                le = ents[e['loc']]
                parts.append(le['name'])
                if le['ctx']:
                    parts.append(le['ctx'])
            if e['ctx']:
                parts.append(e['ctx'])
            if e.get('street'):
                parts.append(e['street'])
            for a in parts:
                for t in tokens(a):
                    if t not in cseen:
                        cseen.add(t)
                        ctx.append(t)
            frows.append((pid, ' '.join(ntoks), ' '.join(alt), ' '.join(ctx),
                          'k%d %s' % (e['kind'], cell_tokens(lat5, lon5))))
        db.executemany('INSERT INTO place VALUES (?,?,?,?,?,?,?,?,?,?,?)', prows)
        db.executemany('INSERT INTO place_fts(rowid, name, alt, ctx, tag) '
                       'VALUES (?,?,?,?,?)', frows)
        del prows, frows
        db.execute('CREATE TEMP TABLE idmap(old INTEGER PRIMARY KEY, new INTEGER)')
        db.executemany('INSERT INTO idmap VALUES (?,?)', enumerate(new_id))
        # Sorted bulk insert; the first row of a (street, hn) wins: rows were
        # collected so that building outlines come before address nodes.
        db.execute('INSERT OR IGNORE INTO house SELECT m.new, r.hn, r.lat, r.lon '
                   'FROM house_raw r JOIN idmap m ON m.old = r.ent '
                   'ORDER BY m.new, r.hn, r.rowid')
        db.execute('DROP TABLE house_raw')
        db.execute('DROP TABLE idmap')
        self.stats['houses'] = db.execute('SELECT count(*) FROM house').fetchone()[0]
        self.stats['localities'] = counts[KIND_LOCALITY]
        self.stats['streets'] = counts[KIND_STREET]
        log('places written: %d, houses: %d' % (len(order), self.stats['houses']))

    # ---------------------------------------------------------------- cameras
    def write_cameras(self, db):
        rows = []
        in_rel = set()
        st = self.stats

        def snap(nid):
            return self.snap_best.get(('n', nid))

        def pos(nid):
            if nid in self.cam_nodes:
                c = self.cam_nodes[nid]
                return c['lat'], c['lon']
            p = self.enf_nodes.get(nid)
            return (p[0], p[1]) if p else None

        def node_ms(nid):
            if nid in self.cam_nodes:
                return self.cam_nodes[nid]['maxspeed']
            p = self.enf_nodes.get(nid)
            return p[2] if p else None

        for r in self.enf:
            devs = [d for d in r['device'] if pos(d)]
            froms = [f for f in r['from'] if pos(f)]
            tos = [t for t in r['to'] if pos(t)]
            in_rel.update(r['device'])
            typ = r['type']
            osm = 'r%d' % r['id']
            if not devs and not froms:
                st['enforcement_without_geometry'] += 1
                continue
            dev = devs[0] if devs else None
            ms_tag = r['maxspeed'] or (node_ms(dev) if dev else None)
            if not froms:
                for d in devs:
                    rows.append(self._standalone(d, typ, ms_tag, osm))
                continue
            for f in froms:
                flat, flon = pos(f)
                end = pos(tos[0]) if tos else None
                if typ == 'average_speed' and end:
                    plat, plon = flat, flon
                    target = end
                else:
                    plat, plon = pos(dev) if dev else (flat, flon)
                    target = pos(dev) if dev else end
                    end = None
                s = snap(f)
                brg = None
                if target and dist_m(flat, flon, target[0], target[1]) > 5.0:
                    brg = bearing(flat, flon, target[0], target[1])
                if s:
                    axis = s[1]
                    if s[2] == -1:
                        axis = (axis + 180.0) % 360.0
                    if s[2] == 0 and brg is not None and ang_diff(axis, brg) > 90.0:
                        axis = (axis + 180.0) % 360.0
                    brg = axis
                ms, from_road = ms_tag, 0
                if ms is None and s and s[3]:
                    ms, from_road = s[3], 1
                rows.append((typ, plat, plon,
                             None if brg is None else int(round(brg)) % 360,
                             0, ms, from_road,
                             end[0] if end else None, end[1] if end else None,
                             osm))
                st['cameras_from_relations'] += 1
        for nid, c in self.cam_nodes.items():
            if nid in in_rel:
                continue
            rows.append(self._standalone(nid, c['type'], c['maxspeed'],
                                         'n%d' % nid))
            st['cameras_standalone'] += 1
        for i, row in enumerate(rows):
            db.execute('INSERT INTO camera VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                       (i + 1,) + row)
            db.execute('INSERT INTO camera_rtree VALUES (?,?,?,?,?)',
                       (i + 1, row[1], row[1], row[2], row[2]))
        st['cameras'] = len(rows)
        st['cameras_with_direction'] = sum(1 for r in rows if r[3] is not None and not r[4])
        st['cameras_bidirectional_axis'] = sum(1 for r in rows if r[3] is not None and r[4])
        st['cameras_no_direction'] = sum(1 for r in rows if r[3] is None)
        st['cameras_with_maxspeed'] = sum(1 for r in rows if r[5] is not None)
        for typ, n in Counter(r[0] for r in rows).items():
            st['cameras_type_' + typ] = n
        log('cameras: %d' % len(rows))

    def _standalone(self, nid, typ, ms_tag, osm):
        c = self.cam_nodes.get(nid)
        if c:
            lat, lon, direction = c['lat'], c['lon'], c['direction']
        else:
            lat, lon = self.enf_nodes[nid][:2]
            direction = None
        s = self.snap_best.get(('n', nid))
        brg, bidir = None, 0
        ms, from_road = ms_tag, 0
        if s:
            d, axis, oneway, road_ms = s
            if oneway:
                brg = axis if oneway == 1 else (axis + 180.0) % 360.0
            elif direction in ('forward', 'backward') and d < 2.0:
                brg = axis if direction == 'forward' else (axis + 180.0) % 360.0
            else:
                brg, bidir = axis % 180.0, 1
            if ms is None and road_ms:
                ms, from_road = road_ms, 1
        return (typ, lat, lon, None if brg is None else int(round(brg)) % 360,
                bidir, ms, from_road, None, None, osm)


def cell_tokens(lat5, lon5):
    """Geo-cell tokens of the FTS `tag` column (mirrors Dart cellTokens).

    Three levels, sizes in degrees (lat x lon): micro 0.0125 x 0.025
    (~1.4 x 1.6 km at 55N), fine 0.05 x 0.1, coarse 0.4 x 0.8."""
    y, x = lat5 + 9000000, lon5 + 18000000
    return 'm%dx%d f%dx%d c%dx%d' % (y // 1250, x // 2500, y // 5000,
                                     x // 10000, y // 40000, x // 80000)


class PointIndex:
    """Points sorted by x for quick polygon / radius candidate lookups."""

    def __init__(self, x, y):
        self.x, self.y = x, y
        self.order = np.argsort(x, kind='stable')
        self.xs = x[self.order]

    def _box(self, minx, miny, maxx, maxy):
        i0, i1 = np.searchsorted(self.xs, [minx, maxx])
        ii = self.order[i0:i1]
        yy = self.y[ii]
        return ii[(yy >= miny) & (yy <= maxy)]

    def within(self, geom):
        ii = self._box(*geom.bounds)
        if len(ii) == 0:
            return ii
        shapely.prepare(geom)
        return ii[shapely.contains_xy(geom, self.x[ii], self.y[ii])]

    def near(self, lon, lat, r_km):
        """Indices within r_km and their distances (km)."""
        dy = r_km / 110.54
        kx = 111.32 * math.cos(math.radians(lat))
        dx = r_km / kx
        ii = self._box(lon - dx, lat - dy, lon + dx, lat + dy)
        d = np.hypot((self.x[ii] - lon) * kx, (self.y[ii] - lat) * 110.54)
        m = d <= r_km
        return ii[m], d[m]


def display_hn(hn):
    """"12к1с2" -> "12 к1 с2", "5а" -> "5А" (mirrors Dart displayHouseNumber)."""
    out = []
    n = len(hn)
    for i, ch in enumerate(hn):
        nxt = hn[i + 1] if i + 1 < n else ''
        prev = hn[i - 1] if i else ''
        if ch in 'кс' and nxt.isdigit() and prev:
            out.append(' ' + ch)
        elif ch.isalpha() and prev.isdigit():
            out.append(ch.upper())
        else:
            out.append(ch)
    return ''.join(out)


SCHEMA = """
PRAGMA page_size = 4096;
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
CREATE TABLE category(id INTEGER PRIMARY KEY, code TEXT NOT NULL,
  label TEXT NOT NULL, kind INTEGER NOT NULL, syn TEXT);
CREATE TABLE place(id INTEGER PRIMARY KEY, kind INTEGER NOT NULL,
  cat INTEGER NOT NULL, name TEXT NOT NULL, alt TEXT, loc INTEGER, ctx TEXT,
  addr TEXT,
  lat INTEGER NOT NULL, lon INTEGER NOT NULL, w INTEGER NOT NULL);
CREATE VIRTUAL TABLE place_fts USING fts5(name, alt, ctx, tag, content='',
  detail=column, columnsize=0, prefix='1 2 3', tokenize="unicode61 remove_diacritics 2");
CREATE TABLE house(street INTEGER NOT NULL, hn TEXT NOT NULL,
  lat INTEGER NOT NULL, lon INTEGER NOT NULL,
  PRIMARY KEY(street, hn)) WITHOUT ROWID;
CREATE TABLE camera(id INTEGER PRIMARY KEY, type TEXT NOT NULL,
  lat REAL NOT NULL, lon REAL NOT NULL, bearing INTEGER,
  bidir INTEGER NOT NULL DEFAULT 0, maxspeed INTEGER,
  maxspeed_from_road INTEGER NOT NULL DEFAULT 0,
  end_lat REAL, end_lon REAL, osm TEXT);
CREATE VIRTUAL TABLE camera_rtree USING rtree(id, min_lat, max_lat,
  min_lon, max_lon);
"""


def main():
    pbf, out = sys.argv[1], sys.argv[2]
    tmp = out + '.tmp'
    if os.path.exists(tmp):
        os.remove(tmp)
    b = Builder(pbf)
    b.read_enforcement()
    b.read_main()
    log('raw: %d addresses, %d pois, %d street segments, %d place nodes'
        % (len(b.addrs), len(b.pois), len(b.segs), len(b.place_nodes)))
    b.resolve()
    b.build_streets()
    db = sqlite3.connect(tmp)
    db.executescript(SCHEMA)
    db.executemany(
        'INSERT INTO category VALUES (?,?,?,?,?)',
        [c[:4] + ((' '.join(dict.fromkeys(
            tokens(b.poi_meta[c[0]][0]) + b.poi_meta[c[0]][3].split()))
            if c[0] in b.poi_meta else None),) for c in b.cats])
    b.build_houses(db)
    b.build_pois()
    b.write_places(db)
    b.write_cameras(db)
    # Header bbox when present; else the data extent (extracts may contain a
    # few far-away objects, e.g. members of long ferry relations).
    bbox = b.bbox or db.execute(
        'SELECT min(lon)/1e5, min(lat)/1e5, max(lon)/1e5, max(lat)/1e5 '
        'FROM house').fetchone()
    meta = {
        'schema_version': SCHEMA_VERSION,
        'norm_version': NORM_VERSION,
        'source_date': b.src_date,
        'source_file': os.path.basename(pbf),
        'built': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'bbox': ','.join('%.5f' % v for v in bbox) if bbox[0] is not None else '',
    }
    for k, v in sorted(b.stats.items()):
        meta['count_' + k] = v
    db.executemany('INSERT INTO meta VALUES (?,?)',
                   [(k, str(v)) for k, v in meta.items()])
    db.commit()
    db.execute("INSERT INTO place_fts(place_fts) VALUES ('optimize')")
    db.commit()
    db.execute('ANALYZE')
    db.commit()
    db.execute('VACUUM')
    db.close()
    os.replace(tmp, out)
    for k, v in meta.items():
        print('  %s = %s' % (k, v))
    log('done: %s, %.1f MB, peak RSS %.0f MB' % (
        out, os.path.getsize(out) / 1e6,
        resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024))


if __name__ == '__main__':
    main()
