import { useState, useMemo } from 'react';
import type { MapMode, Flight } from './types';
import { useGeolocation } from './hooks/useGeolocation';
import { useOpenSky } from './hooks/useOpenSky';
import { latLngToBbox } from './lib/geo';
import { TopBar } from './components/TopBar';
import { MapView } from './components/MapView';
import { FlightPanel, MobileDrawer } from './components/FlightPanel';

const DEFAULT_RADIUS_NM = 100;

export default function App() {
  const [mapMode, setMapMode] = useState<MapMode>('street');
  const [radiusNm, setRadiusNm] = useState(DEFAULT_RADIUS_NM);
  const [selectedIcao, setSelectedIcao] = useState<string | null>(null);

  // ── Location ─────────────────────────────────────────────────────────────
  const { location } = useGeolocation();

  // ── Bounding box for OpenSky ──────────────────────────────────────────────
  const bbox = useMemo(
    () => (location ? latLngToBbox(location.lat, location.lng, radiusNm) : null),
    [location, radiusNm],
  );

  // ── Flight data ───────────────────────────────────────────────────────────
  const { flights, loading, error, lastUpdated, rateLimitRetryIn, getToken, triggerPoll } = useOpenSky(
    bbox,
    location?.lat ?? 0,
    location?.lng ?? 0,
    radiusNm,
  );

  // ── Flight selection ──────────────────────────────────────────────────────
  const handleFlightSelect = (flight: Flight | null) => {
    setSelectedIcao(flight?.icao24 ?? null);
  };

  const panelProps = {
    flights,
    loading,
    error,
    lastUpdated,
    rateLimitRetryIn,
    radiusNm,
    onRadiusChange: setRadiusNm,
    selectedIcao,
    onFlightSelect: handleFlightSelect,
  };

  return (
    <div className="app">
      <TopBar
        location={location}
        mapMode={mapMode}
        onMapModeChange={setMapMode}
      />

      <div className="app__body">
        {/* getToken is passed so MapView can fetch trails itself. Routing trail
            state back up through App props raced with the 10fps position
            updates, so the fetch lives next to the map source it writes to. */}
        <MapView
          flights={flights}
          location={location}
          mapMode={mapMode}
          loading={loading}
          error={error}
          lastUpdated={lastUpdated}
          rateLimitRetryIn={rateLimitRetryIn}
          selectedIcao={selectedIcao}
          onFlightSelect={handleFlightSelect}
          getToken={getToken}
          triggerPoll={triggerPoll}
        />

        {/* Desktop sidebar */}
        <FlightPanel {...panelProps} />

        {/* Mobile bottom drawer */}
        <MobileDrawer {...panelProps} />
      </div>
    </div>
  );
}
