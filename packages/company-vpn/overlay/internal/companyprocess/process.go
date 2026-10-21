package companyprocess

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
)

type Process struct { Name, Path, Fingerprint, Platform string }
var once sync.Once
var current Process

// Describe the actual test executable. Do not impersonate Chrome/SSH or
// assert an application/device trust verdict the test cannot establish.
func Current() Process {
	once.Do(func() {
		current.Path, _ = os.Executable()
		current.Name = filepath.Base(current.Path)
		current.Platform = runtime.GOOS
		if current.Platform == "darwin" { current.Platform = "macOS" }
		if data, err := os.ReadFile(current.Path); err == nil { current.Fingerprint = fmt.Sprintf("%X", sha256.Sum256(data)) }
	})
	return current
}
