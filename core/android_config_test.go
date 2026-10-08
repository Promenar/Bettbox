package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"sync"
	"testing"

	"core/state"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	listenerconfig "github.com/metacubex/mihomo/listener/config"
)

func withProductionAndroidConfigFixture(t *testing.T) {
	t.Helper()
	runLock.Lock()
	previousCoordinator := productionAndroidConfigCoordinator
	previousInit := isInit
	previousConfig := currentConfig
	previousRawConfig := currentRawConfig
	previousState := state.Snapshot()
	previousTestURL := constant.DefaultTestURL
	productionAndroidConfigCoordinator = androidConfigCoordinator{
		driver: productionAndroidConfigDriver{},
		epoch:  androidConfigEpoch,
	}
	isInit = true
	currentConfig = nil
	currentRawConfig = nil
	runLock.Unlock()
	t.Cleanup(func() {
		runLock.Lock()
		defer runLock.Unlock()
		productionAndroidConfigCoordinator = previousCoordinator
		isInit = previousInit
		currentConfig = previousConfig
		currentRawConfig = previousRawConfig
		constant.DefaultTestURL = previousTestURL
		state.Replace(previousState)
	})
}

// 该用例直接走与 C ABI 共用的生产入口，防止只实现孤立helper或测试driver。
func TestProductionAndroidConfigCoordinatorStagesStateBeforeSetup(t *testing.T) {
	withProductionAndroidConfigFixture(t)
	raw := commitAndroidOwnedConfigJSON(
		androidConfigEpoch,
		0,
		androidConfigKindState,
		`{"current-profile-name":"PUBLIC_ANDROID_STAGED","vpn-props":{"allowBypass":true}}`,
	)
	var result androidOwnedConfigResult
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatalf("生产配置回执不是合法JSON: %v", err)
	}
	assertStagedStateResult(t, result)
	if state.Snapshot().CurrentProfileName == "PUBLIC_ANDROID_STAGED" {
		t.Fatal("未配置state不应提前提交Go全局状态")
	}
}

func TestProductionAndroidConfigParseFailureBecomesStickyUnknown(t *testing.T) {
	withProductionAndroidConfigFixture(t)
	stagedRaw := commitAndroidOwnedConfigJSON(androidConfigEpoch, 0, androidConfigKindState, `{}`)
	var staged androidOwnedConfigResult
	if err := json.Unmarshal([]byte(stagedRaw), &staged); err != nil {
		t.Fatalf("生产staged回执不是合法JSON: %v", err)
	}
	assertStagedStateResult(t, staged)

	raw := config.DefaultRawConfig()
	// 在proxy解析阶段固定失败，不进入provider加载、成功ApplyConfig或公网访问。
	raw.Proxy = []map[string]any{{"name": "公开无效节点", "type": "PUBLIC_INVALID_PROXY_TYPE"}}
	payload, err := json.Marshal(&SetupParams{Config: raw})
	if err != nil {
		t.Fatalf("无效setup夹具编码失败: %v", err)
	}
	failedRaw := commitAndroidOwnedConfigJSON(androidConfigEpoch, 0, androidConfigKindSetup, string(payload))
	var failed androidOwnedConfigResult
	if err := json.Unmarshal([]byte(failedRaw), &failed); err != nil {
		t.Fatalf("生产失败回执不是合法JSON: %v", err)
	}
	if failed.Outcome != androidConfigOutcomeUnknown || failed.Phase != androidConfigPhaseEntered ||
		!failed.Blocked || failed.AttemptedRevision != 1 || failed.ConfigRevision != 0 ||
		failed.ErrorCode != androidConfigErrorConfigPrepareFailed || currentConfig != nil {
		t.Fatalf("生产解析失败未保留ENTERED责任: %+v currentConfig=%p", failed, currentConfig)
	}

	var status androidOwnedConfigResult
	if err := json.Unmarshal([]byte(getAndroidOwnedConfigStatusJSON()), &status); err != nil {
		t.Fatalf("blocked状态回执不是合法JSON: %v", err)
	}
	if status.Outcome != androidConfigOutcomeUnknown || status.Phase != androidConfigPhaseEntered ||
		status.AttemptedRevision != 1 || status.ErrorCode != androidConfigErrorConfigPrepareFailed {
		t.Fatalf("status清洗了生产解析失败责任: %+v", status)
	}

	retryRaw := commitAndroidOwnedConfigJSON(androidConfigEpoch, 0, androidConfigKindSetup, string(payload))
	var retry androidOwnedConfigResult
	if err := json.Unmarshal([]byte(retryRaw), &retry); err != nil {
		t.Fatalf("blocked重试回执不是合法JSON: %v", err)
	}
	if retry.Outcome != androidConfigOutcomeRejected || retry.Phase != androidConfigPhaseNotEntered ||
		retry.ErrorCode != androidConfigErrorBlocked || retry.AttemptedRevision != 1 {
		t.Fatalf("blocked后续配置未在ENTERED前拒绝: %+v", retry)
	}
}

