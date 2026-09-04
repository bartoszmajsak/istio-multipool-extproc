// One burst of requests per target, all targets running at once.
//
// Overlap is load-bearing: the outage scenarios claim the weighted rule dies
// *while* the healthy pool's own route keeps serving, and two bursts run one
// after the other could not tell that from a pool that recovered in between.
//
// stdout is one record per request:
//
//     <epoch_ms> <label> <status> <pod> <selected> <req_id>
//
//   pod       which pool's pod answered   (echo-basic reports its own name)
//   selected  the endpoint the picker chose, echoed back from the request
//
// Those two disagreeing is the defect, per request, with no statistics
// involved. req_id joins the record to Envoy's own access log line.
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE;
const HOST = __ENV.HOST;
const TAG = __ENV.TAG;
const N = parseInt(__ENV.N, 10);
const TARGETS = (__ENV.TARGETS || '').split(';').filter(Boolean);

// Pod IP -> pool, so the run can say per request whether the picker that chose
// an endpoint belongs to the pool that ended up serving. That correlation is
// the whole claim, and k6 reporting it as a failing check is a plainer way to
// see it than any prose.
const POOL_OF = {};
for (const [pool, ips] of [['a', __ENV.POOL_A_IPS], ['b', __ENV.POOL_B_IPS]]) {
  for (const ip of (ips || '').split(',')) if (ip) POOL_OF[ip.split(':')[0]] = pool;
}

const BODY = JSON.stringify({
  model: 'conformance-fake-model',
  prompt: 'Write as if you were a critic: San Francisco',
});

// Two modes. A fixed burst answers "what did N requests do"; a probe running at
// a steady rate for a duration answers "how long was it broken", which a burst
// cannot - discrete samples land either side of a window and never see its
// shape.
const DURATION = __ENV.DURATION || '';
const RATE = parseInt(__ENV.RATE || '20', 10);

const scenarios = {};
for (const spec of TARGETS) {
  const idx = spec.indexOf('=');
  const label = spec.slice(0, idx);
  const common = {
    exec: 'burst',
    startTime: '0s',
    env: { LABEL: label, TARGET_PATH: spec.slice(idx + 1) },
  };
  scenarios[label.replace(/-/g, '_')] = DURATION
    ? Object.assign({
        executor: 'constant-arrival-rate',
        rate: RATE, timeUnit: '1s', duration: DURATION,
        preAllocatedVUs: 10, maxVUs: 50,
      }, common)
    : Object.assign({ executor: 'per-vu-iterations', vus: 1, iterations: N }, common);
}

export const options = {
  scenarios,
  // The scenarios are evidence gathering, not a load test. A failed request is
  // frequently the expected result, so nothing here is a threshold.
  thresholds: {},
  summaryTrendStats: ['avg', 'p(95)'],
};

export function burst() {
  const label = __ENV.LABEL;
  const reqId = `${TAG}-${label}-${__ITER}-${__VU}`;
  const res = http.post(`${BASE}${__ENV.TARGET_PATH}`, BODY, {
    headers: {
      Host: HOST,
      'Content-Type': 'application/json',
      'X-Req-Id': reqId,
      // Each request on its own connection, so keep-alive cannot pin a worker
      // to one upstream and bias the observed split.
      Connection: 'close',
    },
    timeout: '30s',
    tags: { label },
  });

  let pod = '-';
  let selected = '-';
  try {
    const body = res.json();
    pod = body.pod || '-';
    const headers = body.headers || {};
    const chosen = headers['X-Gateway-Destination-Endpoint'] ||
                   headers['x-gateway-destination-endpoint'];
    if (chosen && chosen.length) selected = chosen[0];
  } catch (e) {
    // A non-200 has no echo body to read. status still tells the story.
  }
  const servedPool = pod.startsWith('backend-a') ? 'a'
                   : pod.startsWith('backend-b') ? 'b' : null;
  const pickerPool = POOL_OF[selected.split(':')[0]] || null;
  // Named per target rather than tagged, because k6's summary lists checks by
  // name and does not break one check down by tag. One line per route is what
  // makes the weighted rule and its single-pool control comparable at a glance.
  check(res, {
    [`[${label}] endpoint chosen by the pool that served it`]: () =>
      servedPool !== null && pickerPool !== null && servedPool === pickerPool,
  });

  console.log(`${Date.now()} ${label} ${res.status} ${pod} ${selected} ${reqId}`);
}
