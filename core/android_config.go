package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/netip"

	"core/state"
	"github.com/metacubex/mihomo/config"
)

const (
	androidConfigEpoch                int64 = 1
	androidConfigPayloadLimit               = 16 * 1024 * 1024
	androidConfigKindSetup                  = 1
	androidConfigKindUpdate                 = 2
	androidConfigKindState                  = 3
	androidConfigKindInitialComposite       = 4
)

const (
	androidConfigOutcomeApplied  = "applied"
	androidConfigOutcomeStaged   = "staged"
	androidConfigOutcomeRejected = "rejected"
	androidConfigOutcomeUnknown  = "unknown"
	androidConfigPhaseNotEntered = "notEntered"
	androidConfigPhaseEntered    = "entered"
	androidConfigPhaseApplied    = "applied"
	androidConfigPhaseStaged     = "staged"
)

const (
	androidConfigErrorNone                = ""
	androidConfigErrorBlocked             = "coordinatorBlocked"
	androidConfigErrorConfigApplyFailed   = "configApplyFailed"
	androidConfigErrorConfigPrepareFailed = "configPrepareFailed"
	androidConfigErrorCoreNotInitialized  = "coreNotInitialized"
	androidConfigErrorInitialStateMissing = "initialStateMissing"
	androidConfigErrorInitialOnly         = "initialCompositeAfterConfig"
	androidConfigErrorInvalidKind         = "invalidKind"
	androidConfigErrorInvalidPayload      = "invalidPayload"
	androidConfigErrorLegacyConfigPresent = "legacyConfigPresent"
	androidConfigErrorOptionsFailed       = "optionsSnapshotFailed"
	androidConfigErrorPayloadTooLarge     = "payloadTooLarge"
	androidConfigErrorReceiptEncoding     = "receiptEncodingFailed"
	androidConfigErrorRevisionOverflow    = "revisionOverflow"
	androidConfigErrorStaleEpoch          = "staleEpoch"
	androidConfigErrorStaleRevision       = "staleRevision"
	androidConfigErrorStateApplyFailed    = "stateApplyFailed"
	androidConfigErrorUpdateApplyFailed   = "updateApplyFailed"
	androidConfigErrorUpdateBeforeConfig  = "updateBeforeConfig"
	androidConfigErrorUnconfigured        = "unconfigured"
)

// androidOwnedConfigResult 是 Go owner 与 JNI 共享的固定十字段回执。
type androidOwnedConfigResult struct {
	Outcome           string                   `json:"outcome"`
	Phase             string                   `json:"phase"`
	Epoch             int64                    `json:"epoch"`
	ConfigRevision    int64                    `json:"configRevision"`
	AttemptedRevision int64                    `json:"attemptedRevision"`
	StateGeneration   int64                    `json:"stateGeneration"`
	Configured        bool                     `json:"configured"`
	Blocked           bool                     `json:"blocked"`
	Options           *state.AndroidVpnOptions `json:"options"`
	ErrorCode         string                   `json:"errorCode"`
}

type androidConfigDriver interface {
	initializedLocked() bool
	configPresentLocked() bool
	stateSnapshotLocked() state.State
	prepareSetupLocked(*SetupParams) (*preparedSetupConfig, error)
	commitSetupLocked(*preparedSetupConfig, state.State) error
	updateLocked(*UpdateParams) error
	replaceStateLocked(state.State) error
	optionsLocked(state.State) (*state.AndroidVpnOptions, error)
}

type productionAndroidConfigDriver struct{}

func (productionAndroidConfigDriver) initializedLocked() bool          { return isInit }
func (productionAndroidConfigDriver) configPresentLocked() bool        { return currentConfig != nil }
func (productionAndroidConfigDriver) stateSnapshotLocked() state.State { return state.Snapshot() }
func (productionAndroidConfigDriver) prepareSetupLocked(params *SetupParams) (*preparedSetupConfig, error) {
	return prepareSetupConfigLocked(params)
}
func (productionAndroidConfigDriver) commitSetupLocked(prepared *preparedSetupConfig, desired state.State) error {
	commitSetupConfigLocked(prepared)
	state.Replace(desired)
	return nil
}
func (productionAndroidConfigDriver) updateLocked(params *UpdateParams) error {
	updateConfigLocked(params)
	return nil
}
func (productionAndroidConfigDriver) replaceStateLocked(value state.State) error {
	state.Replace(value)
	return nil
}
func (productionAndroidConfigDriver) optionsLocked(value state.State) (*state.AndroidVpnOptions, error) {
	if currentConfig == nil {
		return nil, errors.New("配置尚未建立")
	}
	return androidVpnOptionsSnapshotLocked(currentConfig, value), nil
}

