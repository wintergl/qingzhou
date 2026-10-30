package companyprocess

import (
	"crypto/sha256"
	"fmt"
	"io"
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
		if file, err := os.Open(current.Path); err == nil {
			hash := sha256.New()
			if _, err = io.Copy(hash, file); err == nil { current.Fingerprint = fmt.Sprintf("%X", hash.Sum(nil)) }
			_ = file.Close()
		}
	})
	return current
}

func AuthPlatform() string {
	switch runtime.GOOS {
	case "darwin": return "Mac"
	case "ios": return "iOS"
	case "android": return "Android"
	case "windows": return "Windows"
	default: return "Linux"
	}
}
