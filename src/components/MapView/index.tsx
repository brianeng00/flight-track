import { useEffect, useRef, useCallback, useState } from 'react';
import maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import type { Flight, MapMode, TrailWaypoint, UserLocation } from '../../types';
import { MAP_STYLES } from '../../lib/mapStyles';
import { flightPopupHTML } from '../FlightPopup';
import { haversineDistance } from '../../lib/geo';

interface Props {
  flights: Flight[];
  location: UserLocation | null;
  mapMode: MapMode;
  loading: boolean;
  error: string | null;
  lastUpdated: string | null;
  rateLimitRetryIn: number | null;
  selectedIcao: string | null;
  onFlightSelect: (flight: Flight | null) => void;
  /** Used by MapView's inline trail fetch — no separate hook needed */
  getToken: () => Promise<string | null>;
  /** Triggers an out-of-schedule OpenSky poll when dead-reckoning deviation is high */
  triggerPoll: () => void;
}

const FLIGHTS_SOURCE = 'flights';
const FLIGHTS_LAYER = 'flights-layer';
const USER_SOURCE = 'user-location';
const USER_LAYER = 'user-dot';
const USER_PULSE_LAYER = 'user-pulse';
const TRAIL_SOURCE = 'flight-trail';
const TRAIL_LAYER = 'flight-trail-layer';

/** Build a GeoJSON FeatureCollection from flights array */
function buildFlightGeoJSON(flights: Flight[]): GeoJSON.FeatureCollection {
  return {
    type: 'FeatureCollection',
    features: flights.map(f => ({
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [f.lng, f.lat] },
      properties: {
        icao24: f.icao24,
        callsign: f.callsign,
        heading: f.headingDeg ?? 0,         // MapLibre rejects null in expressions
        status: f.status,
        altitudeFt: f.altitudeFt ?? 0,
        speedKt: f.speedKt ?? 0,
        distanceNm: f.distanceNm ?? 0,
      },
    })),
  };
}

/** Build GeoJSON for user location dot */
function buildUserGeoJSON(location: UserLocation): GeoJSON.FeatureCollection {
  return {
    type: 'FeatureCollection',
    features: [
      {
        type: 'Feature',
        geometry: { type: 'Point', coordinates: [location.lng, location.lat] },
        properties: {},
      },
    ],
  };
}

function hasWebGL(): boolean {
  try {
    const canvas = document.createElement('canvas');
    return !!(canvas.getContext('webgl') || canvas.getContext('experimental-webgl'));
  } catch {
    return false;
  }
}

/** Empty FeatureCollection — used to clear the trail source */
const EMPTY_TRAIL: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };

function buildTrailGeoJSON(waypoints: TrailWaypoint[]): GeoJSON.FeatureCollection {
  return {
    type: 'FeatureCollection',
    features: [{
      type: 'Feature',
      geometry: {
        type: 'LineString',
        coordinates: waypoints.map(p => [p.lng, p.lat]),
      },
      properties: {},
    }],
  };
}

