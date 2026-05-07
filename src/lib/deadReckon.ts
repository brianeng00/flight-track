/**
 * Dead reckoning: project an aircraft's position forward in time
 * using its last known speed and heading.
 *
 * Called at 10fps (every 100ms) between 60s OpenSky polls to animate
 * aircraft smoothly across the map.
 *
 * Limitations (acceptable for v1):
 *  - Assumes straight-and-level flight (no turn radius modelling)
 *  - Will diverge during holds, sharp turns, or steep climbs
 *  - on_ground aircraft are skipped (position stays fixed)
 */

const DEG_TO_RAD = Math.PI / 180;
const RAD_TO_DEG = 180 / Math.PI;
const EARTH_RADIUS_M = 6_371_000;

export interface DeadReckonResult {
  lat: number;
  lng: number;
}

/**
 * @param lat         Last known latitude (degrees)
 * @param lng         Last known longitude (degrees)
 * @param speedMs     Ground speed in m/s (from OpenSky `velocity`)
 * @param headingDeg  True track in degrees clockwise from north (from OpenSky `true_track`)
 * @param deltaMs     Time elapsed since last known position (milliseconds)
 * @param onGround    If true, returns the original position unchanged
 */
export function deadReckon(
  lat: number,
  lng: number,
  speedMs: number,
  headingDeg: number,
  deltaMs: number,
  onGround: boolean,
): DeadReckonResult {
  // Aircraft on the ground don't move
  if (onGround || speedMs <= 0 || deltaMs <= 0) {
    return { lat, lng };
  }

  // Distance travelled in metres over the elapsed time
  const distanceM = speedMs * (deltaMs / 1000);

  // Convert to angular distance on a sphere
  const angularDistance = distanceM / EARTH_RADIUS_M;
  const headingRad = headingDeg * DEG_TO_RAD;
  const latRad = lat * DEG_TO_RAD;
  const lngRad = lng * DEG_TO_RAD;

  // Spherical law of cosines projection
  const newLatRad = Math.asin(
    Math.sin(latRad) * Math.cos(angularDistance) +
    Math.cos(latRad) * Math.sin(angularDistance) * Math.cos(headingRad),
  );

  const newLngRad =
    lngRad +
    Math.atan2(
      Math.sin(headingRad) * Math.sin(angularDistance) * Math.cos(latRad),
      Math.cos(angularDistance) - Math.sin(latRad) * Math.sin(newLatRad),
    );

  return {
    lat: newLatRad * RAD_TO_DEG,
    // Normalise longitude to [-180, 180]
    lng: ((newLngRad * RAD_TO_DEG + 540) % 360) - 180,
  };
}
