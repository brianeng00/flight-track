import { useCallback, useEffect, useRef, useState } from 'react';
import type { BoundingBox, Flight, OpenSkyTokenResponse, RawStateVector } from '../types';
import { parseStateVector } from '../lib/opensky';
import { deadReckon } from '../lib/deadReckon';
import { sortByDistance } from '../lib/geo';

/**
 * OpenSky Network integration.
 *
 * Architecture:
 *   - OAuth2 client credentials → access_token cached in memory
 *   - Proactive token refresh at (expires_in - 60)s — no missed polls
 *   - 60s poll interval — 1,440 calls/day (well within 4,000 credit/day limit)
 *   - 429 exponential backoff: 120s → 240s → 480s → cap 300s
 *   - Page Visibility API: pause polling when tab hidden, resume on visible
 *   - Dead reckoning at 10fps (setInterval 100ms) between polls
 *     - Uses heading + speed to project positions
 *     - on_ground aircraft are skipped (position stays fixed)
 *
 * Rate budget:
 *   60s interval × 24h = 1,440 credits/day (free tier: 4,000)
 */

// Requests route through Vite's dev proxy (or `vite preview` proxy) to avoid
// CORS — OpenSky's API and OAuth2 token endpoint do not allow browser origins.
const OPENSKY_BASE = '/opensky-api';
const TOKEN_URL = '/opensky-token';
const POLL_INTERVAL_MS = 15_000;
const DR_INTERVAL_MS = 100; // 10fps dead reckoning
const MAX_BACKOFF_MS = 300_000; // 5 minutes

const CLIENT_ID = import.meta.env.VITE_OPENSKY_CLIENT_ID as string | undefined;
const CLIENT_SECRET = import.meta.env.VITE_OPENSKY_CLIENT_SECRET as string | undefined;
const USE_AUTH = Boolean(CLIENT_ID && CLIENT_SECRET);

interface OpenSkyState {
  flights: Flight[];
  loading: boolean;
  /** null = no error */
  error: string | null;
  /** ISO string of last successful poll */
  lastUpdated: string | null;
  /** When rate-limited, seconds until next retry */
  rateLimitRetryIn: number | null;
}

interface TokenCache {
  token: string;
  expiresAt: number; // Date.now() ms
}