export function MapView({
  flights,
  location,
  mapMode,
  loading,
  error,
  lastUpdated,
  rateLimitRetryIn,
  selectedIcao,
  onFlightSelect,
  getToken,
  triggerPoll,
}: Props) {
  // Trail state — loading/duration are for the popup only.
  // The actual GeoJSON update is done imperatively (no React state in the map path).
  const [trailLoading, setTrailLoading] = useState(false);
  const [trailDurationMinutes, setTrailDurationMinutes] = useState<number | null>(null);
  // Holds the last rendered trail GeoJSON so style-switch can restore it.
  const currentTrailDataRef = useRef<GeoJSON.FeatureCollection | null>(null);
  // Holds trail data that arrived before the map source was ready (race condition
  // in React dev Strict Mode where the fetch can complete before setupLayers runs).
  const pendingTrailRef = useRef<GeoJSON.FeatureCollection | null>(null);
  // Tracks which icao24 the most recent trail fetch was started for.
  // Used instead of a `cancelled` boolean so Strict Mode double-invoke works:
  // both runs fetch the same icao and both may apply — that's fine.
  // A stale result from a previously-selected aircraft is discarded via ref comparison.
  const trailFetchingForRef = useRef<string | null>(null);

  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const popupRef = useRef<maplibregl.Popup | null>(null);
  const initialCenterSet = useRef(false);
  const iconLoaded = useRef(false);
  // Track the last mode we actually called setStyle for.
  // Initialised to 'street' — same as the map constructor — so the effect is a
  // no-op on first mount (including React dev-mode double-invoke) and only fires
  // when the user genuinely changes to a different mode.
  const lastAppliedMode = useRef<MapMode>('street');
  // Stores the active popup's 'close' handler so we can detach it before
  // programmatic popup.remove() calls. Without this, MapLibre fires 'close'
  // synchronously on remove(), which calls onFlightSelect(null) and resets
  // selectedIcao to null — killing the in-flight trail fetch every time.
  const popupCloseHandlerRef = useRef<(() => void) | null>(null);
  // Always-current snapshot of flights — lets async fetchTrail read the latest
  // dead-reckoned position without being a dep of the trail effect.
  const flightsRef = useRef<Flight[]>(flights);
  const [webglError, setWebglError] = useState(false);

  // ── Initialise map ────────────────────────────────────────────────────────

  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;

    if (!hasWebGL()) {
      setWebglError(true);
      return;
    }

    let map: maplibregl.Map;
    try {
      map = new maplibregl.Map({
        container: containerRef.current,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        style: MAP_STYLES.street as any,
        center: [-74.006, 40.7128], // NYC default, updated when location resolves
        zoom: 8,
        attributionControl: false,
      });
    } catch (err) {
      console.warn('[MapView] Failed to initialise map:', err);
      setWebglError(true);
      return;
    }

    // Attribution (compact)
    map.addControl(new maplibregl.AttributionControl({ compact: true }), 'bottom-right');

    // Navigation controls
    map.addControl(
      new maplibregl.NavigationControl({ showCompass: true, showZoom: true }),
      'bottom-right',
    );

    map.on('load', () => {
      // Ensure the canvas matches the container's actual pixel dimensions.
      // Without this, a flexbox container measured at init might differ.
      map.resize();

      // ── Aircraft icon ─────────────────────────────────────────────────────
      const img = new Image(40, 40);
      img.onload = () => {
        if (!map.hasImage('airplane-icon')) {
          map.addImage('airplane-icon', img, { sdf: true });
        }
        iconLoaded.current = true;
        setupLayers(map);
      };
      img.onerror = () => {
        // fallback: continue without icon
        iconLoaded.current = false;
        setupLayers(map);
      };
      img.src = '/airplane-north.svg';
    });

    // ── WebGL context loss recovery ───────────────────────────────────────
    // Firefox and some systems reclaim GPU contexts aggressively.
    // Prevent the default "context lost = dead" behaviour and force a repaint
    // when the GPU gives the context back.
    const canvas = map.getCanvas();
    const onContextLost = (e: Event) => {
      e.preventDefault(); // allow the browser to restore the context
    };
    const onContextRestored = () => {
      // MapLibre reinitialises internally; nudge it to repaint immediately.
      setTimeout(() => map.triggerRepaint(), 100);
    };
    canvas.addEventListener('webglcontextlost', onContextLost);
    canvas.addEventListener('webglcontextrestored', onContextRestored);

    mapRef.current = map;

    return () => {
      canvas.removeEventListener('webglcontextlost', onContextLost);
      canvas.removeEventListener('webglcontextrestored', onContextRestored);
      popupRef.current?.remove();
      map.remove();
      mapRef.current = null;
      iconLoaded.current = false;
      initialCenterSet.current = false;
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // Keep flightsRef current so async fetchTrail can read latest positions
  useEffect(() => { flightsRef.current = flights; }, [flights]);

  // ── Setup sources and layers ──────────────────────────────────────────────

  const setupLayers = useCallback((map: maplibregl.Map) => {
    // Flights source
    if (!map.getSource(FLIGHTS_SOURCE)) {
      map.addSource(FLIGHTS_SOURCE, {
        type: 'geojson',
        data: { type: 'FeatureCollection', features: [] },
      });
    }

    // User location source
    if (!map.getSource(USER_SOURCE)) {
      map.addSource(USER_SOURCE, {
        type: 'geojson',
        data: { type: 'FeatureCollection', features: [] },
      });
    }

    // User pulse ring
    if (!map.getLayer(USER_PULSE_LAYER)) {
      map.addLayer({
        id: USER_PULSE_LAYER,
        type: 'circle',
        source: USER_SOURCE,
        paint: {
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 5, 12, 15, 28],
          'circle-color': '#3b82f6',
          'circle-opacity': 0.2,
          'circle-stroke-width': 1.5,
          'circle-stroke-color': '#3b82f6',
          'circle-stroke-opacity': 0.5,
        },
      });
    }

    // User dot
    if (!map.getLayer(USER_LAYER)) {
      map.addLayer({
        id: USER_LAYER,
        type: 'circle',
        source: USER_SOURCE,
        paint: {
          'circle-radius': 7,
          'circle-color': '#3b82f6',
          'circle-stroke-width': 2.5,
          'circle-stroke-color': '#fff',
        },
      });
    }

    // Trail source + layer — added BEFORE flights-layer so aircraft icons stay on top
    if (!map.getSource(TRAIL_SOURCE)) {
      map.addSource(TRAIL_SOURCE, { type: 'geojson', data: EMPTY_TRAIL });
      // Apply any trail data that arrived before the source existed (Strict Mode
      // race: fetch can complete before setupLayers runs on the second mount).
      if (pendingTrailRef.current) {
        (map.getSource(TRAIL_SOURCE) as maplibregl.GeoJSONSource).setData(pendingTrailRef.current);
        console.log('[trail] applied pending trail in setupLayers');
        pendingTrailRef.current = null;
      }
    }
    // Trail layer added here (before FLIGHTS_LAYER is added below) so that
    // insertion order puts it underneath aircraft icons. Do NOT pass FLIGHTS_LAYER
    // as beforeId — it doesn't exist yet at this point in setupLayers.
    if (!map.getLayer(TRAIL_LAYER)) {
      map.addLayer({
        id: TRAIL_LAYER,
        type: 'line',
        source: TRAIL_SOURCE,
        layout: { 'line-join': 'round', 'line-cap': 'round' },
        paint: {
          'line-color': '#60a5fa',
          'line-width': 2,
          'line-opacity': 0.7,
          'line-dasharray': [2, 1],
        },
      });
    }

    // Aircraft layer — added after trail so icons render on top
    if (!map.getLayer(FLIGHTS_LAYER)) {
      if (iconLoaded.current) {
        map.addLayer({
          id: FLIGHTS_LAYER,
          type: 'symbol',
          source: FLIGHTS_SOURCE,
          layout: {
            'icon-image': 'airplane-icon',
            'icon-size': ['interpolate', ['linear'], ['zoom'], 6, 0.55, 12, 0.9],
            'icon-rotate': ['get', 'heading'],
            'icon-rotation-alignment': 'map',
            'icon-allow-overlap': true,
            'icon-ignore-placement': true,
            // No text-field — glyph fonts aren't served by OpenFreeMap;
            // callsigns are shown in the sidebar and popup instead.
          },
          paint: {
            'icon-color': [
              'match', ['get', 'status'],
              'climbing',   '#34d399',
              'descending', '#f87171',
              'cruise',     '#60a5fa',
              'ground',     '#94a3b8',
              '#ffffff',
            ],
            'icon-halo-color': 'rgba(0,0,0,0.6)',
            'icon-halo-width': 1.5,
          },
        });
      } else {
        // Fallback circle layer when SVG failed to load
        map.addLayer({
          id: FLIGHTS_LAYER,
          type: 'circle',
          source: FLIGHTS_SOURCE,
          paint: {
            'circle-radius': 6,
            'circle-color': [
              'match', ['get', 'status'],
              'climbing',   '#34d399',
              'descending', '#f87171',
              'cruise',     '#60a5fa',
              'ground',     '#94a3b8',
              '#ffffff',
            ],
            'circle-stroke-width': 1.5,
            'circle-stroke-color': '#000',
          },
        });
      }
    }
  }, []);

  // ── Update flight positions (10fps from dead reckoning) ───────────────────

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !map.isStyleLoaded()) return;
    const source = map.getSource(FLIGHTS_SOURCE) as maplibregl.GeoJSONSource | undefined;
    source?.setData(buildFlightGeoJSON(flights));
  }, [flights]);

  // ── Update user location ──────────────────────────────────────────────────

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !location) return;

    const updateUserDot = () => {
      const source = map.getSource(USER_SOURCE) as maplibregl.GeoJSONSource | undefined;
      source?.setData(buildUserGeoJSON(location));
    };

    if (map.isStyleLoaded()) {
      updateUserDot();
    } else {
      map.once('load', updateUserDot);
    }

    // Fly to user location on first resolve
    if (!initialCenterSet.current) {
      initialCenterSet.current = true;
      const flyTo = () => map.flyTo({ center: [location.lng, location.lat], zoom: 8, duration: 1200 });
      if (map.isStyleLoaded()) flyTo();
      else map.once('load', flyTo);
    }
  }, [location]);

  // ── Trail: fetch imperatively, push directly to map source ──────────────
  // We bypass React state for the GeoJSON update entirely — setState → re-render
  // → effect dep change is too slow / unreliable when the map runs at 10fps.
  // trailLoading / trailDurationMinutes are still React state because they only
  // feed the popup HTML, not the map source.

  useEffect(() => {
    // Clear trail when nothing is selected
    if (!selectedIcao) {
      trailFetchingForRef.current = null;
      currentTrailDataRef.current = null;
      pendingTrailRef.current = null;
      const src = mapRef.current?.getSource(TRAIL_SOURCE) as maplibregl.GeoJSONSource | undefined;
      src?.setData(EMPTY_TRAIL);
      setTrailLoading(false);
      setTrailDurationMinutes(null);
      return;
    }

    // Stamp which aircraft this fetch is for.
    // If the user switches aircraft mid-fetch, the stamp changes and the
    // stale result is discarded without needing any cancellation.
    // Both React Strict Mode runs stamp the same value → both apply fine.
    trailFetchingForRef.current = selectedIcao;
    const icao = selectedIcao;

    setTrailLoading(true);
    setTrailDurationMinutes(null);

    const fetchTrail = async () => {
      try {
        const token = await getToken();
        const headers: HeadersInit = {};
        if (token) headers['Authorization'] = `Bearer ${token}`;

        const res = await fetch(
          `/opensky-api/tracks/all?icao24=${encodeURIComponent(icao)}&time=0`,
          { headers },
        );

        if (!res.ok) throw new Error(`Trail fetch ${res.status}`);

        const data = await res.json() as {
          startTime?: number;
          endTime?: number;
          path?: [number, number | null, number | null, number | null, number | null, boolean][];
        };

        // Discard if user has since selected a different aircraft
        if (icao !== trailFetchingForRef.current) return;

        const path = data.path ?? [];
        const waypoints: TrailWaypoint[] = path
          .filter((p): p is [number, number, number, number | null, number | null, boolean] =>
            p[1] != null && p[2] != null,
          )
          .map(p => ({ lat: p[1], lng: p[2] }));

        const durationMinutes =
          data.startTime != null && data.endTime != null
            ? Math.round((data.endTime - data.startTime) / 60)
            : null;

        if (waypoints.length >= 2) {
          const trailData = buildTrailGeoJSON(waypoints);
          currentTrailDataRef.current = trailData;
          const src = mapRef.current?.getSource(TRAIL_SOURCE) as maplibregl.GeoJSONSource | undefined;
          if (src) {
            src.setData(trailData);
          } else {
            pendingTrailRef.current = trailData;
          }
        }

        // ── Adaptive poll: trigger early if dead-reckoning diverges ────────
        // Compare the most recent trail waypoint's expected position (projected
        // forward at reported speed since the waypoint's timestamp) with the
        // current dead-reckoned position.  If excess deviation > 2 nm, the
        // aircraft has likely manoeuvred and we fetch fresh states immediately.
        if (path.length > 0) {
          const rawLast = path[path.length - 1];
          const lastLat = rawLast[1];
          const lastLng = rawLast[2];
          const lastWptTimeSec = rawLast[0]; // unix seconds
          if (lastLat != null && lastLng != null) {
            const selectedFlight = flightsRef.current.find(f => f.icao24 === icao);
            if (selectedFlight) {
              const ageSeconds = Date.now() / 1000 - lastWptTimeSec;
              const expectedNm = (selectedFlight.speedKt * ageSeconds) / 3600;
              const actualNm = haversineDistance(lastLat, lastLng, selectedFlight.lat, selectedFlight.lng);
              if (actualNm - expectedNm > 2) {
                triggerPoll();
              }
            }
          }
        }

        setTrailLoading(false);
        setTrailDurationMinutes(durationMinutes);
      } catch (err) {
        console.warn('[trail fetch] failed:', err);
        if (icao === trailFetchingForRef.current) setTrailLoading(false);
      }
    };

    // Initial fetch
    fetchTrail();

    // Re-fetch every 60 s so the trail extends as the aircraft moves
    const interval = setInterval(fetchTrail, 10_000);
    return () => clearInterval(interval);
  }, [selectedIcao, getToken]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Trail: refresh popup HTML when trail loading state changes ────────────

  useEffect(() => {
    if (!selectedIcao || !popupRef.current) return;
    const flight = flights.find(f => f.icao24 === selectedIcao);
    if (!flight) return;
    popupRef.current.setHTML(
      flightPopupHTML(flight, { loading: trailLoading, durationMinutes: trailDurationMinutes }),
    );
  }, [trailLoading, trailDurationMinutes, selectedIcao]);

  // ── Map style switching ───────────────────────────────────────────────────

  useEffect(() => {
    // Skip when the map is already displaying this mode (covers first mount and
    // React dev-mode double-invoke, both of which see mapMode === 'street').
    if (mapMode === lastAppliedMode.current) return;
    lastAppliedMode.current = mapMode;

    const map = mapRef.current;
    if (!map) return;
    const style = MAP_STYLES[mapMode];
    // Empty string means MapTiler key is absent — button is disabled, but guard anyway
    if (!style || style === '') return;

    // Snapshot current data before style swap
    const flightsSource = map.getSource(FLIGHTS_SOURCE) as maplibregl.GeoJSONSource | undefined;
    const userSource = map.getSource(USER_SOURCE) as maplibregl.GeoJSONSource | undefined;
    const currentFlightsData = flightsSource ? buildFlightGeoJSON(flights) : null;
    const currentUserData = location && userSource ? buildUserGeoJSON(location) : null;
    const currentTrailData = currentTrailDataRef.current;

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    map.setStyle(style as any);

    const restoreData = () => {
      if (currentFlightsData) {
        (map.getSource(FLIGHTS_SOURCE) as maplibregl.GeoJSONSource)?.setData(currentFlightsData);
      }
      if (currentUserData) {
        (map.getSource(USER_SOURCE) as maplibregl.GeoJSONSource)?.setData(currentUserData);
      }
      if (currentTrailData) {
        (map.getSource(TRAIL_SOURCE) as maplibregl.GeoJSONSource)?.setData(currentTrailData);
      }
    };

    map.once('styledata', () => {
      iconLoaded.current = false;
      const img = new Image(40, 40);
      img.onload = () => {
        if (!map.hasImage('airplane-icon')) {
          map.addImage('airplane-icon', img, { sdf: true });
        }
        iconLoaded.current = true;
        setupLayers(map);
        restoreData();
      };
      img.onerror = () => {
        setupLayers(map);
        restoreData();
      };
      img.src = '/airplane-north.svg';
    });
  }, [mapMode]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Click on aircraft → show popup ───────────────────────────────────────

  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;

    const onClick = (e: maplibregl.MapMouseEvent & { features?: maplibregl.MapGeoJSONFeature[] }) => {
      const feature = e.features?.[0];
      if (!feature) return;

      const props = feature.properties as {
        icao24: string;
        callsign: string;
        heading: number;
        status: string;
        altitudeFt: number;
        speedKt: number;
        distanceNm: number;
      };

      // Find full flight object from current flights list
      const flight = flights.find(f => f.icao24 === props.icao24);
      if (!flight) return;

      onFlightSelect(flight);

      const coords = (feature.geometry as GeoJSON.Point).coordinates as [number, number];

      // Detach close handler BEFORE remove() so MapLibre's synchronous 'close'
      // event doesn't call onFlightSelect(null) and kill the trail fetch.
      if (popupRef.current && popupCloseHandlerRef.current) {
        popupRef.current.off('close', popupCloseHandlerRef.current);
      }
      popupRef.current?.remove();
      popupRef.current = new maplibregl.Popup({ closeButton: true, closeOnClick: false, maxWidth: '280px', offset: 18 })
        .setLngLat(coords)
        .setHTML(flightPopupHTML(flight, { loading: trailLoading, durationMinutes: trailDurationMinutes }))
        .addTo(map);

      const closeHandler = () => { onFlightSelect(null); };
      popupCloseHandlerRef.current = closeHandler;
      popupRef.current.on('close', closeHandler);
    };

    const onMouseEnter = () => { map.getCanvas().style.cursor = 'pointer'; };
    const onMouseLeave = () => { map.getCanvas().style.cursor = ''; };

    map.on('click', FLIGHTS_LAYER, onClick);
    map.on('mouseenter', FLIGHTS_LAYER, onMouseEnter);
    map.on('mouseleave', FLIGHTS_LAYER, onMouseLeave);

    return () => {
      map.off('click', FLIGHTS_LAYER, onClick);
      map.off('mouseenter', FLIGHTS_LAYER, onMouseEnter);
      map.off('mouseleave', FLIGHTS_LAYER, onMouseLeave);
    };
  }, [flights, onFlightSelect]);

  // ── Fly to selected flight (from panel click) ─────────────────────────────

  useEffect(() => {
    if (!selectedIcao) return;
    const map = mapRef.current;
    if (!map) return;
    const flight = flights.find(f => f.icao24 === selectedIcao);
    if (!flight) return;

    map.flyTo({ center: [flight.lng, flight.lat], zoom: Math.max(map.getZoom(), 9), duration: 800 });

    // Show popup for the selected flight.
    // Detach close handler before remove() — same reason as in the click handler.
    if (popupRef.current && popupCloseHandlerRef.current) {
      popupRef.current.off('close', popupCloseHandlerRef.current);
    }
    popupRef.current?.remove();
    popupRef.current = new maplibregl.Popup({ closeButton: true, closeOnClick: false, maxWidth: '280px', offset: 18 })
      .setLngLat([flight.lng, flight.lat])
      .setHTML(flightPopupHTML(flight, { loading: trailLoading, durationMinutes: trailDurationMinutes }))
      .addTo(map);

    const closeHandler = () => { onFlightSelect(null); };
    popupCloseHandlerRef.current = closeHandler;
    popupRef.current.on('close', closeHandler);
  }, [selectedIcao]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Status bar content ────────────────────────────────────────────────────

  const statusPills: Array<{ text: string; type: 'default' | 'warn' | 'error' }> = [];

  if (lastUpdated) {
    const delta = Math.round((Date.now() - new Date(lastUpdated).getTime()) / 1000);
    const label = delta < 5 ? 'just now' : delta < 60 ? `${delta}s ago` : `${Math.round(delta / 60)}m ago`;
    statusPills.push({ text: `${flights.length} flights · ${label}`, type: 'default' });
  } else if (loading) {
    statusPills.push({ text: 'Fetching flights…', type: 'default' });
  }

  if (rateLimitRetryIn != null) {
    statusPills.push({ text: `Rate limited — retry in ${rateLimitRetryIn}s`, type: 'warn' });
  } else if (error) {
    statusPills.push({ text: error, type: 'error' });
  }

  if (webglError) {
    return (
      <div className="map-container" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 12 }}>
        <div style={{ fontSize: 36, opacity: 0.3 }}>🗺</div>
        <div style={{ color: 'var(--text-secondary)', fontSize: 14 }}>Map requires WebGL</div>
        <div style={{ color: 'var(--text-muted)', fontSize: 12 }}>Please use a modern browser with hardware acceleration enabled</div>
      </div>
    );
  }

  // Mount MapLibre directly on the outer div so flex sizing is certain.
  // Overlays are position:absolute children of the same container.
  return (
    <div ref={containerRef} className="map-container">
      {/* Loading overlay — shown only on initial load, not updates */}
      {loading && flights.length === 0 && (
        <div className="loading-overlay">
          <div className="loading-spinner" />
          <span className="loading-text">Loading flights…</span>
        </div>
      )}

      {/* Status pills */}
      {statusPills.length > 0 && (
        <div className="map-status">
          {statusPills.map((pill, i) => (
            <div key={i} className={`map-status__pill${pill.type !== 'default' ? ` map-status__pill--${pill.type}` : ''}`}>
              {pill.text}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
