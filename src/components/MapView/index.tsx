import { useEffect, useRef, useCallback, useState } from 'react';
import maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import type { Flight, MapMode, UserLocation } from '../../types';
import { MAP_STYLES } from '../../lib/mapStyles';
import { flightPopupHTML } from '../FlightPopup';

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
}

const FLIGHTS_SOURCE = 'flights';
const FLIGHTS_LAYER = 'flights-layer';
const USER_SOURCE = 'user-location';
const USER_LAYER = 'user-dot';
const USER_PULSE_LAYER = 'user-pulse';

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
        heading: f.headingDeg,
        status: f.status,
        altitudeFt: f.altitudeFt,
        speedKt: f.speedKt,
        distanceNm: f.distanceNm,
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
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const popupRef = useRef<maplibregl.Popup | null>(null);
  const initialCenterSet = useRef(false);
  const iconLoaded = useRef(false);
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
        style: MAP_STYLES.street,
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

    mapRef.current = map;

    return () => {
      popupRef.current?.remove();
      map.remove();
      mapRef.current = null;
      iconLoaded.current = false;
      initialCenterSet.current = false;
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

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

    // Aircraft layer
    if (!map.getLayer(FLIGHTS_LAYER)) {
      if (iconLoaded.current) {
        map.addLayer({
          id: FLIGHTS_LAYER,
          type: 'symbol',
          source: FLIGHTS_SOURCE,
          layout: {
            'icon-image': 'airplane-icon',
            'icon-size': ['interpolate', ['linear'], ['zoom'], 6, 0.55, 12, 0.85],
            'icon-rotate': ['get', 'heading'],
            'icon-rotation-alignment': 'map',
            'icon-allow-overlap': true,
            'icon-ignore-placement': true,
            'text-field': ['get', 'callsign'],
            'text-font': ['Open Sans Bold', 'Arial Unicode MS Bold'],
            'text-size': 11,
            'text-offset': [0, 1.8],
            'text-anchor': 'top',
            'text-allow-overlap': false,
            'text-optional': true,
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
            'text-color': '#f0f2f8',
            'text-halo-color': 'rgba(0,0,0,0.8)',
            'text-halo-width': 1.5,
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

  // ── Map style switching ───────────────────────────────────────────────────

  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const styleUrl = MAP_STYLES[mapMode];
    if (!styleUrl) return;

    // Snapshot current data before style swap
    const flightsSource = map.getSource(FLIGHTS_SOURCE) as maplibregl.GeoJSONSource | undefined;
    const userSource = map.getSource(USER_SOURCE) as maplibregl.GeoJSONSource | undefined;
    const currentFlightsData = flightsSource ? buildFlightGeoJSON(flights) : null;
    const currentUserData = location && userSource ? buildUserGeoJSON(location) : null;

    map.setStyle(styleUrl);

    map.once('styledata', () => {
      iconLoaded.current = false;
      const img = new Image(40, 40);
      img.onload = () => {
        if (!map.hasImage('airplane-icon')) {
          map.addImage('airplane-icon', img, { sdf: true });
        }
        iconLoaded.current = true;
        setupLayers(map);
        if (currentFlightsData) {
          (map.getSource(FLIGHTS_SOURCE) as maplibregl.GeoJSONSource)?.setData(currentFlightsData);
        }
        if (currentUserData) {
          (map.getSource(USER_SOURCE) as maplibregl.GeoJSONSource)?.setData(currentUserData);
        }
      };
      img.onerror = () => {
        setupLayers(map);
        if (currentFlightsData) {
          (map.getSource(FLIGHTS_SOURCE) as maplibregl.GeoJSONSource)?.setData(currentFlightsData);
        }
        if (currentUserData) {
          (map.getSource(USER_SOURCE) as maplibregl.GeoJSONSource)?.setData(currentUserData);
        }
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

      popupRef.current?.remove();
      popupRef.current = new maplibregl.Popup({ closeButton: true, closeOnClick: false, maxWidth: '280px' })
        .setLngLat(coords)
        .setHTML(flightPopupHTML(flight))
        .addTo(map);

      popupRef.current.on('close', () => {
        onFlightSelect(null);
      });
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

    // Show popup for the selected flight
    popupRef.current?.remove();
    popupRef.current = new maplibregl.Popup({ closeButton: true, closeOnClick: false, maxWidth: '280px' })
      .setLngLat([flight.lng, flight.lat])
      .setHTML(flightPopupHTML(flight))
      .addTo(map);

    popupRef.current.on('close', () => {
      onFlightSelect(null);
    });
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

  return (
    <div className="map-container">
      <div ref={containerRef} className="map-canvas" />

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
