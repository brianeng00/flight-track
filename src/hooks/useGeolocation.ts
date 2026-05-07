import { useEffect, useState } from 'react';
import type { UserLocation } from '../types';

/**
 * Geolocation fallback chain:
 *   1. navigator.geolocation.getCurrentPosition()  → exact GPS
 *   2. ip-api.com/json/                            → city-level (±20km)
 *   3. Hardcoded NYC default                        → always works
 *
 * State machine:
 *   pending → loading → resolved
 *                     → error (if all three fail, resolves to NYC anyway)
 */

const NYC_DEFAULT: UserLocation = {
  lat: 40.7128,
  lng: -74.006,
  source: 'default',
};

interface GeolocationState {
  location: UserLocation | null;
  loading: boolean;
  error: string | null;
}

async function fetchIpLocation(): Promise<UserLocation> {
  const response = await fetch('https://ip-api.com/json/', { signal: AbortSignal.timeout(5000) });
  if (!response.ok) throw new Error('ip-api failed');
  const data = await response.json();
  if (data.status !== 'success') throw new Error('ip-api returned failure status');
  return { lat: data.lat, lng: data.lon, source: 'ip' };
}

export function useGeolocation(): GeolocationState {
  const [state, setState] = useState<GeolocationState>({
    location: null,
    loading: true,
    error: null,
  });

  useEffect(() => {
    let cancelled = false;

    async function resolve() {
      // 1. Try browser geolocation
      if ('geolocation' in navigator) {
        try {
          const position = await new Promise<GeolocationPosition>((resolve, reject) => {
            navigator.geolocation.getCurrentPosition(resolve, reject, {
              timeout: 8000,
              maximumAge: 60_000,
            });
          });
          if (!cancelled) {
            setState({
              location: {
                lat: position.coords.latitude,
                lng: position.coords.longitude,
                source: 'gps',
                accuracyMeters: position.coords.accuracy,
              },
              loading: false,
              error: null,
            });
          }
          return;
        } catch {
          // Denied or unavailable — fall through to IP lookup
        }
      }

      // 2. Try IP-based location
      try {
        const ipLocation = await fetchIpLocation();
        if (!cancelled) {
          setState({
            location: ipLocation,
            loading: false,
            error: 'Using approximate location (GPS unavailable)',
          });
        }
        return;
      } catch {
        // IP lookup failed — fall through to default
      }

      // 3. NYC hardcode fallback
      if (!cancelled) {
        setState({
          location: NYC_DEFAULT,
          loading: false,
          error: 'Location unavailable — showing New York, NY',
        });
      }
    }

    resolve();

    return () => {
      cancelled = true;
    };
  }, []);

  return state;
}
