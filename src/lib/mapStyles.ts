import type { StyleSpecification } from 'maplibre-gl';
import type { MapMode } from '../types';

/**
 * Map tile styles for each mode.
 *
 * Street  → Esri World Dark Gray Canvas raster tiles (no key, dark theme).
 *            Raster avoids the null-type filter errors MapLibre throws on
 *            OpenFreeMap Liberty vector tiles. CARTO's basemap CDN was used
 *            previously but now stamps "API KEY REQUIRED" onto free tiles.
 * Satellite/Terrain → MapTiler (requires VITE_MAPTILER_KEY in .env)
 *
 * Aircraft icon convention (CRITICAL):
 *   The airplane SVG in /public/airplane-north.svg MUST point NORTH (upward).
 *   MapLibre icon-rotate reads degrees clockwise from north — same as OpenSky
 *   true_track — so no offset is needed. If you swap the icon, verify orientation.
 */

const MAPTILER_KEY = import.meta.env.VITE_MAPTILER_KEY as string | undefined;

/**
 * Esri World Dark Gray Canvas raster tiles.
 * Free, no API key, dark theme, global CDN, permissive CORS.
 * Note the {z}/{y}/{x} order — Esri puts row before column, unlike XYZ schemes.
 */
const STREET_STYLE: StyleSpecification = {
  version: 8,
  sources: {
    'esri-dark': {
      type: 'raster',
      tiles: [
        'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}',
      ],
      tileSize: 256,
      maxzoom: 16,
      attribution:
        '© <a href="https://www.esri.com/">Esri</a> | © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    },
  },
  layers: [
    {
      id: 'esri-dark-tiles',
      type: 'raster',
      source: 'esri-dark',
      paint: {
        // Esri's "Dark Gray" canvas is really mid-grey. Pull the brightness
        // range down and desaturate so aircraft icons stay high-contrast
        // against it and the basemap matches the dark app chrome.
        'raster-brightness-max': 0.42,
        'raster-saturation': -0.35,
        'raster-contrast': 0.12,
      },
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