type androidConfigCoordinator struct {
	tunReservation  *androidTunReservation
	driver          androidConfigDriver
	epoch           int64
	lastApplied     int64
	lastAttempted   int64
	stateGeneration int64
	configured      bool
	blocked         bool
	hasDesiredState bool
	desiredState    state.State
	options         *state.AndroidVpnOptions
	lastErrorCode   string
}

var productionAndroidConfigCoordinator = androidConfigCoordinator{
	driver: productionAndroidConfigDriver{},
	epoch:  androidConfigEpoch,
}

// 该构造器只供测试fixture替换driver；生产入口固定使用上面的真实driver。
func newAndroidConfigCoordinatorForTest(driver androidConfigDriver) *androidConfigCoordinator {
	return &androidConfigCoordinator{driver: driver, epoch: androidConfigEpoch}
}

type decodedAndroidConfigMutation struct {
	kind       int
	setup      *SetupParams
	update     *UpdateParams
	stateBytes []byte
}

type initialCompositePayload struct {
	Setup json.RawMessage `json:"setup"`
	State json.RawMessage `json:"state"`
}

func decodeSingleJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return errors.New("JSON包含尾随内容")
	}
	return nil
}

func decodeAndroidConfigMutation(kind int, payload string) (*decodedAndroidConfigMutation, string) {
	data := []byte(payload)
	switch kind {
	case androidConfigKindSetup:
		var params SetupParams
		if err := decodeSingleJSON(data, &params); err != nil {
			return nil, androidConfigErrorInvalidPayload
		}
		copied, err := cloneSetupParams(&params)
		if err != nil {
			return nil, androidConfigErrorInvalidPayload
		}
		return &decodedAndroidConfigMutation{kind: kind, setup: copied}, androidConfigErrorNone
	case androidConfigKindUpdate:
		var params UpdateParams
		if err := decodeSingleJSON(data, &params); err != nil || !validAndroidUpdateParams(&params) {
			return nil, androidConfigErrorInvalidPayload
		}
		return &decodedAndroidConfigMutation{kind: kind, update: &params}, androidConfigErrorNone
	case androidConfigKindState:
		var value map[string]json.RawMessage
		if err := decodeSingleJSON(data, &value); err != nil || value == nil {
			return nil, androidConfigErrorInvalidPayload
		}
		return &decodedAndroidConfigMutation{kind: kind, stateBytes: append([]byte(nil), data...)}, androidConfigErrorNone
	case androidConfigKindInitialComposite:
		var composite initialCompositePayload
		if err := decodeSingleJSON(data, &composite); err != nil || len(composite.Setup) == 0 || len(composite.State) == 0 {
			return nil, androidConfigErrorInvalidPayload
		}
		var params SetupParams
		if err := decodeSingleJSON(composite.Setup, &params); err != nil {
			return nil, androidConfigErrorInvalidPayload
		}
		copied, err := cloneSetupParams(&params)
		if err != nil {
			return nil, androidConfigErrorInvalidPayload
		}
		var stateValue map[string]json.RawMessage
		if err := decodeSingleJSON(composite.State, &stateValue); err != nil || stateValue == nil {
			return nil, androidConfigErrorInvalidPayload
		}
		return &decodedAndroidConfigMutation{
			kind:       kind,
			setup:      copied,
			stateBytes: append([]byte(nil), composite.State...),
		}, androidConfigErrorNone
	default:
		return nil, androidConfigErrorInvalidKind
	}
}

func validAndroidUpdateParams(params *UpdateParams) bool {
	if params == nil || params.Tun == nil {
		return params != nil
	}
	tun := params.Tun
	return tun.AutoRoute != nil && tun.Device != nil && tun.RouteAddress != nil &&
		tun.DNSHijack != nil && tun.Stack != nil && tun.DisableICMPForwarding != nil
}

