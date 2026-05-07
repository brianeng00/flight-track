import type { Flight } from '../../types';
import { formatAltitude, formatSpeed, formatDistance } from '../../lib/geo';
import { STATUS_LABELS } from '../../lib/opensky';

interface Props {
  flight: Flight;
  selected?: boolean;
  onClick?: (flight: Flight) => void;
}

const STATUS_ICONS: Record<string, string> = {
  climbing: '↑',
  descending: '↓',
  cruise: '→',
  ground: '■',
};

export function FlightCard({ flight, selected, onClick }: Props) {
  const { callsign, altitudeFt, speedKt, distanceNm, status, originCountry } = flight;

  return (
    <div
      className={`flight-card${selected ? ' flight-card--selected' : ''}`}
      onClick={() => onClick?.(flight)}
      role="button"
      tabIndex={0}
      onKeyDown={e => e.key === 'Enter' && onClick?.(flight)}
      aria-label={`Flight ${callsign}, ${STATUS_LABELS[status]}, ${formatAltitude(altitudeFt)}, ${formatDistance(distanceNm)} away`}
    >
      <div className={`flight-card__icon flight-card__icon--${status}`}>
        {STATUS_ICONS[status]}
      </div>

      <div className="flight-card__body">
        <div className="flight-card__top">
          <span className="flight-card__callsign">{callsign}</span>
          <span className="flight-card__distance">{formatDistance(distanceNm)}</span>
        </div>

        <div className="flight-card__stats">
          {!flight.onGround && (
            <span className="flight-card__stat">
              <span className="flight-card__stat-value">{formatAltitude(altitudeFt)}</span>
            </span>
          )}
          {speedKt > 0 && (
            <span className="flight-card__stat">
              <span className="flight-card__stat-value">{formatSpeed(speedKt)}</span>
            </span>
          )}
          {originCountry && (
            <span className="flight-card__stat" title="Origin country">
              {originCountry}
            </span>
          )}
          <span className={`flight-card__badge flight-card__badge--${status}`}>
            {STATUS_LABELS[status]}
          </span>
        </div>
      </div>
    </div>
  );
}
