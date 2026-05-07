import { useState } from 'react';
import type { Flight } from '../../types';
import { FlightCard } from '../FlightCard';

interface Props {
  flights: Flight[];
  loading: boolean;
  error: string | null;
  lastUpdated: string | null;
  rateLimitRetryIn: number | null;
  radiusNm: number;
  onRadiusChange: (nm: number) => void;
  selectedIcao: string | null;
  onFlightSelect: (flight: Flight) => void;
}

function formatLastUpdated(iso: string | null): string {
  if (!iso) return '';
  const delta = Math.round((Date.now() - new Date(iso).getTime()) / 1000);
  if (delta < 5) return 'just now';
  if (delta < 60) return `${delta}s ago`;
  return `${Math.round(delta / 60)}m ago`;
}

/** Desktop sidebar */
export function FlightPanel({
  flights,
  loading,
  error,
  lastUpdated,
  rateLimitRetryIn,
  radiusNm,
  onRadiusChange,
  selectedIcao,
  onFlightSelect,
}: Props) {
  return (
    <aside className="flight-panel">
      <div className="flight-panel__header">
        <div className="flight-panel__title">Nearby Flights</div>
        <div className="flight-panel__radius">
          <span className="flight-panel__radius-label">Radius</span>
          <input
            type="range"
            min={25}
            max={200}
            step={25}
            value={radiusNm}
            onChange={e => onRadiusChange(Number(e.target.value))}
            className="radius-slider"
            aria-label="Search radius in nautical miles"
          />
          <span className="flight-panel__radius-value">{radiusNm} nm</span>
        </div>
      </div>

      <div className="flight-panel__meta">
        <span>
          {loading ? 'Fetching…' : `${flights.length} aircraft`}
        </span>
        <span>
          {rateLimitRetryIn != null
            ? `⚠ Rate limited — retry in ${rateLimitRetryIn}s`
            : error
              ? `⚠ ${error}`
              : lastUpdated
                ? `Updated ${formatLastUpdated(lastUpdated)}`
                : ''}
        </span>
      </div>

      <div className="flight-panel__list">
        {flights.length === 0 && !loading ? (
          <div className="flight-panel__empty">
            <span className="flight-panel__empty-icon">✈</span>
            <span>No flights within {radiusNm} nm</span>
            <span style={{ fontSize: 11, marginTop: 4, color: 'var(--text-muted)' }}>
              Try increasing the radius
            </span>
          </div>
        ) : (
          flights.map(f => (
            <FlightCard
              key={f.icao24}
              flight={f}
              selected={f.icao24 === selectedIcao}
              onClick={onFlightSelect}
            />
          ))
        )}
      </div>
    </aside>
  );
}

/** Mobile bottom drawer */
export function MobileDrawer({
  flights,
  loading,
  rateLimitRetryIn,
  radiusNm,
  onRadiusChange,
  selectedIcao,
  onFlightSelect,
}: Props) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className={`mobile-drawer${expanded ? '' : ' mobile-drawer--collapsed'}`}>
      {/* Drag handle + peek row */}
      <div
        className="mobile-drawer__handle-area"
        onClick={() => setExpanded(e => !e)}
        role="button"
        aria-label={expanded ? 'Collapse flight list' : 'Expand flight list'}
        tabIndex={0}
        onKeyDown={e => e.key === 'Enter' && setExpanded(ex => !ex)}
      >
        <div className="mobile-drawer__handle" />
      </div>

      <div className="mobile-drawer__peek">
        <span className="mobile-drawer__peek-label">
          {loading ? 'Fetching flights…' : 'Nearby Flights'}
        </span>
        <span className="mobile-drawer__peek-count">
          {rateLimitRetryIn != null
            ? `Rate limited ${rateLimitRetryIn}s`
            : `${flights.length} within ${radiusNm} nm`}
        </span>
      </div>

      {expanded && (
        <>
          {/* Radius slider in drawer */}
          <div style={{ padding: '0 16px 12px', display: 'flex', alignItems: 'center', gap: 10, borderBottom: '1px solid var(--border)' }}>
            <span style={{ fontSize: 12, color: 'var(--text-secondary)', whiteSpace: 'nowrap' }}>Radius</span>
            <input
              type="range"
              min={25}
              max={200}
              step={25}
              value={radiusNm}
              onChange={e => onRadiusChange(Number(e.target.value))}
              className="radius-slider"
              aria-label="Search radius in nautical miles"
            />
            <span style={{ fontSize: 12, fontFamily: 'var(--font-mono)', color: 'var(--text-primary)', minWidth: 48, textAlign: 'right' }}>
              {radiusNm} nm
            </span>
          </div>

          <div className="mobile-drawer__content">
            {flights.length === 0 && !loading ? (
              <div className="flight-panel__empty">
                <span className="flight-panel__empty-icon">✈</span>
                <span>No flights within {radiusNm} nm</span>
              </div>
            ) : (
              flights.map(f => (
                <FlightCard
                  key={f.icao24}
                  flight={f}
                  selected={f.icao24 === selectedIcao}
                  onClick={flight => {
                    onFlightSelect(flight);
                    setExpanded(false);
                  }}
                />
              ))
            )}
          </div>
        </>
      )}
    </div>
  );
}
