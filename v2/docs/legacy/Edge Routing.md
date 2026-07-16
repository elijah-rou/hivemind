# Edge routing

> **LEGACY — not Hivemind `core/` in-repo:** This note is **historic / platform-design context** for **multi-origin / edge routing** (Thalamus, Cloudflare Workers, Axon load shedding). It does **not** specify the **Hivemind `core/` Zig control plane** or **`hivemind-agent`** in this repository — see **`docs/STATUS.md`** and **`docs/FINDINGS_AND_ISSUES.md`**. Indexed under **`docs/legacy/README.md`**.

Created time: November 16, 2025 6:41 AM

# Summary

As the platform becomes multi-cloud and multi-region, we need more sophisticated routing logic to better utilise our compute set. There are many reasons an origin might be preferred for any given request including but not limited to:

- Geo-location
- Current origin concurrency/capacity
- Origin hardware availability (request requires h100s)
- Data sovereignty for compliance
- Cost

In a perfect world, customers will not have to consider any of this complexity. In the spirit of serverless computation, the platform prefers to handle this complexity on behalf of its users, so we prefer solutions that support a ‘build once, run anywhere’ experience for customers.

Additionally, it would be preferable if Hivemind cortex clusters which already encode a lot of complicated routing and scaling logic should be minimally concerned with routing logic. The platform works best when there is a separation of concerns between intra- and inter-cluster routing. Cortex is concerned only with intra-cluster routing, while our external router (Thalamus) should be concerned only with inter-cluster routing.

Some terminology that this document uses:

