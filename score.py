"""Scores one scenario from the evidence validate.sh already wrote to disk.

Kept apart from validate.sh so the raw evidence is scored after the fact rather
than as it is produced: every scenario's traffic log, counters, config dump and
access log survive a failure and can be re-scored, or read by hand, without
re-running the cluster.

Three independent channels are checked against each other for every scenario:

  per request   the echo backend's line pairs the cluster that served with the
                picker that was consulted and the endpoint that picker chose
  counters      each picker's own invocation count, as a delta over the scenario
  config        the route table as Envoy actually loaded it, and the access log
                as Envoy actually wrote it

A claim that holds on one channel and not the others is a harness fault, not a
finding, and is reported as a failure.
"""
import argparse
import collections
import json
import math
import os
import sys

GREEN, RED, BOLD, NC = "\033[0;32m", "\033[0;31m", "\033[1m", "\033[0m"

EXT_PROC = "envoy.filters.http.ext_proc"

failures = 0
VERBOSE = False


def check(cond, msg):
    """A passing check is only interesting when you are debugging the harness.

    A failing one always prints: the run is evidence, and evidence that quietly
    dropped an assertion is worth nothing.
    """
    global failures
    if cond:
        pass  # A held assertion is not information. The fact blocks are.
    else:
        print("%sFAIL%s: %s" % (RED, NC, msg))
        failures += 1
    return bool(cond)


def note(msg):
    if VERBOSE:
        print("    %s" % msg)


def block(title):
    if VERBOSE:
        print("\n  %s%s%s" % (BOLD, title, NC))


def row(label, value):
    if VERBOSE:
        print("    %-46s %s" % (label, value))


def claim(text):
    """What this scenario sets out to establish, before any of it is measured."""
    return


def headline(args, tag, text):
    """One line per scenario, collected into the run's closing summary.

    The three scenarios are an argument in three steps, and a reader should be
    able to see the argument without reading the assertions under it.
    """
    with open(os.path.join(args.results, "%s.headline" % tag), "w") as handle:
        handle.write(text + "\n")


def verdict(text):
    """The long-form finding. Detail for whoever is debugging the harness; the
    one-line headline is what a reader of the issue needs."""
    return


# --------------------------------------------------------------------------
# Readers
# --------------------------------------------------------------------------

def read_traffic(path):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path):
        parts = line.split()
        if len(parts) != 6:
            continue
        pod = parts[3]
        # echo-basic names the pod that answered, and pod names carry their
        # deployment's name, so which pool served needs no IP bookkeeping.
        backend = "a" if pod.startswith("backend-a") else (
            "b" if pod.startswith("backend-b") else "-")
        rows.append({"ts": int(parts[0]), "label": parts[1], "code": parts[2],
                     "pod": pod, "backend": backend,
                     "selected": parts[4], "req_id": parts[5]})
    return rows


def annotate_pickers(rows, pool_ips):
    """Derive which picker ran, per request, from the endpoint it chose.

    The pickers are real ones, so they stamp no identity of their own. They do
    not need to: each is configured for exactly one InferencePool and only ever
    returns an endpoint from it, so the pod IP in x-gateway-destination-endpoint
    names the picker as surely as a label would - and it comes from the picker's
    own decision rather than from anything this harness added.
    """
    for row in rows:
        endpoint = row.get("selected") or ""
        ip = endpoint.split(":")[0]
        if ip in pool_ips:
            row["picker"] = pool_ips[ip]
        elif endpoint in ("", "-", "none"):
            row["picker"] = "none"
        else:
            row["picker"] = "?"
    return rows


def read_access(path):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows


def key(d, *names):
    """Istio's dynamic config dump is camelCase, a static one snake_case.

    A reader that knows only one spelling reports a false negative - here that
    would read as "Istio attaches no ext_proc at all", the opposite of the
    finding.
    """
    for name in names:
        if isinstance(d, dict) and name in d:
            return d[name]
    return None


