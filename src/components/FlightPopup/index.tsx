import type { Flight } from '../../types';
import { formatAltitude, formatSpeed, formatDistance } from '../../lib/geo';
import { STATUS_LABELS } from '../../lib/opensky';

interface Props {
  flight: Flight;
}

const STATUS_BADGE_CLASSES: Record<string, string> = {
  climbing: 'flight-card__badge--climbing',
  descending: 'flight-card__badge--descending',
  cruise: 'flight-card__badge--cruise',
  ground: 'flight-card__badge--ground',
};

const VERTICAL_ICONS: Record<string, string> = {
  climbing: '↑',
  descending: '↓',
  cruise: '→',
  ground: '',
};

/**
 * FlightPopup renders the content inside a MapLibre GL popup.
 * It is serialised to an HTML string and injected into the popup DOM,
 * so it must be a pure render — no event handlers, no state.
 */
export function flightPopupHTML(flight: Flight): string {
  const { callsign, status, altitudeFt, speedKt, distanceNm, verticalRateMs, originCountry } = flight;

  const badge = STATUS_LABELS[status];
  const badgeClass = STATUS_BADGE_CLASSES[status] ?? '';
  const vertIcon = VERTICAL_ICONS[status] ?? '';

  const vertRateStr =
    verticalRateMs !== 0
      ? `${verticalRateMs > 0 ? '+' : ''}${Math.round(verticalRateMs * 196.85)} fpm`
      : '—';

  return `
    <div class="flight-popup">
      <div class="flight-popup__header">
        <span class="flight-popup__callsign">${escapeHTML(callsign)}</span>
        <span class="flight-popup__badge ${escapeHTML(badgeClass)}">${escapeHTML(vertIcon + ' ' + badge).trim()}</span>
      </div>
      <div class="flight-popup__grid">
        <div class="flight-popup__item">
          <div class="flight-popup__label">Altitude</div>
          <div class="flight-popup__value">${flight.onGround ? 'Ground' : escapeHTML(formatAltitude(altitudeFt))}</div>
        </div>
        <div class="flight-popup__item">
          <div class="flight-popup__label">Speed</div>
          <div class="flight-popup__value">${escapeHTML(formatSpeed(speedKt))}</div>
        </div>
        <div class="flight-popup__item">
          <div class="flight-popup__label">Distance</div>
          <div class="flight-popup__value">${escapeHTML(formatDistance(distanceNm))}</div>
        </div>
        <div class="flight-popup__item">
          <div class="flight-popup__label">Vert. rate</div>
          <div class="flight-popup__value">${escapeHTML(vertRateStr)}</div>
        </div>
        ${originCountry ? `
        <div class="flight-popup__item">
          <div class="flight-popup__label">Origin</div>
          <div class="flight-popup__value" style="font-family:var(--font-sans);font-size:12px">${escapeHTML(originCountry)}</div>
        </div>
        ` : ''}
      </div>
      <button class="flight-popup__trail-btn" disabled title="Coming in v2">
        <span>🛤</span> Show flight trail
      </button>
    </div>
  `;
}

function escapeHTML(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/** React component version (not used directly — for potential future use) */
export function FlightPopup({ flight }: Props) {
  const { callsign, status, altitudeFt, speedKt, distanceNm, verticalRateMs, originCountry } = flight;

  const vertRateStr =
    verticalRateMs !== 0
      ? `${verticalRateMs > 0 ? '+' : ''}${Math.round(verticalRateMs * 196.85)} fpm`
      : '—';

  return (
    <div className="flight-popup">
      <div className="flight-popup__header">
        <span className="flight-popup__callsign">{callsign}</span>
        <span className={`flight-popup__badge ${STATUS_BADGE_CLASSES[status]}`}>
          {VERTICAL_ICONS[status]} {STATUS_LABELS[status]}
        </span>
      </div>
      <div className="flight-popup__grid">
        <div className="flight-popup__item">
          <div className="flight-popup__label">Altitude</div>
          <div className="flight-popup__value">
            {flight.onGround ? 'Ground' : formatAltitude(altitudeFt)}
          </div>
        </div>
        <div className="flight-popup__item">
          <div className="flight-popup__label">Speed</div>
          <div className="flight-popup__value">{formatSpeed(speedKt)}</div>
        </div>
        <div className="flight-popup__item">
          <div className="flight-popup__label">Distance</div>
          <div className="flight-popup__value">{formatDistance(distanceNm)}</div>
        </div>
        <div className="flight-popup__item">
          <div className="flight-popup__label">Vert. rate</div>
          <div className="flight-popup__value">{vertRateStr}</div>
        </div>
        {originCountry && (
          <div className="flight-popup__item">
            <div className="flight-popup__label">Origin</div>
            <div className="flight-popup__value" style={{ fontFamily: 'var(--font-sans)', fontSize: 12 }}>
              {originCountry}
            </div>
          </div>
        )}
      </div>
      <button className="flight-popup__trail-btn" disabled title="Coming in v2">
        <span>🛤</span> Show flight trail
      </button>
    </div>
  );
}
