/**
 * mtls-apikey/stress/k6-stress-combined.js
 *
 * k6 stress test — mTLS + Plain tiers in a single script (two parallel scenarios).
 *
 * This script merges k6-stress-mtls.js and k6-stress-plain.js into one k6 run,
 * producing a single HTML report and a single combined-summary.json.
 *
 * Scenario model:
 *   mtls_load  — client cert (stress-user-001) + APIKEY STRESS-MTLS-XXXX
 *                hits https://mtls.mapi.example.com/<service>/<path>
 *   plain_load — API key only (APIKEY STRESS-PLAIN-XXXX)
 *                hits https://cert.mapi.example.com/<service>/<path>
 *
 *   The two scenarios run concurrently with independent VU pools.
 *   Each scenario uses the same ramping-vus traffic shape:
 *     ramp-up → steady → ramp-down
 *
 * User pool model (identical for both tiers):
 *   MAX_USERS distinct users; each iteration picks a random index [1, MAX_USERS].
 *   User N owns a window of 10 consecutive service groups:
 *     windowStart = ((N-1) * 10) % 300 + 1
 *   Routes 001-150 → /service-NNN/cars  |  Routes 151-300 → /service-NNN/tax
 *
 * Shared-cert model (mTLS):
 *   k6 does NOT support per-VU cert selection — all mTLS VUs present stress-user-001.
 *   All 1500 mTLS API keys carry kuadrant.io/expected-cn: "stress-user-001".
 *
 * Required env vars:
 *   GW_MTLS   — LoadBalancer IP of the external-mtls-apikey gateway service
 *   GW_PLAIN  — LoadBalancer IP of the external-plain gateway service
 *   CERT_DIR  — directory containing stress-user-001.crt / .key files
 *               (default: <repo-root>/tmp/mtls-demo)
 *
 * Optional env vars (all have sensible defaults):
 *   MTLS_VUS           — peak VU count for mTLS scenario   (default: 10)
 *   PLAIN_VUS          — peak VU count for plain scenario  (default: 10)
 *   MAX_USERS          — random user pool size             (default: 1500)
 *   RAMP_DURATION      — ramp-up duration                  (default: 30s)
 *   STEADY_DURATION    — steady-state duration             (default: 120s)
 *   RAMP_DOWN_DURATION — ramp-down duration                (default: 15s)
 *   SLEEP_MIN          — min sleep between requests (s)    (default: 0.1)
 *   SLEEP_MAX          — max sleep between requests (s)    (default: 0.5)
 *   RESULTS_DIR        — output directory for summary JSON (default: results)
 *
 * Quick-start examples:
 *   # Smoke / connectivity check (1 VU each, 60 s):
 *   GW_MTLS=1.2.3.4 GW_PLAIN=1.2.3.5 \
 *   MTLS_VUS=1 PLAIN_VUS=1 STEADY_DURATION=60s \
 *     ./run-stress-test.sh
 *
 *   # Full load (1500 VUs each tier, 60 + 300 + 30 s):
 *   GW_MTLS=1.2.3.4 GW_PLAIN=1.2.3.5 \
 *   MTLS_VUS=1500 PLAIN_VUS=1500 RAMP_DURATION=60s STEADY_DURATION=300s \
 *     ./run-stress-test.sh
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Tell k6 that 200, 429 and 403 are all "expected" statuses so that
// http_req_failed only counts network-level errors and unexpected codes.
http.setResponseCallback(http.expectedStatuses(200, 429, 403));

// ── Custom metrics — mTLS tier ────────────────────────────────────────────────
const mtlsOkRate   = new Rate('mtls_ok_rate');       // 200 responses
const mtls429Rate  = new Rate('mtls_429_rate');      // 429 responses
const mtls403Rate  = new Rate('mtls_403_rate');      // 403 responses
const mtlsErrRate  = new Rate('mtls_error_rate');    // non-200/429/403
const tlsHandshake = new Trend('tls_handshake_ms', true); // TLS handshake ms

// ── Custom metrics — plain tier ───────────────────────────────────────────────
const plainOkRate  = new Rate('plain_ok_rate');
const plain429Rate = new Rate('plain_429_rate');
const plain403Rate = new Rate('plain_403_rate');
const plainErrRate = new Rate('plain_error_rate');

// ── Env vars (resolved at init stage) ─────────────────────────────────────────
const GW_MTLS   = __ENV.GW_MTLS    || '127.0.0.1';
const GW_PLAIN  = __ENV.GW_PLAIN   || '127.0.0.1';
const CERT_DIR  = __ENV.CERT_DIR   || '/tmp/mtls-demo';
const MTLS_VUS  = parseInt(__ENV.MTLS_VUS   || '10',   10);
const PLAIN_VUS = parseInt(__ENV.PLAIN_VUS  || '10',   10);
const MAX_USERS = parseInt(__ENV.MAX_USERS  || '1500', 10);
const RAMP      = __ENV.RAMP_DURATION       || '30s';
const STEADY    = __ENV.STEADY_DURATION     || '120s';
const RAMP_DOWN = __ENV.RAMP_DOWN_DURATION  || '15s';
const SLEEP_MIN = parseFloat(__ENV.SLEEP_MIN || '0.1');
const SLEEP_MAX = parseFloat(__ENV.SLEEP_MAX || '0.5');

// ── Load shared client cert (init stage — open() is init-only) ────────────────
// All mTLS VUs present the same cert: stress-user-001 (CN=stress-user-001).
// All 1500 mTLS API keys carry expected-cn="stress-user-001".
const sharedCert = open(`${CERT_DIR}/stress-user-001.crt`);
const sharedKey  = open(`${CERT_DIR}/stress-user-001.key`);

// ── Options ───────────────────────────────────────────────────────────────────
export const options = {
  // Map hostnames → Gateway IPs (equivalent to curl --resolve, no DNS required)
  hosts: {
    'mtls.mapi.example.com': GW_MTLS,
    'cert.mapi.example.com': GW_PLAIN,
  },
  // Client cert presented for all requests to mtls.mapi.example.com
  tlsAuth: [
    {
      domains: ['mtls.mapi.example.com'],
      cert:    sharedCert,
      key:     sharedKey,
    },
  ],
  scenarios: {
    mtls_load: {
      executor:         'ramping-vus',
      startVUs:         0,
      gracefulRampDown: '15s',
      exec:             'mtlsDefault',
      stages: [
        { duration: RAMP,      target: MTLS_VUS },
        { duration: STEADY,    target: MTLS_VUS },
        { duration: RAMP_DOWN, target: 0        },
      ],
    },
    plain_load: {
      executor:         'ramping-vus',
      startVUs:         0,
      gracefulRampDown: '15s',
      exec:             'plainDefault',
      stages: [
        { duration: RAMP,      target: PLAIN_VUS },
        { duration: STEADY,    target: PLAIN_VUS },
        { duration: RAMP_DOWN, target: 0         },
      ],
    },
  },
  thresholds: {
    'http_req_duration{scenario:mtls_load}':  ['p(95)<2000', 'p(99)<4000'],
    'http_req_duration{scenario:plain_load}': ['p(95)<1500', 'p(99)<3000'],
    'mtls_error_rate':  ['rate<0.02'],
    'plain_error_rate': ['rate<0.02'],
    'http_req_failed':  ['rate<0.02'],
    'tls_handshake_ms': ['p(95)<500'],
  },
  summaryTrendStats: ['avg', 'min', 'p(50)', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

// ── Shared helpers ────────────────────────────────────────────────────────────
const TOTAL_SERVICES = 300;
const WINDOW_SIZE    = 10;

function paddedUser(n)    { return String(n).padStart(4, '0'); }
function paddedService(n) { return String(n).padStart(3, '0'); }

/**
 * Returns a random route from user N's window of WINDOW_SIZE consecutive services.
 *   windowStart (1-based) = ((N-1) * WINDOW_SIZE) % TOTAL_SERVICES + 1
 *   Routes 001-150 → /service-NNN/cars  |  Routes 151-300 → /service-NNN/tax
 */