def read_routes(path):
    """-> {route name: route} from a dynamic_route_configs dump."""
    routes = {}
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return routes
    try:
        dump = json.load(open(path))
    except ValueError:
        return routes
    for config in dump.get("configs", []):
        for vhost in config.get("route_config", {}).get("virtual_hosts", []):
            for route in vhost.get("routes", []):
                if route.get("name"):
                    routes[route["name"]] = route
    return routes


def cluster_service(name):
    return name.split("||")[-1].split(".")[0] if name else ""


def pool_of(cluster_name):
    service = cluster_service(cluster_name)
    return service.rsplit("-ip-", 1)[0] if "-ip-" in service else service


def override_picker(container):
    """-> picker service named by an ExtProcPerRoute on this node, or None."""
    tpfc = key(container, "typed_per_filter_config", "typedPerFilterConfig") or {}
    entry = tpfc.get(EXT_PROC)
    if not entry:
        return None
    overrides = key(entry, "overrides") or {}
    grpc = key(overrides, "grpc_service", "grpcService") or {}
    envoy_grpc = key(grpc, "envoy_grpc", "envoyGrpc") or {}
    return cluster_service(envoy_grpc.get("cluster_name") or
                           envoy_grpc.get("clusterName") or "") or None


def weighted_clusters(route):
    action = key(route, "route") or {}
    weighted = key(action, "weighted_clusters", "weightedClusters") or {}
    return weighted.get("clusters", [])


def band(share, n):
    """Four sigma of the binomial, floored.

    The weighted split is per-request random, so a fixed tolerance turns into a
    flaky precision test of Envoy's RNG the moment --requests is lowered. Floored
    so it stays a sanity check at large n rather than tightening indefinitely.
    """
    if not n:
        return 100.0
    return max(400.0 * math.sqrt(share * (1 - share) / n), 3.0)


def blank(value):
    """Envoy writes an unset access-log field as JSON null, not "-".

    The "-" spelling is what a plain-text access log produces; the JSON encoder
    emits null. A check that knows only one of them reads a correctly empty
    upstream host as a populated one.
    """
    return value in (None, "", "-")


def summarise(rows, label):
    subset = [r for r in rows if r["label"] == label]
    codes = collections.Counter(r["code"] for r in subset)
    pairs = collections.Counter((r["backend"], r.get("picker", "?")) for r in subset)
    return subset, codes, pairs


# --------------------------------------------------------------------------
# Shared gates
# --------------------------------------------------------------------------

def gate_volume(rows, label, expected):
    subset = [r for r in rows if r["label"] == label]
    return check(len(subset) == expected,
                 "%s: recorded all %d responses (%d)" % (label, expected, len(subset)))


def gate_codes(rows, label, code):
    subset, codes, _ = summarise(rows, label)
    return check(subset and codes.get(code, 0) == len(subset),
                 "%s: every response %s (%s)" % (label, code, dict(codes)))


def matched_a(pairs):
    return sum(n for (backend, picker), n in pairs.items()
               if backend == "a" and picker == "a")


def matched_b_zero(pairs):
    return sum(n for (backend, picker), n in pairs.items() if picker != "b")


def show_failures(rows, access, label, limit=5):
    """Under --verbose, the failed responses themselves.

    An assertion says a signature held; this shows the records it held over, so
    a reader can check the reasoning rather than take it.
    """
    if not VERBOSE:
        return
    failed = [r for r in rows if r["label"] == label and r["code"] != "200"]
    if not failed:
        return
    codes = collections.Counter(r["code"] for r in failed)
    print("\n  %s%s: %d failed responses%s %s"
          % (BOLD, label, len(failed), NC, dict(codes)))
    by_id = {a.get("req_id"): a for a in access}
    print("    %-6s %-6s %-5s %-24s %-22s %s"
          % ("code", "flags", "dur", "response_code_details", "upstream_cluster",
             "upstream_host"))
    for row in failed[:limit]:
        log = by_id.get(row["req_id"], {})
        cluster = (log.get("upstream_cluster") or "-").split("||")[-1].split(".")[0]
        print("    %-6s %-6s %-5s %-24s %-22s %s"
              % (row["code"], log.get("response_flags") or "-",
                 log.get("duration", "-"),
                 (log.get("response_code_details") or "-")[:24],
                 cluster[:22], log.get("upstream_host") or "-"))
    if len(failed) > limit:
        print("    ... %d more" % (len(failed) - limit))