- **Origin:** an origin is a single cluster, usually denoted by a domain name. This is differentiated from an endpoint, since an origin may refer to multiple endpoints which are entrypoints into the same cluster.
- **Cluster:** interchangeable with **origin**, but specifically refers to the suite of services running in a single origin.
- **Worker**: a [cloudflare worker](https://workers.cloudflare.com/) which is used as a decision maker for a routing decision.
- **State**: dynamic data used as input to a routing decision.

# Goals

This document describes Thalamus, our inter-cluster router that is able to route requests to a configured set of origins.

- Per-request routing to various origins is supported
- Routing occurs on the edge - minimal in-cluster changes should be needed
- Almost any routing strategy should be supported
    - At minimum, stateless routing decisions are required
    - Stateful routing decisions are preferred as this gives us more flexibility
- Routing should not add considerable latency to requests, ~30ms on all requests is acceptable, but ~200ms is not
    - This latency should be calculated on aggregate, implying it is still okay to have the odd slow request which may cache routing state for fast execution of follow up requests

### Non-Goals

- Routing strategies themselves will not be discussed in this document, only the facility to encode them
- Specific state data as required by the above routing decisions

# Proposed Solution

A routing engine should be built into Cloudflare Workers. This engine is deployed separately from our origin clusters, but should allow for origins to push signals to the engine which will influence its behaviour. These signals are expected to contain stateful information about the cluster and are used as inputs to the routing engine. Some example inputs may include (although we do not define these in this document):

- Capabilities such as available capacity
- Constraints such as supported GPU types
- Cluster metadata such as region, health, costs

The engine will then execute our routing algorithm based on this information.

<aside>
⚠️

A note, CF workers are natively Javascript. This is because they use a technology called V8 Isolates which guarantees sandboxing and isolation for your runtime. V8 isolates do not (apparently) play well with Golang’s threading model, which means that workers are likely to never support Go. They do, however, support WASM - which go is able to compile to. 

One consideration here is whether to write in Go and compile to WASM or write in native Javascript. There are disadvantages to using WASM - apparently WASM binaries are a little more exposed to cold startup problems, and I’m not at all familiar with any WASM constraints for Go - WASM runs single-threaded so there will naturally be some runtime idiosyncracies. My suggestion is to go with Javascript (Typescript).

```go
type AppManifest struct {
  AppID string
  Revision int
  Requirements struct {
    GPU []string
    Regions []string
  }
}

type Origin struct {
  Name string // aws-us-east-1, crusoe-us-east-1, etc
  Region string
  Domain string
  Capabilities struct {
    AvailableGPUs []string
  }
}
```

</aside>

### Routing engine

Define a `strategy` interface which accepts both a current request and a list of potential origin servers to send the request to, and returns a `RoutingDecision`. Implementations of the strategy encode their own ‘load balancing’ logic, such as weighted random or least concurrent connections.

```go
type RoutingStrategy interface {
  Name() string // For metrics
  Evaluate(ctx RoutingContext) RoutingDecision
}

type RoutingContext struct {
  request http.Request // From the client
  allowedOrigins []Origin
}

type RoutingDecision struct {
  origin Origin
  score float32 // 0.0 -> 1 used as a tiebreaker between RoutingDecisions
}

type Origin struct {
  name string // aws-us-east-1, crusoe-us-east-1, etc
  region string
  domain string
  concurrency int
}

// Eg LeastConcurrentStrat chooses the origin with the fewest currently
// open requests

type LeastConcurrentStrat struct {}

func (s LeastConcurrentStrat) Name() string { return "least-concurrent" }

func (s LeastConcurrentStrat) Evaluate(ctx RoutingContext) RoutingDecision {
  leastConns := math.MaxInt64
  var decision Origin
  for _, orig := range ctx.allowedOrigins {
    if leastConns > orig.concurrency {
      leastConns = orig.concurrency
      decision = orig
    }
  }
  return RoutingDecision{orig, /*some_weight*/}
}
```

We will need to filter out certain origins for apps based on their internal configuration. For example, an app may be configured to only run in EU for data residency reasons, or will need to run on certain GPU classes. For this reason, we will also need to store an App Manifest which describes the requirements of any given app, as well as origin capabilities so that origins can be filtered out at request time:

Now, we can write a simple filter to ensure that Origins that cannot process the request are omitted as early on in the process as possible:

```go
func Filter(app AppManifest, origins []Origin) []Origin {
  var allowedOrigins []Origin
  for _, orig := range origins {
    if satisfiesRequirements(app, orig) {
      allowedOrigins = append(allowedOrigins, orig)
    }
  }
  return allowedOrigins
}

func satisfiesRequirements(app AppManifest, orig Origin) bool {
  if !orig.Capabilities.AvailableGPU.ContainsAny(app.Requirements.GPU) {
    return false
  }
  if !orig.Region.In(app.Requirements.Regions) {
    return false
  }
  return true
}
```

Finally, the worker has a simple enough job as the orchestrator of all these functions:

```go
func Handle(req http.Request) {
  appMani := getAppManifest(req.AppID)
  // ALL_ORIGINS is sourced from some on-edge storage, like a Durable Object
  allowedOrigins := Filter(appMani, ALL_ORIGINS)
  
  var validOrigins []RoutingDecision
  // ALL_STRATEGIES will likely be a list hard-coded onto the worker.
  // Strategy updates will require a worker deployment but are unlikely to be frequent.
  // TODO(wes): App Manifest should maybe be used to filter strategies as well!
  for _, strat := range ALL_STRATEGIES {
    decision := strat.Evaluate(req, allowedOrigins)
    if decision != nil {
      validOrigins = append(validOrigins, decision)
    }
  }
  
  // Break ties
  sort.Slice(
    validOrigins, 
    func(i, j int) bool { 
      return validOrigins[i].Score < validOrigins[j].Score 
    }
  )
  
  http.Client{}.Do(req, validOrigins[0].Origin.Domain)
}
```

### Origin signal propagation

For all of this to work, we need to be able to send app manifests and origin state/capabilities to the Worker. For this, we need a means to store state in a way that is (with extremely low latency) available to the routing worker. For this, we could use one of Cloudflare’s Edge storage technologies. The simplest is probably the [CF K/V store](https://developers.cloudflare.com/kv/), and the most flexible is probably [CF Durable Objects](https://developers.cloudflare.com/durable-objects/). The decision of which of these to use is left as a task for the reader, the important part for this doc is that we are able to store some state and update that state out-of-band (not on the hot path of user requests).

We will thus require an entrypoint for external services (our origin clusters) into the chosen storage device, which is typically done via an ‘admin’ cloudflare worker. This admin worker serves an API and acts as a proxy for our origin servers into the storage device. This is independent of the routing worker which only reads data from the storage.

Above, we defined two flavours of state that will likely be necessary for making routing decisions, however exactly what state is required is a consequence of the routing logic (we may need region, hardware capabilites, user information, anything - this document does not make any decisions about what data will be useful, only provides a solution for how to get that data into the edge storage).

One recommendation is that the App Manifest should be pushed to the edge as part of the Build/Deploy process. This is the only time App State will change, so it should be relatively safe time to do it, the only requirement being that the manifest arrives on the edge before the first request to that app does, so that the manifest is respected. The routing worker *could* fall back to requesting a manifest from an origin, but this becomes quite complicated, so for now it’s best to simply rely on this push-during-build method.

The admin worker can be a very simple http layer on top of the storage device:

```go
func Handle(req http.Request) {
	authed := Authenticate(req) // Important, don't let anybody update state
	if !authed {
	  return 401 Unauthorized
	}
	err := Store(req) // Write to storage
	if err != nil {
	  return 500 Server Error
	}
	return 201 Created
}

// This admin worker can also define some other endpoints for:
// - Manually editing state
// - Inspecting the storage device for debugging purposes

// It must also keep an audit log of all state changes entered into the system
```

### Edge ingestion API naming (not Knative queue-proxy)

This doc describes **edge↔origin** plumbing (pushing state, admin APIs, public customer ingress). A common Knative-style pattern is a sidecar **queue-proxy** alongside user containers that hosts **operator-only** paths like `/queue-metrics`, `/queue-health`, `/var/log/*`, and sometimes ambiguous `/metrics` or `/debug` that **must not be exposed** on the public customer URL.

For **the public API surface**, the goal is **intentional naming** so we never end up with “customer request accidentally hits queue-proxy bucket” ambiguity:

- Prefer **resource-shaped** routes for anything customer-facing or long-lived.
- Prefer an explicit **internal / observability** prefix for anything that is not the product API (debug, introspection, operator metrics).

Concretely for behavior analogous to Knative’s queue-proxy:

- **Customer traffic** should never need `/forward/*`, `/wait`, `/drain`, etc.
- **Prometheus-style metrics** are fine; use **`/metrics`** (or `/:cluster/metrics` where needed) and keep scrape off the public hostname if required (network policy, separate listener, auth).
- Avoid vague top-level names like **`/debug`** or **`/state`** for “everything else”. Split into explicit endpoints (health vs introspection vs backpressure) under something like **`/v1/internal/...`** (authenticated, not routed like user workloads).

The **in-repo Hivemind `core/` control plane** (replicas + `hivemind-agent`) is separate from this document: see **`docs/STATUS.md`** and **`docs/FINDINGS_AND_ISSUES.md`** (*In-cluster HTTP naming*) for what surfaces exist today and naming choices there.

---

It may be best for the worker to support websockets so that origin servers may stream live data about their internal state into storage without back-and-forth http overhead. A consideration is what to do about dropped updates from the origin. The implementation should be careful to apply idempotency to state updates so that origins can safely re-send requests until a successful response is received.

In our origin clusters, we will need to build a client that interacts with this administrative worker, so that origins can propagate their state to the edge router. Since `axon` is our intra-cluster proxy layer, it is a good place to record all of the data that we might need to send to the admin worker. 

One complication here is that we would like `axon` to be horizontally scalable, which may imply that multiple clients may be running within the same cluster, all sending state data to the admin worker simultaneously. We will therefore need to be sure that either:

- All instances within the same cluster synchronise over some shared storage (eg redis), and then only one cluster leader will be responsible for reporting the cluster state to the admin worker.
- The admin worker provides an atomic api (eg `Increment` instead of `Set`), allowing multiple clients from the same cluster to report their own information independently of one another.

Writing the worker in a way that exposes an atomic API may present some difficulties. A simpler solution would be to implement leader election with `etcd`, and each independent worker simply reports its own state data into some kind of shared storage, which the leader will use to construct a single update request to the admin worker.

### Axon load shedding

As a final layer of protection, we are able to proxy requests from one origin to another. Pushing state from origins to the edge is necessarily reactive and there will be scenarios where an origin is selected that is unable process a request. To combat this, we can make use of load shedding in axon.

When an origin is selected on the edge, the request should be sent to that origin with `X-Thalamus-Metadata` set in the headers. Here, we will pass a json object containing all the possible origins for a given request.

Axon may then apply load shedding rules (for example, max concurrent requests) and in the case where the current origin is unable to process the request, select aother origin from `X-Thalamus-Metadata` to shed the load to. It should also remove itself from the list of eligible origins to avoid circular routing. If no more eligible origins are available or some maximum number of proxy ‘hops’ is reached and the current origin is in a load shedding state, a 502 should be returned.