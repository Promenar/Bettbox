//go:build android && cgo

package main

import "C"

//export getAndroidOwnedConfigStatus
func getAndroidOwnedConfigStatus() *C.char {
	return C.CString(getAndroidOwnedConfigStatusJSON())
}

//export commitAndroidOwnedConfig
func commitAndroidOwnedConfig(expectedEpoch C.longlong, expectedRevision C.longlong, kind C.int, payload *C.char) *C.char {
	payloadValue := ""
	if payload != nil {
		payloadValue = C.GoString(payload)
	}
	return C.CString(commitAndroidOwnedConfigJSON(
		int64(expectedEpoch),
		int64(expectedRevision),
		int(kind),
		payloadValue,
	))
}
