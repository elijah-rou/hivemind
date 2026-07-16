package main

import (
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/a-h/templ"
	"github.com/elijahrou/hivemind/v2/api/templates"
)

func registerDashboardRoutes(mux *http.ServeMux, client *HivemindClient) {
	mux.HandleFunc("GET /v1/cluster-state", func(w http.ResponseWriter, r *http.Request) {
		cs, err := client.SendClusterStateRequest()
		if err != nil {
			writeErr(w, http.StatusBadGateway, err.Error())
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(cs); err != nil {
			return
		}
	})

	mux.HandleFunc("GET /dashboard", func(w http.ResponseWriter, r *http.Request) {
		templ.Handler(templates.Dashboard()).ServeHTTP(w, r)
	})

	mux.HandleFunc("GET /dashboard/cluster", func(w http.ResponseWriter, r *http.Request) {
		cs, err := client.SendClusterStateRequest()
		if err != nil {
			w.WriteHeader(502)
			templ.Handler(templates.ErrorSection(fmt.Sprintf("cluster query failed: %v", err))).ServeHTTP(w, r)
			return
		}
		view := &templates.ClusterStateView{
			ViewNumber: cs.ViewNumber,
			CommitMin:  cs.CommitMin,
			OpNumber:   cs.OpNumber,
			StatusName: templates.StatusName(cs.Status),
			IsLeader:   cs.IsLeader,
		}
		templ.Handler(templates.ClusterSection(view)).ServeHTTP(w, r)
	})

	mux.HandleFunc("GET /dashboard/nodes", func(w http.ResponseWriter, r *http.Request) {
		cs, err := client.SendClusterStateRequest()
		if err != nil {
			w.WriteHeader(502)
			templ.Handler(templates.ErrorSection(err.Error())).ServeHTTP(w, r)
			return
		}
		views := make([]templates.NodeView, len(cs.Nodes))
		for i, n := range cs.Nodes {
			views[i] = templates.NodeView{
				Name:        n.Name,
				StatusName:  templates.NodeStatusName(n.Status),
				StatusClass: templates.NodeStatusClass(n.Status),
				GpuSummary:  templates.GpuSummaryWithFree(n.GpuType, n.GpuCount, n.AllocatableGpu),
				CPUDisplay:  fmt.Sprintf("%dm", n.CPU),
				MemDisplay:  fmt.Sprintf("%dMi", n.Memory),
				Region:      n.Region,
			}
		}
		templ.Handler(templates.NodesSection(views)).ServeHTTP(w, r)
	})

	mux.HandleFunc("GET /dashboard/deployments", func(w http.ResponseWriter, r *http.Request) {
		cs, err := client.SendClusterStateRequest()
		if err != nil {
			w.WriteHeader(502)
			templ.Handler(templates.ErrorSection(err.Error())).ServeHTTP(w, r)
			return
		}
		views := make([]templates.DeploymentView, len(cs.Deployments))
		for i, d := range cs.Deployments {
			replicaClass := "ok"
			if d.ReadyReplicas < d.Replicas {
				replicaClass = "warn"
			}
			if d.ReadyReplicas == 0 && d.Replicas > 0 {
				replicaClass = "err"
			}
			views[i] = templates.DeploymentView{
				Name:          d.Name,
				Image:         d.Image,
				Replicas:      d.Replicas,
				ReadyReplicas: d.ReadyReplicas,
				ReplicaClass:  replicaClass,
				Version:       d.Version,
				GpuSummary:    templates.GpuSummary(d.GpuType, d.GpuCount),
				Paused:        d.Paused,
			}
		}
		templ.Handler(templates.DeploymentsSection(views)).ServeHTTP(w, r)
	})

	mux.HandleFunc("GET /dashboard/workers", func(w http.ResponseWriter, r *http.Request) {
		cs, err := client.SendClusterStateRequest()
		if err != nil {
			w.WriteHeader(502)
			templ.Handler(templates.ErrorSection(err.Error())).ServeHTTP(w, r)
			return
		}
		views := make([]templates.WorkerView, len(cs.Agents))
		for i, a := range cs.Agents {
			hbAge := "n/a"
			hbClass := "muted"
			if a.LastHeartbeatTick > 0 {
				// Tick is in ms; show relative
				hbAge = fmt.Sprintf("%dms ago", a.LastHeartbeatTick)
				if a.Connected {
					hbClass = "ok"
				} else {
					hbClass = "err"
				}
			}
			views[i] = templates.WorkerView{
				Hostname:       a.Hostname,
				NodeID:         a.NodeID,
				Connected:      a.Connected,
				GpuSummary:     templates.GpuSummary(a.GpuType, a.GpuCount),
				HeartbeatAge:   hbAge,
				HeartbeatClass: hbClass,
			}
		}
		templ.Handler(templates.WorkersSection(views)).ServeHTTP(w, r)
	})

	mux.HandleFunc("GET /dashboard/queue", func(w http.ResponseWriter, r *http.Request) {
		cs, err := client.SendClusterStateRequest()
		if err != nil {
			w.WriteHeader(502)
			templ.Handler(templates.ErrorSection(err.Error())).ServeHTTP(w, r)
			return
		}
		view := &templates.QueueView{
			Depth:         cs.QueueDepth,
			InFlight:      cs.InFlight,
			EnqueueTotal:  cs.EnqueueTotal,
			DispatchTotal: cs.DispatchTotal,
			ResolveTotal:  cs.ResolveTotal,
		}
		templ.Handler(templates.QueueSection(view)).ServeHTTP(w, r)
	})

	mux.HandleFunc("GET /dashboard/pods", func(w http.ResponseWriter, r *http.Request) {
		cs, err := client.SendClusterStateRequest()
		if err != nil {
			w.WriteHeader(502)
			templ.Handler(templates.ErrorSection(err.Error())).ServeHTTP(w, r)
			return
		}
		views := make([]templates.PodView, len(cs.Pods))
		for i, p := range cs.Pods {
			views[i] = templates.PodView{
				ID:           p.ID,
				DeploymentID: p.DeploymentID,
				NodeID:       p.NodeID,
				PhaseName:    templates.PodPhaseName(p.Phase),
				PhaseClass:   templates.PodPhaseClass(p.Phase),
			}
		}
		templ.Handler(templates.PodsSection(views)).ServeHTTP(w, r)
	})
}