func assertStagedStateResult(t *testing.T, result androidOwnedConfigResult) {
	t.Helper()
	if result.Outcome != androidConfigOutcomeStaged || result.Phase != androidConfigPhaseStaged {
		t.Fatalf("未配置state必须进入staged，实际为 outcome=%s phase=%s errorCode=%s", result.Outcome, result.Phase, result.ErrorCode)
	}
	if result.Epoch != androidConfigEpoch || result.ConfigRevision != 0 || result.AttemptedRevision != 0 {
		t.Fatalf("staged不得伪造配置版本: %+v", result)
	}
	if result.StateGeneration != 1 || result.Configured || result.Blocked || result.Options != nil || result.ErrorCode != "" {
		t.Fatalf("staged回执与未配置合同不符: %+v", result)
	}
}

type fixtureAndroidConfigDriver struct {
	initHome    string
	initVersion int
	initErr     error
	initCall    int
	listeners   bool
	initialized bool
	present     bool
	state       state.State
	prepareErr  error
	commitErr   error
	updateErr   error
	stateErr    error
	optionsErr  error
	panicAt     string
	prepareCall int
	commitCall  int
	updateCall  int
	stateCall   int
}

func (d *fixtureAndroidConfigDriver) initializedLocked() bool { return d.initialized }
func (d *fixtureAndroidConfigDriver) initializationCompatibleLocked(p *InitParams) bool {
	return !d.initialized || d.initHome == p.HomeDir && d.initVersion == p.Version
}
func (d *fixtureAndroidConfigDriver) listenersPresentLocked() bool { return d.listeners }
func (d *fixtureAndroidConfigDriver) initializeLocked(p *InitParams) error {
	if d.initialized {
		return nil
	}
	d.initCall++
	if d.panicAt == "initialize" {
		panic("公开初始化故障")
	}
	if d.initErr != nil {
		return d.initErr
	}
	d.initialized = true
	d.initHome, d.initVersion = p.HomeDir, p.Version
	return nil
}
func (d *fixtureAndroidConfigDriver) configPresentLocked() bool        { return d.present }
func (d *fixtureAndroidConfigDriver) stateSnapshotLocked() state.State { return state.Copy(d.state) }
func (d *fixtureAndroidConfigDriver) prepareSetupLocked(*SetupParams) (*preparedSetupConfig, error) {
	d.prepareCall++
	if d.panicAt == "prepare" {
		panic("fixture prepare panic")
	}
	return &preparedSetupConfig{}, d.prepareErr
}
func (d *fixtureAndroidConfigDriver) commitSetupLocked(_ *preparedSetupConfig, desired state.State) error {
	d.commitCall++
	if d.panicAt == "commit" {
		panic("fixture commit panic")
	}
	if d.commitErr == nil {
		d.present = true
		d.state = state.Copy(desired)
	}
	return d.commitErr
}
func (d *fixtureAndroidConfigDriver) updateLocked(*UpdateParams) error {
	d.updateCall++
	if d.panicAt == "update" {
		panic("fixture update panic")
	}
	return d.updateErr
}
func (d *fixtureAndroidConfigDriver) replaceStateLocked(value state.State) error {
	d.stateCall++
	if d.panicAt == "state" {
		panic("fixture state panic")
	}
	if d.stateErr == nil {
		d.state = state.Copy(value)
	}
	return d.stateErr
}
func (d *fixtureAndroidConfigDriver) optionsLocked(value state.State) (*state.AndroidVpnOptions, error) {
	if d.panicAt == "options" {
		panic("fixture options panic")
	}
	if d.optionsErr != nil {
		return nil, d.optionsErr
	}
	copyOf := state.Copy(value)
	return &state.AndroidVpnOptions{
		Enable:        copyOf.VpnProps.Enable,
		AllowBypass:   copyOf.VpnProps.AllowBypass,
		BypassDomain:  copyOf.BypassDomain,
		AccessControl: copyOf.VpnProps.AccessControl,
		Port:          7890,
	}, nil
}

