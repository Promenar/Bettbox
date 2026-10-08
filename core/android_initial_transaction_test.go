package main

import (
	"encoding/json"
	"errors"
	"math"
	"sync"
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
)

// 使用实际入口和初始化原语；配置在节点解析阶段失败，不开启网络监听。
func TestProductionAndroidInitialTransactionRetainsInitializationResponsibility(t *testing.T) {
	withProductionAndroidConfigFixture(t)
	previousHome, previousVersion := constant.Path.HomeDir(), version
	t.Cleanup(func() {
		constant.SetHomeDir(previousHome)
		version = previousVersion
	})
	isInit = false
	raw := config.DefaultRawConfig()
	raw.Proxy = []map[string]any{{"name": "公开无效节点", "type": "PUBLIC_INVALID_PROXY_TYPE"}}
	init := InitParams{HomeDir: t.TempDir(), Version: 36}
	payload, err := json.Marshal(map[string]any{
		"init": init, "setup": SetupParams{Config: raw}, "state": map[string]any{},
	})
	if err != nil {
		t.Fatal("公开夹具编码失败")
	}
	var result androidOwnedConfigResult
	if json.Unmarshal([]byte(commitAndroidOwnedConfigJSON(androidConfigEpoch, 0, 5, string(payload))), &result) != nil {
		t.Fatal("回执编码无效")
	}
	if !isInit || version != 36 || constant.Path.HomeDir() != init.HomeDir {
		t.Fatal("首次事务没有执行实际初始化")
	}
	if result.Outcome != androidConfigOutcomeUnknown || result.Phase != androidConfigPhaseEntered ||
		!result.Blocked || result.AttemptedRevision != 1 || result.ConfigRevision != 0 ||
		result.ErrorCode != androidConfigErrorConfigPrepareFailed || currentConfig != nil {
		t.Fatal("初始化后的配置失败没有保留未确认责任")
	}
	if handleInitClash(`{"home-dir":"PUBLIC_LEGACY","version":1}`) || version != 36 || constant.Path.HomeDir() != init.HomeDir {
		t.Fatal("初始化失败责任允许旧入口污染")
	}
}

func initialTransactionFixture(t *testing.T) *decodedAndroidConfigMutation {
	t.Helper()
	return fixtureMutation(t, androidConfigKindInitializeComposite,
		`{"init":{"home-dir":"/PUBLIC_OWNER","version":36},"setup":`+fixtureSetupJSON(t)+`,"state":{"current-profile-name":"PUBLIC_INITIAL"}}`)
}

func TestAndroidInitialTransactionCommitsOnceAndRejectsReplay(t *testing.T) {
	driver := &fixtureAndroidConfigDriver{}
	c := newAndroidConfigCoordinatorForTest(driver)
	mutation := initialTransactionFixture(t)
	var mu sync.Mutex
	var wg sync.WaitGroup
	results := make(chan androidOwnedConfigResult, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			mu.Lock()
			defer mu.Unlock()
			results <- c.commitLocked(androidConfigEpoch, 0, mutation)
		}()
	}
	wg.Wait()
	close(results)
	applied := 0
	for r := range results {
		if r.Outcome == androidConfigOutcomeApplied {
			applied++
		}
	}
	if applied != 1 || driver.initCall != 1 || driver.commitCall != 1 || c.lastApplied != 1 || c.stateGeneration != 1 || c.options == nil {
		t.Fatal("并发首次配置未保持单次初始化与提交")
	}
	if r := c.commitLocked(androidConfigEpoch, 1, mutation); r.ErrorCode != androidConfigErrorInitialOnly || driver.initCall != 1 {
		t.Fatal("已配置首次请求再次执行初始化")
	}
	if r := c.snapshotLocked(); r.Outcome != androidConfigOutcomeApplied || r.ConfigRevision != 1 || r.Options == nil {
		t.Fatal("丢失回执后的状态读取没有保留完成事实")
	}
}