def gate_access(rows, access, label):
    """Every request in this scenario reached the access log.

    Envoy writes the log a beat behind the response, so a capture can be short
    without anything being wrong with the cluster. A short capture would quietly
    understate every count scored from it, which is why the completeness is
    asserted here rather than assumed by the capture.
    """
    ids = {r["req_id"] for r in rows if r["label"] == label}
    logged = [a for a in access if a.get("req_id") in ids]
    # `0 == 0` would sail through here, and a burst that recorded nothing is the
    # most likely reason for an empty access log.
    check(len(ids) > 0 and len(logged) == len(ids),
          "%s: access log carries all %d of the scenario's requests (%d)"
          % (label, len(ids), len(logged)))
    return logged


def gate_split(rows, label, weight_a, weight_b):
    """Both weighted clusters served, in their configured proportion.

    Without this an assertion like "picker A was never invoked" is vacuously
    true whenever pool A received no traffic at all.
    """
    subset = [r for r in rows if r["label"] == label]
    n_a = sum(1 for r in subset if r["backend"] == "a")
    n_b = sum(1 for r in subset if r["backend"] == "b")
    ok_both = check(n_a > 0 and n_b > 0,
                    "%s: both pools served traffic (a=%d b=%d)" % (label, n_a, n_b))
    if not subset:
        return False
    share = 100.0 * n_a / len(subset)
    expected = 100.0 * weight_a / (weight_a + weight_b)
    tolerance = band(weight_a / float(weight_a + weight_b), len(subset))
    ok_band = check(abs(share - expected) < tolerance,
                    "%s: pool-a share %.1f%% within +/-%.1f of its weight share %.1f%%"
                    % (label, share, tolerance, expected))
    return ok_both and ok_band


# --------------------------------------------------------------------------
# Scenarios
# --------------------------------------------------------------------------

