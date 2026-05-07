import type { MapMode } from '../types';

/**
 * Map tile style URLs for each mode.
 *
 * Street  → OpenFreeMap "Liberty" dark style (zero config, no key)
 * Satellite/Terrain → MapTiler (requires VITE_MAPTILER_KEY in .env)
 *
 * Aircraft icon convention (CRITICAL):
 *   The airplane SVG in /public/airplane-north.svg MUST point NORTH (upward).
 *   MapLibre icon-rotate reads degrees clockwise from north — same as OpenSky
 *   true_track — so no offset is needed. If you swap the icon, verify orientation.
 */

const MAPTILER_KEY = import.meta.env.VITE_MAPTILER_KEY as string | undefined;

export const MAP_STYLES: Record<MapMode, string> = {
  street: 'https://tiles.openfreemap.org/styles/liberty',
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
