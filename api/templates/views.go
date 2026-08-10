package templates

import "fmt"

var statusNames = []string{"normal", "view_change", "recovering"}
var gpuTypeNames = []string{"none", "a100_40", "a100_80", "h100_sxm", "h100_pcie", "h200", "l40s", "a10g", "t4"}
var nodeStatusNames = []string{"provisioning", "starting", "ready", "unhealthy", "draining", "terminating", "terminated"}
var podPhaseNames = []string{"pending", "scheduled", "running", "succeeded", "failed", "terminating"}

type ClusterStateView struct {
	ViewNumber uint64
	CommitMin  uint64
	OpNumber   uint64
	StatusName string
	IsLeader   bool
}

type NodeView struct {
	Name        string
	StatusName  string
	StatusClass string
	GpuSummary  string
	CPUDisplay  string
	MemDisplay  string
	Region      string
}

type DeploymentView struct {
	Name          string
	Image         string
	Replicas      uint32
	ReadyReplicas uint32
	ReplicaClass  string
	Version       uint32
	GpuSummary    string
	Paused        bool
}

type WorkerView struct {
	Hostname       string
	NodeID         uint64
	Connected      bool
	GpuSummary     string
	HeartbeatAge   string
	HeartbeatClass string
}

type QueueView struct {
	Depth         uint64
	InFlight      uint64
	EnqueueTotal  uint64
	DispatchTotal uint64
	ResolveTotal  uint64
}

type PodView struct {
	ID           uint64
	DeploymentID uint64
	NodeID       uint64
	PhaseName    string
	PhaseClass   string
}

func StatusName(status byte) string {
	if int(status) < len(statusNames) {
		return statusNames[status]
	}
	return "unknown"
}

func GpuTypeName(t byte) string {
	if int(t) < len(gpuTypeNames) {
		return gpuTypeNames[t]
	}
	return "unknown"
}

func NodeStatusName(s byte) string {
	if int(s) < len(nodeStatusNames) {
		return nodeStatusNames[s]
	}
	return "unknown"
}

func NodeStatusClass(s byte) string {
	switch s {
	case 2: // ready
		return "ok"
	case 3: // unhealthy
		return "err"
	case 4, 5: // draining, terminating
		return "warn"
	default:
		return "muted"
	}
}

func PodPhaseName(p byte) string {
	if int(p) < len(podPhaseNames) {
		return podPhaseNames[p]
	}
	return "unknown"
}

func PodPhaseClass(p byte) string {
	switch p {
	case 2: // running
		return "ok"
	case 4: // failed
		return "err"
	case 0, 1: // pending, scheduled
		return "warn"
	default:
		return "muted"
	}
}

func GpuSummary(gpuType byte, gpuCount byte) string {
	if gpuCount == 0 {
		return "-"
	}
	return fmt.Sprintf("%s x%d", GpuTypeName(gpuType), gpuCount)
}

func GpuSummaryWithFree(gpuType byte, gpuCount byte, free byte) string {
	if gpuCount == 0 {
		return "-"
	}
	return fmt.Sprintf("%s x%d (%d free)", GpuTypeName(gpuType), gpuCount, free)
}
