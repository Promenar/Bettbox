package androidstartup

// QuickStart 按顺序预检初始化和状态，仅预检成功后配置内核。
// 调用者只将返回值发送一次；此函数不发送回执，也不启动额外协程。
func QuickStart(init func() bool, setState func() error, setup func() string) string {
	if !init() {
		return "init error"
	}
	if err := setState(); err != nil {
		// 固定使用状态解析现有错误类别，不返回可能含输入的异常正文。
		return "客户端状态格式无效"
	}
	return setup()
}