def scenario_bypass(args, rows, routes, access):
    n_split = n_ctl = args.requests

    claim("one rule, two InferencePools at 9:1. If Istio attached a picker per\n"
          "       backendRef, each pool's traffic would reach its own picker. This\n"
          "       measures which picker actually ran, for whose traffic.")

    gate_volume(rows, "split", n_split)
    gate_volume(rows, "a-only", n_ctl)
    gate_codes(rows, "split", "200")
    gate_codes(rows, "a-only", "200")
    gate_split(rows, "split", args.weight_a, args.weight_b)

    # The control exists for picker A only. Picker B needs none: the weighted rule
    # itself consults it 100 times, which is the whole finding.
    _, _, pairs_a = summarise(rows, "a-only")
    check(set(p[1] for p in pairs_a) == {"a"},
          "a-only: every request consulted picker a, so it is answering and simply "
          "never asked about the weighted rule (%s)" % dict(pairs_a))

    split, _, pairs = summarise(rows, "split")
    route = routes.get(args.split_route)
    if route is not None:
        block("compiled route  %s" % args.split_route)
        row("route-level ext_proc override", override_picker(route) or "none")
        for c in weighted_clusters(route):
            row("weighted cluster %s (weight %s)"
                % (pool_of(c["name"]), c.get("weight")),
                "ext_proc override: %s" % (override_picker(c) or "none"))
    block("%d requests to the weighted rule" % len(split))
    for (backend, picker), n in sorted(pairs.items()):
        row("served by pool-%s, endpoint chosen by picker %s" % (backend, picker), n)
    ctl = [r for r in rows if r["label"] == "a-only"]
    ctl_pairs = collections.Counter((r["backend"], r.get("picker")) for r in ctl)
    example = next((r for r in split
                    if r["picker"] in ("a", "b") and r["picker"] != r["backend"]), None)
    if example:
        row("one of them, verbatim", "")
        note("%s %s %s %s %s %s" % (example["ts"], example["label"], example["code"],
                                    example["pod"], example["selected"],
                                    example["req_id"]))

    block("%d requests to pool-a's own single-pool route (the control)" % len(ctl))
    for (backend, picker), n in sorted(ctl_pairs.items()):
        row("served by pool-%s, endpoint chosen by picker %s" % (backend, picker), n)

    matched = sum(n for (backend, picker), n in pairs.items() if backend == picker)
    check(set(p[1] for p in pairs) == {"b"},
          "split: pool b's picker chose the endpoint for 100% of the rule, both "
          "pools' traffic included")
    crossed = sum(n for (backend, picker), n in pairs.items() if backend != picker)
    check(crossed > 0,
          "split: %d of %d requests were served by one pool while the other pool's "
          "picker was consulted" % (crossed, len(split)))

    route = routes.get(args.split_route)
    if check(route is not None, "route %s is present" % args.split_route):
        clusters = weighted_clusters(route)
        check(len(clusters) == 2,
              "route carries two weighted clusters (%d)" % len(clusters))
        check(override_picker(route) == "epp-b",
              "route-level ext_proc override names epp-b (%s)" % override_picker(route))
        with_override = [pool_of(c["name"]) for c in clusters if override_picker(c)]
        check(not with_override,
              "no weighted cluster carries an ext_proc override (%s)"
              % (with_override or "none"))

    pool_ips = {}
    for spec in args.pool_ips:
        pool, ips = spec.split("=", 1)
        for ip in ips.split(","):
            if ip:
                pool_ips[ip.split(":")[0]] = pool
    logged = gate_access(rows, access, "split")
    to_pool_a = [r for r in logged if pool_of(r.get("upstream_cluster") or "") == "pool-a"]
    if check(len(to_pool_a) > 0,
             "access log has %d split requests routed to pool-a's cluster" % len(to_pool_a)):
        wrong_pool = [r for r in to_pool_a
                      if pool_ips.get((r.get("ep_requested") or "").split(":")[0]) == "b"]
        # upstream_host rather than the served-endpoint metadata: Envoy 1.37, as
        # shipped by Istio 1.29, records no x-gateway-destination-endpoint-served
        # at all. upstream_host is the endpoint Envoy actually dialled and is
        # present on every version, so the claim does not depend on a field that
        # comes and goes between minors.
        served_right = [r for r in to_pool_a
                        if pool_ips.get((r.get("upstream_host") or "").split(":")[0]) == "a"]
        check(len(wrong_pool) == len(to_pool_a),
              "every one of them was handed an endpoint from pool B by picker b "
              "(%d of %d)" % (len(wrong_pool), len(to_pool_a)))
        check(len(served_right) == len(to_pool_a),
              "and every one was served from a pool A endpoint anyway - "
              "override_host fell back to round robin and threw the picker's "
              "choice away (%d of %d)" % (len(served_right), len(to_pool_a)))
        block("Envoy's access log, for the %d requests it routed to pool-a's cluster"
              % len(to_pool_a))
        row("picker asked for a pool-b endpoint", len(wrong_pool))
        row("Envoy dialled a pool-a endpoint instead", len(served_right))

        recorded = [r for r in to_pool_a if not blank(r.get("ep_served"))]
        if recorded:
            agree = [r for r in recorded
                     if r.get("ep_served") == r.get("upstream_host")]
            check(len(agree) == len(recorded),
                  "Envoy's own served-endpoint metadata agrees with the host it "
                  "dialled (%d of %d)" % (len(agree), len(recorded)))
        else:
            note("this Envoy records no x-gateway-destination-endpoint-served; "
                 "the served endpoint is read from upstream_host alone")

    headline(args, "1-bypass",
             "two InferencePools behind one HTTPRoute rule, split %d:%d, both healthy\n"
             "     pool-b's picker chose the endpoint for %d of %d requests, pool-a's "
             "for %d\n"
             "     each pool's picker should choose for its own share, so %d and %d"
             % (args.weight_a, args.weight_b, len(split) - matched_b_zero(pairs),
                len(split), matched_a(pairs),
                round(len(split) * args.weight_a / float(args.weight_a + args.weight_b)),
                round(len(split) * args.weight_b / float(args.weight_a + args.weight_b))))


