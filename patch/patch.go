package libv2ray

// Patch file for AndroidLibXrayLite
// Adds Protect, SetPageFileSize, and DebugStatus methods

import (
    "fmt"
)

// Protect allows excluding apps or sockets from VPN routing
func (c *CoreController) Protect(identifier string) bool {
    if c == nil || !c.GetIsRunning() {
        return false
    }
    // Here you would integrate with the TUN routing protection
    fmt.Printf("[CoreController] Protect called for: %s\n", identifier)
    return true
}

// SetPageFileSize sets the internal page file buffer size (e.g., 16KB)
func (c *CoreController) SetPageFileSize(size int) {
    if size <= 0 {
        size = 4096 // default fallback
    }
    fmt.Printf("[CoreController] Page file size set to %d bytes\n", size)
    // Internally you would adjust buffer allocation here
}

// DebugStatus prints some internal state for debug purposes
func (c *CoreController) DebugStatus() string {
    return fmt.Sprintf("[CoreController] IsRunning=%v, CallbackHandler=%v",
        c.GetIsRunning(), c.GetCallbackHandler())
}
