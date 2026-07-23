export const SAMPLE_LIMIT = 200;
export const MIN_SAMPLE_LIMIT = 10;
export const MAX_SAMPLE_LIMIT = 500;
export const ALERT_THRESHOLD = 0.5;
export const SCAN_INTERVAL_MS = 60_000;
export const SCAN_FAILURE_RELOAD_THRESHOLD = 2;
export const MAX_CAPTCHA_LOGIN_ATTEMPTS = 10;
export const MAX_TOTP_LOGIN_ATTEMPTS = 5;

export function canAttemptCaptcha(afterFailures) {
  return Number(afterFailures) < MAX_CAPTCHA_LOGIN_ATTEMPTS;
}

export function canAttemptTotp(afterFailures) {
  return Number(afterFailures) < MAX_TOTP_LOGIN_ATTEMPTS;
}

export function normalizeSampleLimit(value) {
  const parsed = Math.round(Number(value));
  if (!Number.isFinite(parsed)) return SAMPLE_LIMIT;
  return Math.min(MAX_SAMPLE_LIMIT, Math.max(MIN_SAMPLE_LIMIT, parsed));
}

export function shouldReloadAfterFailure(
  consecutiveFailures,
  threshold = SCAN_FAILURE_RELOAD_THRESHOLD
) {
  return Number(threshold) > 0 && Number(consecutiveFailures) >= Number(threshold);
}

export function calculateMetrics(statuses, sampleLimit = SAMPLE_LIMIT) {
  const bounded = Array.from(statuses || []).slice(0, normalizeSampleLimit(sampleLimit));
  const successCount = bounded.reduce((count, status) => (
    String(status).trim().toUpperCase() === 'SUCCESS' ? count + 1 : count
  ), 0);
  return {
    sampleCount: bounded.length,
    successCount,
    nonSuccessCount: bounded.length - successCount,
    successRate: bounded.length > 0 ? successCount / bounded.length : 0
  };
}

export function isAlert(metrics, threshold = ALERT_THRESHOLD) {
  return metrics.sampleCount > 0 && metrics.successRate < threshold;
}

export function percentageText(metrics) {
  if (!metrics || metrics.sampleCount === 0) return '--';
  const percentage = metrics.successRate * 100;
  return Number.isInteger(percentage) ? `${percentage}%` : `${percentage.toFixed(1)}%`;
}

export function selectFocus(modules) {
  const withMetrics = modules.filter((module) => module.metrics && module.metrics.sampleCount > 0);
  const alerting = withMetrics.filter((module) => isAlert(module.metrics, module.alertThreshold));
  const byRate = (left, right) => (
    left.metrics.successRate - right.metrics.successRate || left.id.localeCompare(right.id)
  );
  if (alerting.length > 0) return [...alerting].sort(byRate)[0];
  if (withMetrics.length > 0) return [...withMetrics].sort(byRate)[0];
  return modules.find((module) => module.status === 'auth')
    || modules.find((module) => module.status === 'error')
    || modules[0]
    || null;
}

export function summarize(modules) {
  return {
    alertCount: modules.filter((module) => (
      module.metrics && isAlert(module.metrics, module.alertThreshold)
    )).length,
    healthyCount: modules.filter((module) => module.status === 'healthy').length,
    authenticationCount: modules.filter((module) => module.status === 'auth').length,
    errorCount: modules.filter((module) => module.status === 'error').length,
    focus: selectFocus(modules)
  };
}