func fixtureMutation(t *testing.T, kind int, payload string) *decodedAndroidConfigMutation {
	t.Helper()
	mutation, errorCode := decodeAndroidConfigMutation(kind, payload)
	if errorCode != "" {
		t.Fatalf("fixture mutation解码失败: %s", errorCode)
	}
	return mutation
}

func fixtureSetupJSON(t *testing.T) string {
	t.Helper()
	data, err := json.Marshal(defaultSetupParams())
	if err != nil {
		t.Fatalf("setup fixture编码失败: %v", err)
	}
	return string(data)
}

func TestAndroidConfigRejectsBeforeInitWithoutStaging(t *testing.T) {
	driver := &fixtureAndroidConfigDriver{}
	coordinator := newAndroidConfigCoordinatorForTest(driver)
	result := coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindState, `{}`))
	if result.Outcome != androidConfigOutcomeRejected || result.Phase != androidConfigPhaseNotEntered ||
		result.ErrorCode != androidConfigErrorCoreNotInitialized || result.StateGeneration != 0 {
		t.Fatalf("未初始化门禁错误: %+v", result)
	}
}

func TestAndroidConfigStagedStateIsConsumedBySetupAndCASIsStrict(t *testing.T) {
	driver := &fixtureAndroidConfigDriver{initialized: true}
	coordinator := newAndroidConfigCoordinatorForTest(driver)
	staged := coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindState,
		`{"current-profile-name":"PUBLIC_STAGED","bypass-domain":["fixture.invalid"]}`))
	assertStagedStateResult(t, staged)
	applied := coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindSetup, fixtureSetupJSON(t)))
	if applied.Outcome != androidConfigOutcomeApplied || applied.ConfigRevision != 1 || applied.AttemptedRevision != 1 ||
		!applied.Configured || applied.Options == nil || driver.state.CurrentProfileName != "PUBLIC_STAGED" {
		t.Fatalf("setup未消费staged state: %+v state=%+v", applied, driver.state)
	}
	stale := coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindUpdate, `{}`))
	if stale.ErrorCode != androidConfigErrorStaleRevision || stale.Phase != androidConfigPhaseNotEntered || driver.updateCall != 0 {
		t.Fatalf("stale base未在副作用前拒绝: %+v calls=%d", stale, driver.updateCall)
	}
}

func TestAndroidConfigInvalidStateKeepsEarlierStagedSnapshot(t *testing.T) {
	driver := &fixtureAndroidConfigDriver{initialized: true}
	coordinator := newAndroidConfigCoordinatorForTest(driver)
	coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindState,
		`{"current-profile-name":"PUBLIC_KEPT"}`))
	invalid := coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindState,
		`{"only-statistics-proxy":"INVALID"}`))
	if invalid.Outcome != androidConfigOutcomeRejected || invalid.Phase != androidConfigPhaseNotEntered ||
		invalid.StateGeneration != 1 || invalid.AttemptedRevision != 0 {
		t.Fatalf("无效state改变了staged归属: %+v", invalid)
	}
	applied := coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindSetup, fixtureSetupJSON(t)))
	if applied.Outcome != androidConfigOutcomeApplied || driver.state.CurrentProfileName != "PUBLIC_KEPT" {
		t.Fatalf("无效state覆盖了已staged状态: %+v state=%+v", applied, driver.state)
	}
}

