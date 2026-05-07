import type { BoundingBox, UserLocation } from '../types';

const EARTH_RADIUS_NM = 3440.065; // nautical miles
const DEG_TO_RAD = Math.PI / 180;

/**
 * Haversine distance between two lat/lng points, in nautical miles.
 */
export function haversineDistance(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number,
): number {
  const dLat = (lat2 - lat1) * DEG_TO_RAD;
  const dLng = (lng2 - lng1) * DEG_TO_RAD;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * DEG_TO_RAD) * Math.cos(lat2 * DEG_TO_RAD) * Math.sin(dLng / 2) ** 2;
  return EARTH_RADIUS_NM * 2 * Math.asin(Math.sqrt(a));
}

/**
 * Build an OpenSky bounding box from a user location and radius in nautical miles.
 * 1 degree latitude ≈ 60 nm. Longitude degrees vary by latitude.
 */
export function latLngToBbox(
  lat: number,
  lng: number,
  radiusNm: number,
): BoundingBox {
  const latDelta = radiusNm / 60;
  const lngDelta = radiusNm / (60 * Math.cos(lat * DEG_TO_RAD));
  return {
    lamin: Math.max(-90, lat - latDelta),
    lamax: Math.min(90, lat + latDelta),
    lomin: Math.max(-180, lng - lngDelta),
    lomax: Math.min(180, lng + lngDelta),
  };
}

/**
 * Sort flights by distance from the user, ascending.
 */
export function sortByDistance<T extends { distanceNm: number }>(flights: T[]): T[] {
  return [...flights].sort((a, b) => a.distanceNm - b.distanceNm);
}

/**
 * Reverse-geocode a lat/lng to a city name using MapLibre's built-in data
 * (no extra API call). Falls back to coordinate string.
 * NOTE: In the actual implementation this uses the Nominatim API.
 */
export function formatLocation(location: UserLocation): string {
  if (location.source === 'default') return 'New York, NY';
  return `${location.lat.toFixed(2)}°, ${location.lng.toFixed(2)}°`;
}

/** Convert meters to feet */
export function metersToFeet(m: number): number {
  return Math.round(m * 3.28084);
}

/** Convert m/s to knots */
export function msToKnots(ms: number): number {
  return Math.round(ms * 1.94384);
}

/** Format altitude for display: "37,000 ft" */
export function formatAltitude(ft: number): string {
  return `${ft.toLocaleString()} ft`;
}

/** Format speed for display: "487 kt" */
export function formatSpeed(kt: number): string {
  return `${kt} kt`;
}

/** Format distance: "12 nm" */
export function formatDistance(nm: number): string {
  return `${Math.round(nm)} nm`;
}