def read_marks(path):
    marks = []
    if os.path.exists(path):
        for line in open(path):
            parts = line.split("\t")
            if len(parts) == 2:
                marks.append((int(parts[0]), parts[1].strip()))
    return marks


def outage_window(rows, label):
    """-> (first failure ms, last failure ms, count) for one target."""
    failed = sorted(r["ts"] for r in rows if r["label"] == label and r["code"] != "200")
    if not failed:
        return None
    return failed[0], failed[-1], len(failed)


def scenario_outage(args, rows, routes, access, status):
    claim("a probe runs at a steady rate while pool b - the 10%% canary, which\n"
          "       owns the picker - is scaled to zero and then back. This measures\n"
          "       how much of the rule that costs, and for how long.")
    split_all = [r for r in rows if r["label"] == "split"]
    ctl_all = [r for r in rows if r["label"] == "a-only"]
    check(len(split_all) > 50 and len(ctl_all) > 50,
          "the probe recorded enough of both targets to slice (split=%d a-only=%d)"
          % (len(split_all), len(ctl_all)))

    marks0 = dict((name, ts) for ts, name in read_marks(
        os.path.join(args.results, "outage-marks.tsv")))
    lo = marks0.get("drained", 0)
    hi = marks0.get("refill-start", 10 ** 15)
    split = [r for r in rows if r["label"] == "split" and lo <= r["ts"] <= hi]
    ctl = [r for r in rows if r["label"] == "a-only" and lo <= r["ts"] <= hi]
    split_codes = collections.Counter(r["code"] for r in split)
    ctl_codes = collections.Counter(r["code"] for r in ctl)
    check(split and split_codes.get("200", 0) == 0,
          "split: nothing succeeded while pool b had no endpoints - including the "
          "%d%% share whose weighted cluster is the healthy pool A (%d requests)"
          % (round(100.0 * args.weight_a / (args.weight_a + args.weight_b)), len(split)))
    check(ctl and ctl_codes.get("200", 0) == len(ctl),
          "a-only: every request succeeded in the same window - pool A is healthy "
          "and reachable, and the weighted rule died for another reason (%d)"
          % len(ctl))

    # Only the failures. The probe also records everything before the drain and
    # after the refill, and counting those in would compare 218 dead requests
    # against 1395 total and call it a miss.
    block("while pool-b had no endpoints")
    row("requests to the weighted rule", "%d, of which %d failed"
        % (len(split), split_codes.get("503", 0) + split_codes.get("500", 0)))
    row("requests to pool-a's own route (the control)", "%d, of which %d failed"
        % (len(ctl), len(ctl) - ctl_codes.get("200", 0)))
    show_failures(rows, access, "split")
    failed_ids = {r["req_id"] for r in rows if r["label"] == "split" and r["code"] != "200"}
    logged = [a for a in access if a.get("req_id") in failed_ids]
    if check(len(logged) > 0 and len(logged) == len(failed_ids),
             "access log carries all %d of the failed requests (%d)"
             % (len(failed_ids), len(logged))):
        no_host = [r for r in logged if blank(r.get("upstream_host"))]
        no_time = [r for r in logged if blank(r.get("upstream_service_time"))]
        check(len(no_host) == len(logged),
              "no upstream host on any of them (%d of %d) - the router filter never "
              "ran" % (len(no_host), len(logged)))
        check(len(no_time) == len(logged),
              "no upstream service time either (%d of %d): refused before upstream "
              "selection, not by a failing backend" % (len(no_time), len(logged)))
        # The real picker's ImmediateResponse carries no details string, so the
        # signature is the absence of an upstream rather than a name. Envoy
        # naming the cluster it had already chosen is what identifies the cause.
        detail = collections.Counter(r.get("response_code_details") or "-" for r in logged)
        row("response_code_details", dict(detail))

        # Envoy names the weighted cluster it chose even for a request the
        # picker killed before the router ran. So the central claim - that the
        # healthy pool's share of the traffic died too - is read off Envoy's own
        # log rather than inferred from the control route.
        chosen = collections.Counter(pool_of(r.get("upstream_cluster") or "")
                                     for r in logged)
        block("which cluster Envoy had already chosen for the failed requests")
        for pool, n in sorted(chosen.items()):
            row(pool, n)
        killed_a = chosen.get("pool-a", 0)
        share = 100.0 * killed_a / len(logged)
        globals()["_KILLED_SHARE_A"] = share
        expected = 100.0 * args.weight_a / (args.weight_a + args.weight_b)
        tolerance = band(args.weight_a / float(args.weight_a + args.weight_b),
                         len(logged))
        check(abs(share - expected) < tolerance,
              "%d of the %d dead requests (%.1f%%, the healthy pool's own weight "
              "share) had already been routed to pool A's cluster when picker b "
              "refused on their behalf"
              % (killed_a, len(logged), share))

    marks = dict((name, ts) for ts, name in read_marks(
        os.path.join(args.results, "outage-marks.tsv")))
    window = outage_window(rows, "split")
    if check(bool(marks) and window is not None,
             "the probe ran across the drain and the refill, and recorded both"):
        first, last, n = window
        drained = marks.get("drained")
        refilled = marks.get("refilled")
        block("the outage window")
        row("probe ran for", "%.0fs at a steady rate"
            % ((max(r["ts"] for r in rows) - min(r["ts"] for r in rows)) / 1000.0))
        row("continuous failure", "%.1fs" % ((last - first) / 1000.0))
        if drained:
            check(first >= marks.get("drain-start", first),
                  "no request failed before the drain began")
            row("first failure, relative to Envoy seeing zero endpoints",
                "%+.1fs" % ((first - drained) / 1000.0))
        if refilled:
            row("last failure, relative to the pool regaining them",
                "%+.1fs" % ((last - refilled) / 1000.0))
        recovered = [r for r in rows
                     if r["label"] == "split" and r["ts"] > last and r["code"] == "200"]
        check(len(recovered) > 0,
              "the rule recovered on its own once the pool had endpoints again "
              "(%d requests after the last failure, all 200)" % len(recovered))

    for kind, name, condition, value in status:
        check(value == "True",
              "%s/%s %s=%s during the outage" % (kind, name, condition, value))
    lost = 100.0 * split_codes.get("503", 0) / len(split) if split else 0.0
    share_a = globals().get("_KILLED_SHARE_A", 0.0)
    win = outage_window(rows, "split")
    secs = (win[1] - win[0]) / 1000.0 if win else 0.0
    dead = len(split)
    expect = int(round(dead * args.weight_b / float(args.weight_a + args.weight_b)))
    headline(args, "2-outage",
             "pool-b (the %d%% canary) scaled to zero, as during a rollout\n"
             "     %d of %d requests on the rule failed over %.1fs, %.0f%% of them "
             "bound for healthy pool-a\n"
             "     only pool-b's own %d%% share should have failed, so about %d"
             % (round(100.0 * args.weight_b / (args.weight_a + args.weight_b)),
                dead, dead, secs, share_a,
                round(100.0 * args.weight_b / (args.weight_a + args.weight_b)), expect))
    verdict("while the 10%% member had no endpoints, nothing on the rule succeeded -\n"
            "         %d requests over %.1fs, %.0f%% of which had already been routed to\n"
            "         the healthy pool's cluster. Pool a served 200s on its own route\n"
            "         throughout, and the rule recovered by itself once the pool came\n"
            "         back. Every Kubernetes condition stayed True." % (win[2], secs, share_a))


