package androidstartup

type LeaseDisposition uint32

const (
	LeaseHeld LeaseDisposition = iota
	LeaseReleased
	LeaseUnknown
)

func (l *OnceLease) Disposition() LeaseDisposition {
	if l == nil {
		return LeaseReleased
	}
	return LeaseDisposition(l.disposition.Load())
}
