package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"testing"
)

func TestProductionAndroidRuntimeEpochIsNotFixedIdentity(t *testing.T) {
	if androidConfigEpoch <= 1 || androidConfigEpoch > androidRuntimeEpochMax {
		t.Fatal("生产实例身份未满足非固定的精确整数合同")
	}
	var first, second androidOwnedConfigResult
	if err := json.Unmarshal([]byte(getAndroidOwnedConfigStatusJSON()), &first); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(getAndroidOwnedConfigStatusJSON()), &second); err != nil {
		t.Fatal(err)
	}
	if first.Epoch != androidConfigEpoch || second.Epoch != first.Epoch {
		t.Fatal("同一运行时状态读取改变实例身份")
	}
}

func TestAndroidRuntimeEpochReaderRangeAndFailure(t *testing.T) {
	for _, value := range []uint64{2, uint64(androidRuntimeEpochMax), ^uint64(0)} {
		t.Run(fmt.Sprint(value), func(t *testing.T) {
			var input [8]byte
			binary.BigEndian.PutUint64(input[:], value)
			epoch, err := readAndroidRuntimeEpoch(bytes.NewReader(input[:]))
			if err != nil || epoch <= 1 || epoch > androidRuntimeEpochMax {
				t.Fatal("实例身份超出精确整数合同")
			}
		})
	}
	for _, input := range [][]byte{nil, {1}, make([]byte, 64)} {
		epoch, err := readAndroidRuntimeEpoch(bytes.NewReader(input))
		if err == nil || epoch != 0 {
			t.Fatal("失败或无效熵不得降级发行身份")
		}
	}
	var valid [8]byte
	binary.BigEndian.PutUint64(valid[:], 2)
	retry := append(make([]byte, 8), valid[:]...)
	if epoch, err := readAndroidRuntimeEpoch(bytes.NewReader(retry)); err != nil || epoch != 2 {
		t.Fatal("保留值应重新读取身份")
	}
}

func TestAndroidRuntimeEpochMissingIdentityAbortsInitialization(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("身份失败后继续初始化")
		}
	}()
	mustAndroidRuntimeEpoch(bytes.NewReader(nil))
}

func TestAndroidRuntimeEpochRejectsOtherInstanceBeforeStateMutation(t *testing.T) {
	oldDriver := &fixtureAndroidConfigDriver{initialized: true}
	newDriver := &fixtureAndroidConfigDriver{initialized: true}
	old := newAndroidConfigCoordinatorForTest(oldDriver)
	current := newAndroidConfigCoordinatorForTest(newDriver)
	old.epoch, current.epoch = 101, 202
	mutation := fixtureMutation(t, androidConfigKindState, `{"current-profile-name":"PUBLIC_OLD_INSTANCE"}`)
	if old.commitLocked(old.epoch, 0, mutation).Outcome != androidConfigOutcomeStaged {
		t.Fatal("旧实例夹具未接受状态")
	}
	rejected := current.commitLocked(old.epoch, 0, mutation)
	if rejected.Outcome != androidConfigOutcomeRejected || rejected.ErrorCode != androidConfigErrorStaleEpoch ||
		rejected.Epoch != current.epoch || current.hasDesiredState || current.stateGeneration != 0 || newDriver.stateCall != 0 {
		t.Fatal("旧实例请求污染新实例状态")
	}
	if current.commitLocked(current.epoch, 0, fixtureMutation(t, androidConfigKindState, `{}`)).Outcome != androidConfigOutcomeStaged {
		t.Fatal("当前实例请求遭到误拒")
	}
}
