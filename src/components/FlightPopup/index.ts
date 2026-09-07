import type { Flight } from '../../types';
import { formatAltitude, formatSpeed, formatDistance } from '../../lib/geo';
import { STATUS_LABELS } from '../../lib/opensky';

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
 * Builds the markup inside a MapLibre GL popup.
 *
 * MapLibre takes an HTML string, not React nodes, so this is a plain string
 * builder rather than a component — every interpolated value must go through
 * escapeHTML(). No event handlers or state can survive here.
 */
export function flightPopupHTML(
  flight: Flight,
  trail?: { loading: boolean; durationMinutes: number | null },
): string {
  const { callsign, status, altitudeFt, speedKt, distanceNm, verticalRateMs, originCountry } = flight;

  const badge = STATUS_LABELS[status];
  const badgeClass = STATUS_BADGE_CLASSES[status] ?? '';
  const vertIcon = VERTICAL_ICONS[status] ?? '';

  const vertRateStr =
    verticalRateMs !== 0
      ? `${verticalRateMs > 0 ? '+' : ''}${Math.round(verticalRateMs * 196.85)} fpm`
      : '—';

  const trailStatus = !trail
    ? ''
    : trail.loading
      ? `<div class="flight-popup__trail-status">🛤 Trail loading…</div>`
      : trail.durationMinutes != null
        ? `<div class="flight-popup__trail-status">🛤 Trail: ${trail.durationMinutes} min</div>`
        : `<div class="flight-popup__trail-status">🛤 Trail active</div>`;

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
      ${trailStatus}
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