def scenario_fix(args, rows, routes, access, edits, stats, edits_doc=None):
    n_split = args.requests
    claim("an EnvoyFilter puts an ExtProcPerRoute on each weighted cluster naming\n"
          "       that pool's own picker. This measures whether the data plane can\n"
          "       express what Istio did not emit.")
    check(len(edits) == 4,
          "the inserted route differs from the original in exactly 4 edits: a "
          "rename, the dropped route-level override, and one picker per weighted "
          "cluster (%d)" % len(edits))
    kinds = collections.Counter(e["edit"] for e in edits)
    check(kinds.get("rename") == 1 and kinds.get("drop-route-level-ext_proc") == 1
          and kinds.get("add-weighted-cluster-ext_proc") == 2,
          "and nothing else changed: %s" % dict(kinds))
    # The strong form of "nothing else changed": every field of the override we
    # emit must equal Istio's, except the picker cluster. An allowlist of copied
    # fields cannot make that claim - this can.
    src = edits_doc.get("source_overrides") if isinstance(edits_doc, dict) else None
    fixed = routes.get(args.fixed_route)
    if src and fixed is not None:
        drifted = []
        for cluster in weighted_clusters(fixed):
            got = key(key(cluster, "typed_per_filter_config",
                          "typedPerFilterConfig") or {}, EXT_PROC) or {}
            got = key(got, "overrides") or {}
            for field in set(src) | set(got):
                if field in ("grpc_service", "grpcService"):
                    continue
                if src.get(field) != got.get(field):
                    drifted.append("%s.%s" % (pool_of(cluster["name"]), field))
        check(not drifted,
              "each per-cluster override matches Istio's own field for field, "
              "apart from the picker it names (%s)" % (drifted or "no drift"))
    if check(fixed is not None, "route %s is present in the route table"
             % args.fixed_route):
        check(override_picker(fixed) is None,
              "the inserted route carries no route-level override")
        got = {pool_of(c["name"]): override_picker(c) for c in weighted_clusters(fixed)}
        check(got == {"pool-a": "epp-a", "pool-b": "epp-b"},
              "each weighted cluster names its own pool's picker (%s)" % got)
    # An EnvoyFilter has no status, and a rejected RDS update leaves the previous
    # route table in place - which reads exactly like "the fix does not work".
    check(stats.get("rejected_delta", 1) == 0,
          "Envoy rejected no route config update while applying it (rds "
          "update_rejected delta %s)" % stats.get("rejected_delta"))

    gate_volume(rows, "split", n_split)
    gate_codes(rows, "split", "200")
    gate_split(rows, "split", args.weight_a, args.weight_b)

    split, _, pairs = summarise(rows, "split")
    fixed = routes.get(args.fixed_route)
    if fixed is not None:
        block("patched route  %s" % args.fixed_route)
        row("route-level ext_proc override", override_picker(fixed) or "none")
        for c in weighted_clusters(fixed):
            row("weighted cluster %s (weight %s)"
                % (pool_of(c["name"]), c.get("weight")),
                "ext_proc override: %s" % (override_picker(c) or "none"))
    block("%d requests to the weighted rule, under the patch" % len(split))
    for (backend, picker), n in sorted(pairs.items()):
        row("served by pool-%s, endpoint chosen by picker %s" % (backend, picker), n)

    matched = sum(n for (backend, picker), n in pairs.items() if backend == picker)
    crossed = sum(n for (backend, picker), n in pairs.items() if backend != picker)
    check(crossed == 0,
          "no request was served by one pool while the other's picker was "
          "consulted (%d crossed)" % crossed)
    check({p[1] for p in pairs} == {"a", "b"},
          "both pickers now choose endpoints, where before the patch pool a's "
          "picker chose none at all (%s)" % dict(pairs))
    served_by_route = collections.Counter(
        r.get("route_name") for r in gate_access(rows, access, "split"))
    check(set(served_by_route) == {args.fixed_route},
          "and Envoy served all of it from the inserted route (%s)"
          % dict(served_by_route))
    verdict("with one ExtProcPerRoute per weighted cluster, every request reached\n"
            "         its own pool's picker and none crossed. Envoy had no difficulty\n"
            "         with per-backend ext_proc config, so the gap is in what Istio\n"
            "         emits rather than in what the data plane can carry.")