func rejectedAndroidOwnedConfigResult(errorCode string) androidOwnedConfigResult {
	return androidOwnedConfigResult{
		Outcome:   androidConfigOutcomeRejected,
		Phase:     androidConfigPhaseNotEntered,
		Epoch:     androidConfigEpoch,
		ErrorCode: errorCode,
	}
}

func (c *androidConfigCoordinator) snapshotLocked() androidOwnedConfigResult {
	result := androidOwnedConfigResult{
		Epoch:             c.epoch,
		ConfigRevision:    c.lastApplied,
		AttemptedRevision: c.lastAttempted,
		StateGeneration:   c.stateGeneration,
		Configured:        c.configured,
		Blocked:           c.blocked,
		Options:           cloneAndroidVpnOptions(c.options),
		ErrorCode:         c.lastErrorCode,
	}
	switch {
	case c.blocked:
		result.Outcome = androidConfigOutcomeUnknown
		result.Phase = androidConfigPhaseEntered
		result.Options = nil
	case c.configured:
		result.Outcome = androidConfigOutcomeApplied
		result.Phase = androidConfigPhaseApplied
	case c.hasDesiredState:
		result.Outcome = androidConfigOutcomeStaged
		result.Phase = androidConfigPhaseStaged
	default:
		result.Outcome = androidConfigOutcomeRejected
		result.Phase = androidConfigPhaseNotEntered
		result.ErrorCode = androidConfigErrorUnconfigured
	}
	return result
}

func (c *androidConfigCoordinator) rejectedLocked(errorCode string) androidOwnedConfigResult {
	result := c.snapshotLocked()
	result.Outcome = androidConfigOutcomeRejected
	result.Phase = androidConfigPhaseNotEntered
	result.Options = nil
	result.ErrorCode = errorCode
	return result
}

func (c *androidConfigCoordinator) enteredFailureLocked(attempt int64, errorCode string) androidOwnedConfigResult {
	c.blocked = true
	c.lastAttempted = attempt
	c.lastErrorCode = errorCode
	result := c.snapshotLocked()
	result.Outcome = androidConfigOutcomeUnknown
	result.Phase = androidConfigPhaseEntered
	result.Options = nil
	return result
}

func runAndroidConfigEntered(operation func() error) (err error, panicked bool) {
	defer func() {
		if recover() != nil {
			err = errors.New("配置提交发生panic")
			panicked = true
		}
	}()
	err = operation()
	return err, false
}

