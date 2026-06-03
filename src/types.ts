// ── Core domain types for FlightTrack ──────────────────────────────────────

export type MapMode = 'street' | 'satellite' | 'terrain';

export interface UserLocation {
  lat: number;
  lng: number;
  /** How the location was obtained */
  source: 'gps' | 'ip' | 'default';
  /** Accuracy in meters — only meaningful for 'gps' source */
  accuracyMeters?: number;
}

/**
 * Raw state vector from OpenSky Network /api/states/all
 * All fields can be null when the aircraft isn't broadcasting.
 * Index positions per OpenSky docs.
 */
export type RawStateVector = [
  icao24: string,          // 0  ICAO 24-bit address
  callsign: string | null, // 1  callsign
  origin_country: string,  // 2  country of origin
  time_position: number | null, // 3 unix time of last position update
  last_contact: number,    // 4  unix time of last any update
  longitude: number | null, // 5
  latitude: number | null,  // 6
  baro_altitude: number | null, // 7 barometric altitude (meters)
  on_ground: boolean,       // 8
  velocity: number | null,  // 9 ground speed (m/s)
  true_track: number | null, // 10 heading (degrees, clockwise from north)
  vertical_rate: number | null, // 11 m/s, positive = climbing
  sensors: number[] | null, // 12
  geo_altitude: number | null, // 13 geometric altitude (meters)
  squawk: string | null,    // 14
  spi: boolean,             // 15 special purpose indicator
  position_source: number,  // 16
];

/** Parsed, validated flight state — nulls replaced with undefined */
export interface Flight {
  icao24: string;
  callsign: string;
  originCountry: string;
  lat: number;
  lng: number;
  /** Barometric altitude in feet */
  altitudeFt: number;
  /** Ground speed in knots */
  speedKt: number;
  /** Heading clockwise from north (0–360) */
  headingDeg: number;
  /** Vertical rate: positive = climbing, negative = descending */
  verticalRateMs: number;
  onGround: boolean;
  /** Speed in m/s — used internally for dead reckoning */
  speedMs: number;
  /** Distance from user in nautical miles — computed client-side */
  distanceNm: number;
  /** Cruise | Climbing | Descending | Ground */
  status: FlightStatus;
}

export type FlightStatus = 'cruise' | 'climbing' | 'descending' | 'ground';

export interface BoundingBox {
  lamin: number; // min latitude
  lamax: number; // max latitude
  lomin: number; // min longitude
  lomax: number; // max longitude
}

export interface OpenSkyTokenResponse {
  access_token: string;
  expires_in: number;
  token_type: string;
}

export interface AppError {
  type: 'location' | 'api' | 'rate_limit' | 'tile';
  message: string;
  retryAfterMs?: number;
}

/** A single lat/lng waypoint from an OpenSky flight track */
export interface TrailWaypoint {
  lat: number;
  lng: number;
}

/** State returned by useFlightTrail */
export interface FlightTrailState {
  waypoints: TrailWaypoint[];
  durationMinutes: number | null;
  loading: boolean;
  error: string | null;
}