function serviceForUser(userIdx) {
  const windowStart = ((userIdx - 1) * WINDOW_SIZE) % TOTAL_SERVICES + 1;
  const slot   = Math.floor(Math.random() * WINDOW_SIZE);
  const svcIdx = (windowStart - 1 + slot) % TOTAL_SERVICES + 1;
  const path   = svcIdx <= 150 ? 'cars' : 'tax';
  return { svcId: paddedService(svcIdx), path };
}

function randSleep() {
  sleep(Math.random() * (SLEEP_MAX - SLEEP_MIN) + SLEEP_MIN);
}

// ── mTLS scenario function ────────────────────────────────────────────────────
export function mtlsDefault() {
  const userIdx = Math.floor(Math.random() * MAX_USERS) + 1;
  const keyId   = paddedUser(userIdx);
  const svc     = serviceForUser(userIdx);

  const res = http.get(
    `https://mtls.mapi.example.com/service-${svc.svcId}/${svc.path}`,
    {
      headers: { 'Authorization': `APIKEY STRESS-MTLS-${keyId}` },
      tags:    { user_id: keyId, service: `stress-svc-${svc.svcId}`, tier: 'mtls' },
    }
  );

  mtlsOkRate.add(res.status === 200);
  mtls429Rate.add(res.status === 429);
  mtls403Rate.add(res.status === 403);
  const isErr = res.status !== 200 && res.status !== 429 && res.status !== 403;
  mtlsErrRate.add(isErr);

  if (res.timings) tlsHandshake.add(res.timings.tls_handshaking);

  if (isErr) {
    console.error(
      `[mtls][${res.status}] user=${keyId} svc=${svc.svcId} path=${svc.path}` +
      ` body=${res.body ? res.body.substring(0, 300) : '<empty>'}` +
      ` headers=${JSON.stringify(res.headers)}`
    );
  }

  check(res, {
    'mtls: 200 or 429 (valid responses)': r => r.status === 200 || r.status === 429,
    'mtls: no 401 (key must be valid)':   r => r.status !== 401,
    'mtls: no 403 (CN+group check pass)': r => r.status !== 403,
    'mtls: no TLS error (exit 56)':       r => r.status !== 0,
  });

  randSleep();
}