func (c *androidConfigCoordinator) commitLocked(expectedEpoch, expectedRevision int64, mutation *decodedAndroidConfigMutation) androidOwnedConfigResult {
	if !c.driver.initializedLocked() {
		return c.rejectedLocked(androidConfigErrorCoreNotInitialized)
	}
	if c.blocked {
		return c.rejectedLocked(androidConfigErrorBlocked)
	}
	if c.tunReservation != nil {
		return c.rejectedLocked(androidConfigErrorTunReserved)
	}
	if !c.configured && c.driver.configPresentLocked() {
		return c.rejectedLocked(androidConfigErrorLegacyConfigPresent)
	}
	if expectedEpoch != c.epoch {
		return c.rejectedLocked(androidConfigErrorStaleEpoch)
	}
	if expectedRevision < 0 || expectedRevision != c.lastApplied {
		return c.rejectedLocked(androidConfigErrorStaleRevision)
	}

	baseState := c.desiredState
	if !c.hasDesiredState {
		baseState = c.driver.stateSnapshotLocked()
	}
	if mutation.kind == androidConfigKindState && !c.configured {
		next, err := state.MergeJSON(baseState, mutation.stateBytes)
		if err != nil {
			return c.rejectedLocked(androidConfigErrorInvalidPayload)
		}
		if c.stateGeneration == math.MaxInt64 {
			return c.rejectedLocked(androidConfigErrorRevisionOverflow)
		}
		c.desiredState = next
		c.hasDesiredState = true
		c.stateGeneration++
		c.lastErrorCode = androidConfigErrorNone
		return c.snapshotLocked()
	}
	if mutation.kind == androidConfigKindUpdate && !c.configured {
		return c.rejectedLocked(androidConfigErrorUpdateBeforeConfig)
	}
	if mutation.kind == androidConfigKindInitialComposite && c.configured {
		return c.rejectedLocked(androidConfigErrorInitialOnly)
	}
	if mutation.kind == androidConfigKindSetup && !c.hasDesiredState {
		return c.rejectedLocked(androidConfigErrorInitialStateMissing)
	}

	desired := state.Copy(baseState)
	nextStateGeneration := c.stateGeneration
	if mutation.kind == androidConfigKindInitialComposite || mutation.kind == androidConfigKindState {
		next, err := state.MergeJSON(baseState, mutation.stateBytes)
		if err != nil {
			return c.rejectedLocked(androidConfigErrorInvalidPayload)
		}
		if nextStateGeneration == math.MaxInt64 {
			return c.rejectedLocked(androidConfigErrorRevisionOverflow)
		}
		desired = next
		nextStateGeneration++
	}
	if c.lastAttempted == math.MaxInt64 {
		return c.rejectedLocked(androidConfigErrorRevisionOverflow)
	}
	attempt := c.lastAttempted + 1
	c.lastAttempted = attempt // ENTERED：从此尝试号不可复用，也不响应调用方取消。

	var enteredErrorCode string
	var operation func() error
	switch mutation.kind {
	case androidConfigKindSetup, androidConfigKindInitialComposite:
		prepared, err, panicked := prepareAndroidSetupEntered(c.driver, mutation.setup)
		if err != nil || panicked {
			return c.enteredFailureLocked(attempt, androidConfigErrorConfigPrepareFailed)
		}
		enteredErrorCode = androidConfigErrorConfigApplyFailed
		operation = func() error { return c.driver.commitSetupLocked(prepared, desired) }
	case androidConfigKindUpdate:
		enteredErrorCode = androidConfigErrorUpdateApplyFailed
		operation = func() error { return c.driver.updateLocked(mutation.update) }
	case androidConfigKindState:
		enteredErrorCode = androidConfigErrorStateApplyFailed
		operation = func() error { return c.driver.replaceStateLocked(desired) }
	default:
		return c.enteredFailureLocked(attempt, androidConfigErrorInvalidKind)
	}
	if err, panicked := runAndroidConfigEntered(operation); err != nil || panicked {
		return c.enteredFailureLocked(attempt, enteredErrorCode)
	}
	options, err, panicked := snapshotAndroidOptionsEntered(c.driver, desired)
	if err != nil || panicked || options == nil {
		return c.enteredFailureLocked(attempt, androidConfigErrorOptionsFailed)
	}
	c.lastApplied = attempt
	c.configured = true
	c.desiredState = state.Copy(desired)
	c.hasDesiredState = true
	c.stateGeneration = nextStateGeneration
	c.options = cloneAndroidVpnOptions(options)
	c.lastErrorCode = androidConfigErrorNone
	return c.snapshotLocked()
}

func prepareAndroidSetupEntered(driver androidConfigDriver, params *SetupParams) (prepared *preparedSetupConfig, err error, panicked bool) {
	defer func() {
		if recover() != nil {
			prepared = nil
			err = errors.New("配置准备发生panic")
			panicked = true
		}
	}()
	prepared, err = driver.prepareSetupLocked(params)
	return
}

func snapshotAndroidOptionsEntered(driver androidConfigDriver, desired state.State) (options *state.AndroidVpnOptions, err error, panicked bool) {
	defer func() {
		if recover() != nil {
			options = nil
			err = errors.New("配置快照发生panic")
			panicked = true
		}
	}()
	options, err = driver.optionsLocked(desired)
	return
}

func cloneAndroidVpnOptions(options *state.AndroidVpnOptions) *state.AndroidVpnOptions {
	if options == nil {
		return nil
	}
	copyOf := *options
	copyOf.RouteAddress = cloneAndroidRouteAddress(options.RouteAddress)
	copyOf.BypassDomain = append(copyOf.BypassDomain[:0:0], options.BypassDomain...)
	if options.AccessControl != nil {
		control := *options.AccessControl
		control.AcceptList = append(control.AcceptList[:0:0], options.AccessControl.AcceptList...)
		control.RejectList = append(control.RejectList[:0:0], options.AccessControl.RejectList...)
		copyOf.AccessControl = &control
	}
	return &copyOf
}

