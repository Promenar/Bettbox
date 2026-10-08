package androidstartup

import "errors"

// ConfirmJNIRelease 只接受已确认删除及任务线程收尾的精确成功状态。
func ConfirmJNIRelease(code int) error {
	if code != 1 {
		return errors.New("JNI引用释放未确认")
	}
	return nil
}