func TestAndroidInitialTransactionPreflightAndEnteredFailures(t *testing.T) {
	for _, scenario := range []string{"identity", "revision", "listeners", "conflict", "overflow", "stateOverflow", "initializeError", "initializePanic", "reuse", "kind4"} {
		t.Run(scenario, func(t *testing.T) {
			d := &fixtureAndroidConfigDriver{}
			c := newAndroidConfigCoordinatorForTest(d)
			m := initialTransactionFixture(t)
			epoch, revision := androidConfigEpoch, int64(0)
			expected := androidConfigErrorNone
			switch scenario {
			case "identity":
				epoch++
				expected = androidConfigErrorStaleEpoch
			case "revision":
				revision++
				expected = androidConfigErrorStaleRevision
			case "listeners":
				d.listeners = true
				expected = androidConfigErrorLegacyListenerPresent
			case "conflict":
				d.initialized = true
				expected = androidConfigErrorInitializationConflict
			case "overflow":
				c.lastAttempted = math.MaxInt64
				expected = androidConfigErrorRevisionOverflow
			case "stateOverflow":
				c.stateGeneration = math.MaxInt64
				expected = androidConfigErrorRevisionOverflow
			case "initializeError":
				d.initErr = errors.New("公开初始化拒绝")
				expected = androidConfigErrorInitializeFailed
			case "initializePanic":
				d.panicAt = "initialize"
				expected = androidConfigErrorInitializeFailed
			case "reuse":
				d.initialized = true
				d.initHome, d.initVersion = "/PUBLIC_OWNER", 36
			case "kind4":
				m.kind = androidConfigKindInitialComposite
				expected = androidConfigErrorCoreNotInitialized
			}
			r := c.commitLocked(epoch, revision, m)
			if r.ErrorCode != expected {
				t.Fatal("首次事务错误分类不符")
			}
			if scenario == "initializeError" || scenario == "initializePanic" {
				if !r.Blocked || r.Phase != androidConfigPhaseEntered || r.AttemptedRevision != 1 || d.prepareCall != 0 {
					t.Fatal("初始化故障责任被清空")
				}
			} else if scenario == "reuse" {
				if r.Outcome != androidConfigOutcomeApplied || d.initCall != 0 || d.commitCall != 1 {
					t.Fatal("一致初始化没有无操作复用")
				}
			} else if r.Phase != androidConfigPhaseNotEntered || d.initCall != 0 || d.prepareCall != 0 {
				t.Fatal("纯校验拒绝执行了初始化")
			}
		})
	}
}

func TestAndroidInitialTransactionInvalidInputHasNoInitialization(t *testing.T) {
	for _, init := range []string{`null`, `{}`, `{"home-dir":"/PUBLIC_OWNER"}`, `{"home-dir":"relative","version":36}`, `{"home-dir":"/PUBLIC_OWNER","version":null}`, `{"home-dir":"/PUBLIC_OWNER","version":-1}`} {
		if _, code := decodeAndroidConfigMutation(androidConfigKindInitializeComposite, `{"init":`+init+`,"setup":{},"state":{}}`); code != androidConfigErrorInvalidPayload {
			t.Fatal("畸形初始化没有在纯校验阶段拒绝")
		}
	}
	d := &fixtureAndroidConfigDriver{}
	c := newAndroidConfigCoordinatorForTest(d)
	m := initialTransactionFixture(t)
	m.stateBytes = []byte(`{"only-statistics-proxy":"INVALID"}`)
	if r := c.commitLocked(androidConfigEpoch, 0, m); r.ErrorCode != androidConfigErrorInvalidPayload || d.initCall != 0 {
		t.Fatal("畸形状态在初始化后拒绝")
	}
}

func TestProductionAndroidInitialTransactionRejectsLegacyRunningFlag(t *testing.T) {
	withProductionAndroidConfigFixture(t)
	before := isRunning
	t.Cleanup(func() { isRunning = before })
	isRunning = true
	m := initialTransactionFixture(t)
	m.init = &InitParams{HomeDir: constant.Path.HomeDir(), Version: version}
	runLock.Lock()
	r := productionAndroidConfigCoordinator.commitLocked(androidConfigEpoch, 0, m)
	runLock.Unlock()
	if r.ErrorCode != androidConfigErrorLegacyListenerPresent || r.Phase != androidConfigPhaseNotEntered || productionAndroidConfigCoordinator.lastAttempted != 0 {
		t.Fatal("旧运行责任未在初始化前保留")
	}
}