export function useOpenSky(
  bbox: BoundingBox | null,
  userLat: number,
  userLng: number,
  radiusNm: number,
) {
  const [state, setState] = useState<OpenSkyState>({
    flights: [],
    loading: false,
    error: null,
    lastUpdated: null,
    rateLimitRetryIn: null,
  });

  // Mutable refs — don't trigger re-renders
  const tokenRef = useRef<TokenCache | null>(null);
  const tokenRefreshTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pollTimer = useRef<ReturnType<typeof setInterval> | null>(null);
  const drTimer = useRef<ReturnType<typeof setInterval> | null>(null);
  const backoffMs = useRef(POLL_INTERVAL_MS);
  const lastPollData = useRef<{ flights: Flight[]; pollTime: number }>({
    flights: [],
    pollTime: 0,
  });
  const isMounted = useRef(true);
  const isPollingPaused = useRef(false);
  const rateLimitCountdown = useRef<ReturnType<typeof setInterval> | null>(null);

  // ── Token management ──────────────────────────────────────────────────────

  // fetchToken reschedules itself for the next proactive refresh, and poll()
  // reschedules itself after a 429 backoff. Both need to call the *current*
  // instance from inside a timer, which a direct self-reference cannot express
  // (the callback would capture itself before it is declared). These refs hold
  // the latest instance; effects below keep them current.
  const fetchTokenRef = useRef<(() => Promise<string | null>) | null>(null);
  const pollRef = useRef<(() => Promise<void>) | null>(null);

  const fetchToken = useCallback(async (): Promise<string | null> => {
    if (!USE_AUTH) return null;
    try {
      const body = new URLSearchParams({
        grant_type: 'client_credentials',
        client_id: CLIENT_ID!,
        client_secret: CLIENT_SECRET!,
      });
      const res = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body,
        signal: AbortSignal.timeout(10_000),
      });
      if (!res.ok) throw new Error(`Token fetch ${res.status}`);
      const data: OpenSkyTokenResponse = await res.json();

      const expiresAt = Date.now() + data.expires_in * 1000;
      tokenRef.current = { token: data.access_token, expiresAt };

      // Schedule proactive refresh 60s before expiry
      const refreshIn = Math.max(0, data.expires_in * 1000 - 60_000);
      if (tokenRefreshTimer.current) clearTimeout(tokenRefreshTimer.current);
      tokenRefreshTimer.current = setTimeout(() => {
        if (isMounted.current) void fetchTokenRef.current?.();
      }, refreshIn);

      return data.access_token;
    } catch (err) {
      console.warn('[useOpenSky] Token fetch failed:', err);
      return null;
    }
  }, []);

  const getToken = useCallback(async (): Promise<string | null> => {
    if (!USE_AUTH) return null;
    if (tokenRef.current && tokenRef.current.expiresAt > Date.now() + 5000) {
      return tokenRef.current.token;
    }
    return fetchToken();
  }, [fetchToken]);

  // ── Flight data polling ───────────────────────────────────────────────────

  const poll = useCallback(async () => {
    if (!bbox || isPollingPaused.current || !isMounted.current) return;

    // Show the spinner on the very first fetch. Done here rather than in the
    // mount effect so no setState happens synchronously in an effect body.
    setState(s => (s.flights.length === 0 && !s.loading ? { ...s, loading: true } : s));

    try {
      const token = await getToken();
      const params = new URLSearchParams({
        lamin: bbox.lamin.toString(),
        lamax: bbox.lamax.toString(),
        lomin: bbox.lomin.toString(),
        lomax: bbox.lomax.toString(),
      });
      const headers: HeadersInit = {};
      if (token) headers['Authorization'] = `Bearer ${token}`;

      const res = await fetch(`${OPENSKY_BASE}/states/all?${params}`, {
        headers,
        signal: AbortSignal.timeout(15_000),
      });

      if (res.status === 429) {
        // Exponential backoff
        backoffMs.current = Math.min(backoffMs.current * 2, MAX_BACKOFF_MS);
        const retryInSec = Math.round(backoffMs.current / 1000);

        // Clear existing poll and schedule retry after backoff
        if (pollTimer.current) clearInterval(pollTimer.current);
        pollTimer.current = setTimeout(
          () => {
            if (isMounted.current) {
              void pollRef.current?.();
              // Re-establish regular interval after recovery
              pollTimer.current = setInterval(() => void pollRef.current?.(), POLL_INTERVAL_MS);
            }
          },
          backoffMs.current,
        ) as unknown as ReturnType<typeof setInterval>;

        // Countdown display
        if (rateLimitCountdown.current) clearInterval(rateLimitCountdown.current);
        let remaining = retryInSec;
        setState(s => ({ ...s, rateLimitRetryIn: remaining }));
        rateLimitCountdown.current = setInterval(() => {
          remaining -= 1;
          if (remaining <= 0) {
            clearInterval(rateLimitCountdown.current!);
            setState(s => ({ ...s, rateLimitRetryIn: null }));
          } else {
            setState(s => ({ ...s, rateLimitRetryIn: remaining }));
          }
        }, 1000);
        return;
      }

      // Reset backoff on success
      backoffMs.current = POLL_INTERVAL_MS;
      if (!res.ok) throw new Error(`OpenSky ${res.status}`);

      const data = await res.json();
      const rawStates: unknown[] = data.states ?? [];

      // Deduplicate raw vectors by icao24 before parsing, keeping the entry
      // with the highest last_contact timestamp (index 4). OpenSky can return
      // the same aircraft from multiple ground stations in one response.
      const byIcao = new Map<string, RawStateVector>();
      for (const sv of rawStates) {
        const s = sv as RawStateVector;
        const existing = byIcao.get(s[0]);
        if (!existing || (existing[4] ?? 0) < (s[4] ?? 0)) {
          byIcao.set(s[0], s);
        }
      }

      const unique = [...byIcao.values()]
        .map(s => parseStateVector(s, userLat, userLng))
        .filter((f): f is Flight => f !== null)
        .filter(f => f.distanceNm <= radiusNm);

      const sorted = sortByDistance(unique);

      if (isMounted.current) {
        lastPollData.current = { flights: sorted, pollTime: Date.now() };
        setState({
          flights: sorted,
          loading: false,
          error: null,
          lastUpdated: new Date().toISOString(),
          rateLimitRetryIn: null,
        });
      }
    } catch (err) {
      console.warn('[useOpenSky] Poll failed:', err);
      if (isMounted.current) {
        setState(s => ({
          ...s,
          loading: false,
          error: s.flights.length > 0 ? 'Data may be stale' : 'Cannot reach OpenSky API',
        }));
      }
    }
  }, [bbox, getToken, userLat, userLng, radiusNm]);

  /**
   * Trigger an out-of-schedule poll — used by MapView when dead-reckoning
   * deviation exceeds threshold.  Debounced: no-op if last poll was < 8s ago.
   */
  const triggerPoll = useCallback(() => {
    if (isPollingPaused.current || !isMounted.current) return;
    if (Date.now() - lastPollData.current.pollTime < 8_000) return;
    void poll();
  }, [poll]);

  // Keep the self-reschedule refs pointing at the current callbacks.
  useEffect(() => {
    fetchTokenRef.current = fetchToken;
    pollRef.current = poll;
  }, [fetchToken, poll]);

  // ── Dead reckoning (10fps position interpolation) ─────────────────────────

  useEffect(() => {
    drTimer.current = setInterval(() => {
      if (!isMounted.current || lastPollData.current.flights.length === 0) return;
      const deltaMs = Date.now() - lastPollData.current.pollTime;

      const interpolated = lastPollData.current.flights.map(f => {
        const { lat, lng } = deadReckon(f.lat, f.lng, f.speedMs, f.headingDeg, deltaMs, f.onGround);
        return { ...f, lat, lng };
      });

      setState(s => ({ ...s, flights: interpolated }));
    }, DR_INTERVAL_MS);

    return () => {
      if (drTimer.current) clearInterval(drTimer.current);
    };
  }, []);

  // ── Polling lifecycle ─────────────────────────────────────────────────────

  useEffect(() => {
    if (!bbox) return;
    isMounted.current = true;

    // poll() sets the loading flag itself on the first fetch.
    void poll();
    pollTimer.current = setInterval(() => void poll(), POLL_INTERVAL_MS);

    // Pause/resume on visibility change
    const handleVisibility = () => {
      if (document.hidden) {
        isPollingPaused.current = true;
      } else {
        isPollingPaused.current = false;
        void poll(); // immediate poll on resume
      }
    };
    document.addEventListener('visibilitychange', handleVisibility);

    return () => {
      if (pollTimer.current) clearInterval(pollTimer.current as unknown as ReturnType<typeof setInterval>);
      if (tokenRefreshTimer.current) clearTimeout(tokenRefreshTimer.current);
      if (rateLimitCountdown.current) clearInterval(rateLimitCountdown.current);
      document.removeEventListener('visibilitychange', handleVisibility);
      isMounted.current = false;
    };
  }, [bbox, poll]);

  return { ...state, getToken, triggerPoll };
}
