import type { StyleSpecification } from 'maplibre-gl';
import type { MapMode } from '../types';

/**
 * Map tile styles for each mode.
 *
 * Street  → CARTO Dark Matter raster tiles (no key, dark theme, no complex
 *            vector filter expressions — OpenFreeMap Liberty has null-type
 *            errors in MapLibre because the tile data has nulls where the
 *            style's filter expressions expect numbers).
 * Satellite/Terrain → MapTiler (requires VITE_MAPTILER_KEY in .env)
 *
 * Aircraft icon convention (CRITICAL):
 *   The airplane SVG in /public/airplane-north.svg MUST point NORTH (upward).
 *   MapLibre icon-rotate reads degrees clockwise from north — same as OpenSky
 *   true_track — so no offset is needed. If you swap the icon, verify orientation.
 */

const MAPTILER_KEY = import.meta.env.VITE_MAPTILER_KEY as string | undefined;

/**
 * CARTO Dark Matter raster tiles.
 * Free, no API key, dark theme, globally cached CDN, permissive CORS.
 */
const STREET_STYLE: StyleSpecification = {
  version: 8,
  sources: {
    'carto-dark': {
      type: 'raster',
      tiles: [
        'https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
        'https://b.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
        'https://c.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
        'https://d.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
      ],
      tileSize: 256,
      maxzoom: 19,
      attribution:
        '© <a href="https://carto.com/attributions">CARTO</a> | © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    },
  },
  layers: [
    {
      id: 'carto-dark-tiles',
      type: 'raster',
      source: 'carto-dark',
    },
  ],
};

export const MAP_STYLES: Record<MapMode, StyleSpecification | string> = {
  street: STREET_STYLE,
  satellite: MAPTILER_KEY
    ? `https://api.maptiler.com/maps/satellite/style.json?key=${MAPTILER_KEY}`
    : '',
  terrain: MAPTILER_KEY
    ? `https://api.maptiler.com/maps/outdoor-v2/style.json?key=${MAPTILER_KEY}`
    : '',
};

/** True when a MapTiler key is present and satellite/terrain modes are usable */
export const hasMaptilerKey = Boolean(MAPTILER_KEY);

/** Human-readable labels for each mode */
export const MAP_MODE_LABELS: Record<MapMode, string> = {
  street: 'Street',
  satellite: 'Satellite',
  terrain: 'Terrain',
};

export const MAP_MODES: MapMode[] = ['street', 'satellite', 'terrain'];