func cloneAndroidRouteAddress(value []netip.Prefix) []netip.Prefix {
	if value == nil {
		return nil
	}
	return append(make([]netip.Prefix, 0, len(value)), value...)
}

// 调用者持有runLock；返回值只引用新复制的数据，可随同一次配置回执发布。
func androidVpnOptionsSnapshotLocked(configSnapshot *config.Config, clientState state.State) *state.AndroidVpnOptions {
	ipv6Address := ""
	if configSnapshot.General.IPv6 {
		ipv6Address = state.DefaultIpv6Address
	}
	clientStateCopy := state.Copy(clientState)
	routeAddress := cloneAndroidRouteAddress(configSnapshot.General.Tun.RouteAddress)
	return &state.AndroidVpnOptions{
		Enable:                clientStateCopy.VpnProps.Enable,
		Port:                  configSnapshot.General.MixedPort,
		Ipv4Address:           state.DefaultIpv4Address,
		Ipv6Address:           ipv6Address,
		AccessControl:         clientStateCopy.VpnProps.AccessControl,
		SystemProxy:           clientStateCopy.VpnProps.SystemProxy,
		AllowBypass:           clientStateCopy.VpnProps.AllowBypass,
		RouteAddress:          routeAddress,
		RouteMode:             clientStateCopy.VpnProps.RouteMode,
		BypassDomain:          clientStateCopy.BypassDomain,
		DnsServerAddress:      state.GetDnsServerAddress(),
		DozeSuspend:           clientStateCopy.VpnProps.DozeSuspend,
		DisableIcmpForwarding: configSnapshot.General.Tun.DisableICMPForwarding,
		Mtu:                   uint32(configSnapshot.General.Tun.MTU),
	}
}

func getAndroidOwnedConfigStatusJSON() string {
	runLock.Lock()
	defer runLock.Unlock()
	if !productionAndroidConfigCoordinator.blocked && !productionAndroidConfigCoordinator.configured && productionAndroidConfigCoordinator.driver.configPresentLocked() {
		return productionAndroidConfigCoordinator.marshalResultLocked(
			productionAndroidConfigCoordinator.rejectedLocked(androidConfigErrorLegacyConfigPresent),
		)
	}
	return productionAndroidConfigCoordinator.marshalResultLocked(productionAndroidConfigCoordinator.snapshotLocked())
}

func commitAndroidOwnedConfigJSON(expectedEpoch, expectedRevision int64, kind int, payload string) string {
	if len(payload) > androidConfigPayloadLimit {
		return productionAndroidConfigRejectedJSON(androidConfigErrorPayloadTooLarge)
	}
	mutation, errorCode := decodeAndroidConfigMutation(kind, payload)
	if errorCode != androidConfigErrorNone {
		return productionAndroidConfigRejectedJSON(errorCode)
	}
	runLock.Lock()
	defer runLock.Unlock()
	return productionAndroidConfigCoordinator.marshalResultLocked(
		productionAndroidConfigCoordinator.commitLocked(expectedEpoch, expectedRevision, mutation),
	)
}

func productionAndroidConfigRejectedJSON(errorCode string) string {
	runLock.Lock()
	defer runLock.Unlock()
	return productionAndroidConfigCoordinator.marshalResultLocked(
		productionAndroidConfigCoordinator.rejectedLocked(errorCode),
	)
}

func (c *androidConfigCoordinator) marshalResultLocked(result androidOwnedConfigResult) string {
	return c.marshalResultWithEncoderLocked(result, json.Marshal)
}

func (c *androidConfigCoordinator) marshalResultWithEncoderLocked(
	result androidOwnedConfigResult,
	encode func(any) ([]byte, error),
) string {
	result.Options = cloneAndroidVpnOptions(result.Options)
	data, err := encode(result)
	if err != nil {
		c.blocked = true
		c.lastErrorCode = androidConfigErrorReceiptEncoding
		blocked := c.snapshotLocked()
		data, fallbackErr := json.Marshal(blocked)
		if fallbackErr != nil {
			panic("固定配置回执无法编码")
		}
		return string(data)
	}
	return string(data)
}