// ── Plain scenario function ───────────────────────────────────────────────────
export function plainDefault() {
  const userIdx = Math.floor(Math.random() * MAX_USERS) + 1;
  const keyId   = paddedUser(userIdx);
  const svc     = serviceForUser(userIdx);

  const res = http.get(
    `https://cert.mapi.example.com/service-${svc.svcId}/${svc.path}`,
    {
      headers: { 'Authorization': `APIKEY STRESS-PLAIN-${keyId}` },
      tags:    { user_id: keyId, service: `stress-svc-${svc.svcId}`, tier: 'plain' },
    }
  );

  plainOkRate.add(res.status === 200);
  plain429Rate.add(res.status === 429);
  plain403Rate.add(res.status === 403);
  const isErr = res.status !== 200 && res.status !== 429 && res.status !== 403;
  plainErrRate.add(isErr);

  if (isErr) {
    console.error(
      `[plain][${res.status}] user=${keyId} svc=${svc.svcId} path=${svc.path}` +
      ` body=${res.body ? res.body.substring(0, 300) : '<empty>'}` +
      ` headers=${JSON.stringify(res.headers)}`
    );
  }

  check(res, {
    'plain: 200 or 429 (valid responses)':   r => r.status === 200 || r.status === 429,
    'plain: no 401 (key must be valid)':     r => r.status !== 401,
    'plain: no 403 (group check must pass)': r => r.status !== 403,
  });

  randSleep();
}

// ── Combined end-of-test summary ──────────────────────────────────────────────
export function handleSummary(data) {
  const dir = __ENV.RESULTS_DIR || 'results';
  return {
    [`${dir}/combined-summary.json`]: JSON.stringify(data, null, 2),
  };
}