func TestAndroidConfigInitialCompositeAppliesOneRevision(t *testing.T) {
	driver := &fixtureAndroidConfigDriver{initialized: true}
	coordinator := newAndroidConfigCoordinatorForTest(driver)
	setup := json.RawMessage(fixtureSetupJSON(t))
	payload, err := json.Marshal(map[string]json.RawMessage{
		"setup": setup,
		"state": json.RawMessage(`{"current-profile-name":"PUBLIC_COMPOSITE","vpn-props":{"enable":true}}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	result := coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindInitialComposite, string(payload)))
	if result.Outcome != androidConfigOutcomeApplied || result.ConfigRevision != 1 || result.StateGeneration != 1 ||
		result.Options == nil || !result.Options.Enable || driver.prepareCall != 1 || driver.commitCall != 1 {
		t.Fatalf("initialComposite未形成一次真实提交: %+v", result)
	}
}

func TestAndroidConfigEnteredFailuresAreStickyAndAttemptsAreNotReused(t *testing.T) {
	for _, test := range []struct {
		name       string
		prepareErr error
		panicAt    string
		errorCode  string
	}{
		{name: "prepare error", prepareErr: errors.New("fixture"), errorCode: androidConfigErrorConfigPrepareFailed},
		{name: "commit panic", panicAt: "commit", errorCode: androidConfigErrorConfigApplyFailed},
	} {
		t.Run(test.name, func(t *testing.T) {
			driver := &fixtureAndroidConfigDriver{initialized: true, prepareErr: test.prepareErr, panicAt: test.panicAt}
			coordinator := newAndroidConfigCoordinatorForTest(driver)
			coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindState, `{}`))
			failed := coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindSetup, fixtureSetupJSON(t)))
			if failed.Outcome != androidConfigOutcomeUnknown || failed.Phase != androidConfigPhaseEntered ||
				!failed.Blocked || failed.AttemptedRevision != 1 || failed.ConfigRevision != 0 || failed.ErrorCode != test.errorCode {
				t.Fatalf("ENTERED失败分类错误: %+v", failed)
			}
			retry := coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindSetup, fixtureSetupJSON(t)))
			if retry.Outcome != androidConfigOutcomeRejected || retry.ErrorCode != androidConfigErrorBlocked || retry.AttemptedRevision != 1 {
				t.Fatalf("blocked被重试清洗或尝试号复用: %+v", retry)
			}
		})
	}
}

func TestAndroidConfigAppliedAttemptsAdvanceAndOptionsAreIndependent(t *testing.T) {
	driver := &fixtureAndroidConfigDriver{initialized: true}
	coordinator := newAndroidConfigCoordinatorForTest(driver)
	coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindState,
		`{"bypass-domain":["first.invalid"],"vpn-props":{"accessControl":{"acceptList":["PUBLIC_ACCEPT"]}}}`))
	first := coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindSetup, fixtureSetupJSON(t)))
	first.Options.BypassDomain[0] = "changed.invalid"
	first.Options.AccessControl.AcceptList[0] = "PUBLIC_CHANGED"
	status := coordinator.snapshotLocked()
	if status.Options.BypassDomain[0] != "first.invalid" || status.Options.AccessControl.AcceptList[0] != "PUBLIC_ACCEPT" {
		t.Fatal("回执options泄露coordinator内部可变别名")
	}
	second := coordinator.commitLocked(androidConfigEpoch, 1, fixtureMutation(t, androidConfigKindUpdate, `{"mixed-port":7891}`))
	if second.ConfigRevision != 2 || second.AttemptedRevision != 2 || driver.updateCall != 1 {
		t.Fatalf("成功尝试号未单调推进: %+v calls=%d", second, driver.updateCall)
	}
}

func TestAndroidConfigPreEntryValidationHasNoDriverSideEffects(t *testing.T) {
	driver := &fixtureAndroidConfigDriver{initialized: true}
	coordinator := newAndroidConfigCoordinatorForTest(driver)
	tests := []struct {
		epoch     int64
		revision  int64
		kind      int
		payload   string
		errorCode string
	}{
		{androidConfigEpoch + 1, 0, androidConfigKindState, `{}`, androidConfigErrorStaleEpoch},
		{androidConfigEpoch, 1, androidConfigKindState, `{}`, androidConfigErrorStaleRevision},
		{androidConfigEpoch, 0, androidConfigKindUpdate, `{}`, androidConfigErrorUpdateBeforeConfig},
	}
	for _, test := range tests {
		result := coordinator.commitLocked(test.epoch, test.revision, fixtureMutation(t, test.kind, test.payload))
		if result.ErrorCode != test.errorCode || result.Phase != androidConfigPhaseNotEntered || result.AttemptedRevision != 0 {
			t.Fatalf("副作用前拒绝错误: %+v", result)
		}
	}
	if driver.prepareCall != 0 || driver.commitCall != 0 || driver.updateCall != 0 || driver.stateCall != 0 {
		t.Fatalf("副作用前拒绝仍调用driver: %+v", driver)
	}
}

func TestAndroidConfigDecodeRejectsTrailingAndInvalidKinds(t *testing.T) {
	for _, test := range []struct {
		kind      int
		payload   string
		errorCode string
	}{
		{99, `{}`, androidConfigErrorInvalidKind},
		{androidConfigKindState, `{} {}`, androidConfigErrorInvalidPayload},
		{androidConfigKindInitialComposite, `{"setup":{},"state":null}`, androidConfigErrorInvalidPayload},
	} {
		if _, errorCode := decodeAndroidConfigMutation(test.kind, test.payload); errorCode != test.errorCode {
			t.Fatalf("解码拒绝类别错误: got=%s want=%s", errorCode, test.errorCode)
		}
	}
}

func TestAndroidConfigLegacyConfigCannotBeAdoptedAsApplied(t *testing.T) {
	driver := &fixtureAndroidConfigDriver{initialized: true, present: true}
	coordinator := newAndroidConfigCoordinatorForTest(driver)
	result := coordinator.commitLocked(androidConfigEpoch, 0, fixtureMutation(t, androidConfigKindState, `{}`))
	if result.ErrorCode != androidConfigErrorLegacyConfigPresent || result.Configured || result.Options != nil {
		t.Fatalf("未追踪旧配置被伪造为Applied: %+v", result)
	}
}

func TestAndroidVpnOptionsSnapshotHasNoMutableAliases(t *testing.T) {
	route := []netip.Prefix{netip.MustParsePrefix("198.51.100.0/24")}
	configSnapshot := &config.Config{General: &config.General{Inbound: config.Inbound{
		MixedPort: 7890,
		Tun:       listenerconfig.Tun{RouteAddress: route, MTU: 1400},
	}}}
	clientState := state.State{
		BypassDomain: []string{"fixture.invalid"},
		VpnProps: state.AndroidVpnRawOptions{AccessControl: &state.AccessControl{
			AcceptList: []string{"PUBLIC_ACCEPT"},
		}},
	}
	options := androidVpnOptionsSnapshotLocked(configSnapshot, clientState)
	configSnapshot.General.Tun.RouteAddress[0] = netip.MustParsePrefix("203.0.113.0/24")
	clientState.BypassDomain[0] = "changed.invalid"
	clientState.VpnProps.AccessControl.AcceptList[0] = "PUBLIC_CHANGED"
	if options.RouteAddress[0].String() != "198.51.100.0/24" || options.BypassDomain[0] != "fixture.invalid" ||
		options.AccessControl.AcceptList[0] != "PUBLIC_ACCEPT" {
		t.Fatalf("options快照保留了candidate/state别名: %+v", options)
	}
}

func TestAndroidVpnOptionsRouteAddressPreservesWireShape(t *testing.T) {
	for _, test := range []struct {
		name  string
		value []netip.Prefix
		want  string
	}{
		{name: "nil", value: nil, want: "null"},
		{name: "explicit empty", value: []netip.Prefix{}, want: "[]"},
		{name: "non-empty", value: []netip.Prefix{netip.MustParsePrefix("198.51.100.0/24")}, want: `["198.51.100.0/24"]`},
	} {
		t.Run(test.name, func(t *testing.T) {
			configSnapshot := &config.Config{General: &config.General{Inbound: config.Inbound{
				Tun: listenerconfig.Tun{RouteAddress: test.value},
			}}}
			options := androidVpnOptionsSnapshotLocked(configSnapshot, state.State{})
			coordinator := newAndroidConfigCoordinatorForTest(&fixtureAndroidConfigDriver{})
			wire := coordinator.marshalResultLocked(androidOwnedConfigResult{Epoch: androidConfigEpoch, Options: options})
			var decoded struct {
				Options struct {
					RouteAddress json.RawMessage `json:"routeAddress"`
				} `json:"options"`
			}
			if err := json.Unmarshal([]byte(wire), &decoded); err != nil {
				t.Fatalf("wire回执不是合法JSON: %v", err)
			}
			if string(decoded.Options.RouteAddress) != test.want {
				t.Fatalf("RouteAddress三态丢失: got=%s want=%s", decoded.Options.RouteAddress, test.want)
			}
		})
	}
}

func TestAndroidConfigReceiptEncodingFailureBlocksAndPreservesStamp(t *testing.T) {
	coordinator := newAndroidConfigCoordinatorForTest(&fixtureAndroidConfigDriver{})
	coordinator.lastApplied = 7
	coordinator.lastAttempted = 7
	coordinator.stateGeneration = 3
	coordinator.configured = true
	coordinator.options = &state.AndroidVpnOptions{RouteAddress: []netip.Prefix{}}
	result := coordinator.snapshotLocked()

	calls := 0
	wire := coordinator.marshalResultWithEncoderLocked(result, func(any) ([]byte, error) {
		calls++
		return nil, errors.New("fixture encode failure")
	})
	var failed androidOwnedConfigResult
	if err := json.Unmarshal([]byte(wire), &failed); err != nil {
		t.Fatalf("编码失败回执不是合法JSON: %v", err)
	}
	if calls != 1 || failed.Outcome != androidConfigOutcomeUnknown || failed.Phase != androidConfigPhaseEntered ||
		failed.Epoch != androidConfigEpoch || failed.ConfigRevision != 7 || failed.AttemptedRevision != 7 ||
		failed.StateGeneration != 3 || !failed.Configured || !failed.Blocked || failed.Options != nil ||
		failed.ErrorCode != androidConfigErrorReceiptEncoding {
		t.Fatalf("编码失败未粘滞阻断或丢失版本戳: calls=%d result=%+v", calls, failed)
	}
	status := coordinator.snapshotLocked()
	if !status.Blocked || status.ErrorCode != androidConfigErrorReceiptEncoding || status.ConfigRevision != 7 {
		t.Fatalf("编码失败只伪造单次blocked回执: %+v", status)
	}
}

// 直接调用生产公共入口，验证已接受的配置身份不会被旧写入污染。
func TestProductionAndroidConfigRejectsLegacyMutations(t *testing.T) {
	for _, phase := range []string{"staged", "entered", "configured", "blocked", "reservation"} {
		t.Run(phase, func(t *testing.T) {
			withProductionAndroidConfigFixture(t)
			var staged androidOwnedConfigResult
			if err := json.Unmarshal([]byte(commitAndroidOwnedConfigJSON(androidConfigEpoch, 0, androidConfigKindState, `{}`)), &staged); err != nil {
				t.Fatal(err)
			}
			assertStagedStateResult(t, staged)
			runLock.Lock()
			switch phase {
			case "entered":
				productionAndroidConfigCoordinator.hasDesiredState = false
				productionAndroidConfigCoordinator.lastAttempted = 1
			case "configured":
				productionAndroidConfigCoordinator.hasDesiredState = false
				productionAndroidConfigCoordinator.configured = true
			case "reservation":
				productionAndroidConfigCoordinator.hasDesiredState = false
				productionAndroidConfigCoordinator.tunReservation = &androidTunReservation{epoch: androidConfigEpoch, revision: 1}
			case "blocked":
				productionAndroidConfigCoordinator.hasDesiredState = false
				productionAndroidConfigCoordinator.blocked = true
			}
			before := state.Snapshot()
			oldVersion := version
			runLock.Unlock()
			t.Cleanup(func() { runLock.Lock(); version = oldVersion; runLock.Unlock() })
			if err := handleSetState(`{"current-profile-name":"PUBLIC_LEGACY_INTRUSION"}`); err == nil {
				t.Fatal("已接受owned配置后旧setState仍获准写入")
			}
			if state.Snapshot().CurrentProfileName != before.CurrentProfileName {
				t.Fatal("拒绝旧写仍污染实际状态")
			}
			if handleInitClash(`{"version":"PUBLIC_LEGACY_INIT"}`) || version != oldVersion {
				t.Fatal("旧init不得覆盖已接受的配置运行时")
			}
			if message := handleUpdateConfig([]byte(`{}`)); message == "" {
				t.Fatal("旧update不得报告应用成功")
			}
			if message := handleSetupConfig([]byte(`{`)); message == "" || currentConfig != nil || currentRawConfig != nil {
				t.Fatal("畸形旧setup不得回退写默认配置")
			}
			if message := handleSetupConfig([]byte(`{"config":{}}`)); message == "" || currentConfig != nil || currentRawConfig != nil {
				t.Fatal("合法旧setup不得覆盖owned配置")
			}
			currentConfig = &config.Config{General: &config.General{}}
			requestedPort := 12345
			updateConfig(&UpdateParams{MixedPort: &requestedPort})
			if currentConfig.General.MixedPort != 0 {
				t.Fatal("直接旧update包装器修改了实际配置")
			}
			currentConfig = nil
			if err := setupConfig(defaultSetupParams()); err == nil || currentConfig != nil {
				t.Fatal("直接旧setup包装器不得旁路写入")
			}
		})
	}
}

func TestProductionAndroidConfigAllowsUnadoptedLegacyState(t *testing.T) {
	withProductionAndroidConfigFixture(t)
	if err := handleSetState(`{"current-profile-name":"PUBLIC_LEGACY_ALLOWED"}`); err != nil {
		t.Fatal(err)
	}
	if state.Snapshot().CurrentProfileName != "PUBLIC_LEGACY_ALLOWED" {
		t.Fatal("尚未采用owned的状态写入应保持工作")
	}
}

// 竞争允许旧请求先于采用提交；采用返回后任何旧请求均不得再污染状态。
func TestProductionAndroidConfigConcurrentLegacyAdoption(t *testing.T) {
	for attempt := 0; attempt < 32; attempt++ {
		t.Run(fmt.Sprint(attempt), func(t *testing.T) {
			withProductionAndroidConfigFixture(t)
			start := make(chan struct{})
			var wg sync.WaitGroup
			var legacyErr error
			var ownedWire string
			wg.Add(2)
			go func() {
				defer wg.Done()
				<-start
				legacyErr = handleSetState(`{"current-profile-name":"PUBLIC_BEFORE_ADOPTION"}`)
			}()
			go func() {
				defer wg.Done()
				<-start
				ownedWire = commitAndroidOwnedConfigJSON(androidConfigEpoch, 0, androidConfigKindState, `{}`)
			}()
			close(start)
			wg.Wait()
			var owned androidOwnedConfigResult
			if err := json.Unmarshal([]byte(ownedWire), &owned); err != nil {
				t.Fatal(err)
			}
			assertStagedStateResult(t, owned)
			before := state.Snapshot().CurrentProfileName
			if legacyErr == nil && before != "PUBLIC_BEFORE_ADOPTION" {
				t.Fatal("采用前受理的旧请求没有完成写入")
			}
			if err := handleSetState(`{"current-profile-name":"PUBLIC_AFTER_ADOPTION"}`); err == nil {
				t.Fatal("并发采用完成后旧写入仍获准")
			}
			if state.Snapshot().CurrentProfileName != before {
				t.Fatal("并发采用后拒绝请求仍污染状态")
			}
		})
	}
}
