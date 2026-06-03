import { useEffect, useRef, useState } from 'react';
import type { FlightTrailState, TrailWaypoint } from '../types';

const EMPTY: FlightTrailState = {
  waypoints: [],
  durationMinutes: null,
  loading: false,
  error: null,
};

/**
 * Fetches the historical track for a single aircraft from OpenSky
 * `/api/tracks/all?icao24=…&time=0`.
 *
 * - Fetches when `icao24` becomes non-null, clears when it becomes null.
 * - Per-icao24 session cache avoids re-fetching when the same aircraft is
 *   re-selected within a page session.
 * - Reuses the bearer token from `useOpenSky` — no separate OAuth2 flow.
 * - Null lat/lng waypoints (aircraft not broadcasting position) are filtered out.
 */
export function useFlightTrail(
  icao24: string | null,
  getToken: () => Promise<string | null>,
): FlightTrailState {
  const [state, setState] = useState<FlightTrailState>(EMPTY);
  const cache = useRef<Map<string, FlightTrailState>>(new Map());

  useEffect(() => {
    if (!icao24) {
      setState(EMPTY);
      return;
    }

    // Cache hit — apply immediately, skip network request
    const cached = cache.current.get(icao24);
    if (cached) {
      setState(cached);
      return;
    }

    let cancelled = false;

    (async () => {
      setState({ waypoints: [], durationMinutes: null, loading: true, error: null });

      try {
        const token = await getToken();
        const headers: HeadersInit = {};
        if (token) headers['Authorization'] = `Bearer ${token}`;

        const res = await fetch(
          `/opensky-api/tracks/all?icao24=${encodeURIComponent(icao24)}&time=0`,
          { headers, signal: AbortSignal.timeout(15_000) },
        );

        if (!res.ok) throw new Error(`Trail fetch ${res.status}`);

        const data = await res.json() as {
          startTime?: number;
          endTime?: number;
          path?: [number, number | null, number | null, number | null, number | null, boolean][];
        };

        const path = data.path ?? [];
        console.log(`[useFlightTrail] ${icao24}: ${path.length} raw waypoints`);

        // Filter entries where lat or lng is null — aircraft not broadcasting position
        const waypoints: TrailWaypoint[] = path
          .filter((p): p is [number, number, number, number | null, number | null, boolean] =>
            p[1] != null && p[2] != null,
          )
          .map(p => ({ lat: p[1], lng: p[2] }));

        const durationMinutes =
          data.startTime != null && data.endTime != null
            ? Math.round((data.endTime - data.startTime) / 60)
            : null;

        const result: FlightTrailState = {
          waypoints,
          durationMinutes,
          loading: false,
          error: null,
        };

        if (!cancelled) {
          cache.current.set(icao24, result);
          setState(result);
        }
      } catch (err) {
        console.warn('[useFlightTrail] fetch failed:', err);
        if (!cancelled) {
          setState({ waypoints: [], durationMinutes: null, loading: false, error: 'Trail unavailable' });
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [icao24, getToken]);

  return state;
}
