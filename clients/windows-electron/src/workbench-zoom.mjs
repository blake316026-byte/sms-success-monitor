export const WORKBENCH_ZOOM_FACTORS = [
  0.5,
  0.67,
  0.75,
  0.8,
  0.9,
  1,
  1.1,
  1.25,
  1.5,
  1.75,
  2
];

export const DEFAULT_WORKBENCH_ZOOM_FACTOR = 1;
export const MIN_WORKBENCH_ZOOM_FACTOR = WORKBENCH_ZOOM_FACTORS[0];
export const MAX_WORKBENCH_ZOOM_FACTOR = WORKBENCH_ZOOM_FACTORS.at(-1);

export function normalizeWorkbenchZoomFactor(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return DEFAULT_WORKBENCH_ZOOM_FACTOR;
  return WORKBENCH_ZOOM_FACTORS.reduce((closest, candidate) => (
    Math.abs(candidate - parsed) < Math.abs(closest - parsed) ? candidate : closest
  ));
}

export function nextWorkbenchZoomFactor(current, direction) {
  if (direction === 'reset') return DEFAULT_WORKBENCH_ZOOM_FACTOR;
  const normalized = normalizeWorkbenchZoomFactor(current);
  const index = WORKBENCH_ZOOM_FACTORS.indexOf(normalized);
  if (direction === 'in') {
    return WORKBENCH_ZOOM_FACTORS[Math.min(index + 1, WORKBENCH_ZOOM_FACTORS.length - 1)];
  }
  if (direction === 'out') {
    return WORKBENCH_ZOOM_FACTORS[Math.max(index - 1, 0)];
  }
  return normalized;
}
