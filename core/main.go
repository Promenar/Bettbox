//go:build !cgo

package main

import (
	"fmt"
	"os"
)

func main() {
	args := os.Args
	if len(args) <= 1 {
		fmt.Println("Arguments error")
		os.Exit(1)
	}
	if args[1] == "--owned-pipe-v1" {
		if len(args) != 2 {
			os.Exit(1)
		}
		if err := runOwnedPipe(); err != nil {
			os.Exit(1)
		}
		return
	}
	startServer(args[1])
}
