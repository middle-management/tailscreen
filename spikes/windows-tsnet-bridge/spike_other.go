//go:build !windows

// The spike only means anything on Windows. This file exists so the package
// still has a main() elsewhere — `go vet ./...` on a Linux dev box would
// otherwise fail with "build constraints exclude all Go files" rather than
// saying something useful.
package main

import "fmt"

func main() {
	fmt.Println("windows-tsnet-bridge is a Windows-only spike; build it with GOOS=windows.")
}
