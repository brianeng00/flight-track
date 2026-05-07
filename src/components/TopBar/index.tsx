import type { MapMode, UserLocation } from '../../types';
import { MAP_MODES, MAP_MODE_LABELS, hasMaptilerKey } from '../../lib/mapStyles';

interface Props {
  location: UserLocation | null;
  mapMode: MapMode;
  onMapModeChange: (mode: MapMode) => void;
}

function locationLabel(location: UserLocation | null): string {
  if (!location) return 'Locating…';
  switch (location.source) {
    case 'gps':
      return `${location.lat.toFixed(3)}°, ${location.lng.toFixed(3)}°`;
    case 'ip':
      return `~${location.lat.toFixed(2)}°, ${location.lng.toFixed(2)}°`;
    default:
      return 'New York, NY';
  }
}

function locationDotClass(location: UserLocation | null): string {
  if (!location) return 'topbar__location-dot topbar__location-dot--default';
  switch (location.source) {
    case 'gps': return 'topbar__location-dot';
    case 'ip': return 'topbar__location-dot topbar__location-dot--approx';
    default: return 'topbar__location-dot topbar__location-dot--default';
  }
}

function maptilerTooltip(mode: MapMode): string | undefined {
  if (mode === 'street') return undefined;
  if (!hasMaptilerKey) return 'Add VITE_MAPTILER_KEY to .env to enable';
  return undefined;
}

export function TopBar({ location, mapMode, onMapModeChange }: Props) {
  return (
    <header className="topbar">
      {/* Logo */}
      <div className="topbar__logo">
        <div className="topbar__logo-icon">✈</div>
        <span className="topbar__logo-name">FlightTrack</span>
      </div>

      {/* Location pill */}
      <div className="topbar__location" title={location?.source === 'gps' ? `Accuracy: ±${Math.round(location.accuracyMeters ?? 0)}m` : undefined}>
        <span className={locationDotClass(location)} />
        <span className="topbar__location-text">{locationLabel(location)}</span>
      </div>

      <div className="topbar__spacer" />

      {/* Map mode toggle */}
      <nav className="topbar__mode-toggle" aria-label="Map mode">
        {MAP_MODES.map(mode => {
          const disabled = mode !== 'street' && !hasMaptilerKey;
          const tooltip = maptilerTooltip(mode);
          return (
            <button
              key={mode}
              className={`topbar__mode-btn${mapMode === mode ? ' topbar__mode-btn--active' : ''}`}
              onClick={() => !disabled && onMapModeChange(mode)}
              disabled={disabled}
              title={tooltip}
              aria-pressed={mapMode === mode}
            >
              {MAP_MODE_LABELS[mode]}
            </button>
          );
        })}
      </nav>
    </header>
  );
}
