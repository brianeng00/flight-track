import type { Flight, FlightStatus, RawStateVector } from '../types';
import { haversineDistance, metersToFeet, msToKnots } from './geo';

/**
 * Parse a raw OpenSky state vector array into a typed Flight object.
 * Returns null if the aircraft lacks a valid position (common when
 * it's not broadcasting ADS-B).
 */
export function parseStateVector(
  raw: RawStateVector,
  userLat: number,
  userLng: number,
): Flight | null {
  const [
    icao24,
    callsignRaw,
    originCountry,
    ,               // time_position (unused)
    ,               // last_contact (unused)
    longitude,
    latitude,
    baroAltitude,
    onGround,
    velocity,
    trueTrack,
    verticalRate,
  ] = raw;

  // Must have a position to be useful
  if (latitude == null || longitude == null) return null;

  const altitudeFt = baroAltitude != null ? metersToFeet(baroAltitude) : 0;
  const speedMs = velocity ?? 0;
  const speedKt = msToKnots(speedMs);
  const headingDeg = trueTrack ?? 0;
  const verticalRateMs = verticalRate ?? 0;
  const callsign = (callsignRaw ?? icao24).trim() || icao24;

  const distanceNm = haversineDistance(userLat, userLng, latitude, longitude);
  const status = deriveStatus(onGround, verticalRateMs, altitudeFt);

  return {
    icao24,
    callsign,
    originCountry,
    lat: latitude,
    lng: longitude,
    altitudeFt,
    speedKt,
    headingDeg,
    verticalRateMs,
    onGround,
    speedMs,
    distanceNm,
    status,
  };
}

/**
 * Classify a flight's phase based on ground flag, vertical rate, and altitude.
 *
 * Thresholds:
 *   climbing   vertical_rate > +1 m/s
 *   descending vertical_rate < -1 m/s
 *   ground     on_ground flag or altitude < 500 ft
 */
function deriveStatus(
  onGround: boolean,
  verticalRateMs: number,
  altitudeFt: number,
): FlightStatus {
  if (onGround || altitudeFt < 500) return 'ground';
  if (verticalRateMs > 1) return 'climbing';
  if (verticalRateMs < -1) return 'descending';
  return 'cruise';
}

/** Label map for display */
export const STATUS_LABELS: Record<FlightStatus, string> = {
  cruise: 'Cruise',
  climbing: 'Climbing',
  descending: 'Descending',
  ground: 'Ground',
};