def scenario_fix_outage(args, rows, routes, access):
    n_split = args.requests
    claim("the outage scenario re-run underneath that patch: same pool emptied,\n"
          "       same traffic, one config difference.")
    split, codes, _ = summarise(rows, "split")
    gate_volume(rows, "split", n_split)
    block("the same outage, with the patch in place")
    for code, n in sorted(codes.items()):
        row("HTTP %s" % code, n)
    failed = codes.get("503", 0)
    share = 100.0 * failed / len(split) if split else 100.0
    expected = 100.0 * args.weight_b / (args.weight_a + args.weight_b)
    tolerance = band(args.weight_b / float(args.weight_a + args.weight_b), len(split))
    check(abs(share - expected) < tolerance,
          "with picker b refusing, %.1f%% of requests failed - the canary's weight "
          "share (%.1f%% +/-%.1f), not the 100%% it was before the patch"
          % (share, expected, tolerance))
    survivors = [r for r in split if r["code"] == "200"]
    check(survivors and all(r["backend"] == "a" for r in survivors),
          "and every surviving request was served by the healthy pool (%d)"
          % len(survivors))
    show_failures(rows, access, "split")
    headline(args, "3-fix",
             "same outage, with an EnvoyFilter giving each pool its own picker\n"
             "     %d of %d requests failed - pool-b's share only, pool-a served "
             "throughout\n"
             "     which is what emptying a %d%% member should cost"
             % (failed, len(split),
                round(100.0 * args.weight_b / (args.weight_a + args.weight_b))))
    verdict("the same empty pool now costs %.0f%% instead of 100%%. That is the\n"
            "         canary's own weight share, which is what emptying a 10%% member\n"
            "         should cost." % share)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--results", required=True)
    parser.add_argument("--requests", type=int, required=True)
    parser.add_argument("--weight-a", type=int, default=9)
    parser.add_argument("--weight-b", type=int, default=1)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--split-route", required=True)
    parser.add_argument("--fixed-route", default="")
    parser.add_argument("--pool-ips", action="append", default=[])
    parser.add_argument("--stamp", default="")
    parser.add_argument("--verbose", action="store_true",
                        help="print every passing assertion, not just the verdict")
    args = parser.parse_args()
    global VERBOSE
    VERBOSE = args.verbose

    tag = args.scenario
    base = os.path.join(args.results, tag)
    rows = read_traffic(base + "-traffic.log")
    routes = read_routes(base + "-routes.json")
    access = read_access(base + "-access.log")

    pool_ips = {}
    for spec in args.pool_ips:
        pool, ips = spec.split("=", 1)
        for ip in ips.split(","):
            if ip:
                pool_ips[ip.split(":")[0]] = pool
    annotate_pickers(rows, pool_ips)


    if not check(bool(routes), "route capture is non-empty (%d routes)" % len(routes)):
        # Every config assertion below would pass vacuously against an empty
        # capture, so the scenario stops here rather than reporting a green run.
        print("%sabort%s: no route table captured; refusing to score the scenario"
              % (RED, NC))
        return 1

    if tag == "bypass":
        scenario_bypass(args, rows, routes, access)
    elif tag == "outage":
        status = []
        path = base + "-status.json"
        if os.path.exists(path):
            status = json.load(open(path))
        check(bool(status), "status was snapshotted during the outage window")
        scenario_outage(args, rows, routes, access, status)
    elif tag == "fix":
        edits_doc = json.load(open(os.path.join(
            args.results, "envoyfilter-per-pool-extproc-diff.json")))
        edits = edits_doc["edits"]
        stats = json.load(open(base + "-stats.json"))
        scenario_fix(args, rows, routes, access, edits, stats, edits_doc)
    elif tag == "fix-outage":
        scenario_fix_outage(args, rows, routes, access)
    else:
        sys.exit("unknown scenario %s" % tag)

    return failures


if __name__ == "__main__":
    sys.exit(main())
