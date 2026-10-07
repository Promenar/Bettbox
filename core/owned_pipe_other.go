//go:build !darwin && !cgo

package main

// 非Darwin平台拒绝专用入口，既有UDS/TCP入口不变。
func runOwnedPipe() error { return errOwnedPipe }
