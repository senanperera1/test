package libv2ray

import (
	"fmt"
	"sync"
)

// Protect function placeholder
func Protect() {
	// Implement actual protection logic here
	fmt.Println("Protect function called: core secured")
}

// CoreController struct with methods
type CoreController struct {
	mu       sync.Mutex
	running  bool
	callback CoreCallbackHandler
}

// CoreCallbackHandler interface
type CoreCallbackHandler interface {
	OnStatus(msg string)
	OnStartup()
	OnShutdown()
}

// NewCoreController creates a new controller instance
func NewCoreController(cb CoreCallbackHandler) *CoreController {
	return &CoreController{
		callback: cb,
		running:  false,
	}
}

// StartCore simulates starting the core
func (c *CoreController) StartCore(config string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.running = true
	if c.callback != nil {
		c.callback.OnStartup()
	}
	fmt.Println("Core started with config:", config)
}

// StopCore simulates stopping the core
func (c *CoreController) StopCore() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.running = false
	if c.callback != nil {
		c.callback.OnShutdown()
	}
	fmt.Println("Core stopped")
}

// QueryStats simulates returning stats
func (c *CoreController) QueryStats(key string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return fmt.Sprintf("Stats for %s: 0", key)
}

// MeasureDelay simulates delay measurement
func (c *CoreController) MeasureDelay(target string) int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	// return a dummy delay
	return 42
}

// SetCallback sets the callback handler
func (c *CoreController) SetCallback(cb CoreCallbackHandler) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.callback = cb
}

// IsRunning returns whether the core is running
func (c *CoreController) IsRunning() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.running
}

// Page file simulation: 16KB buffer for Android 15+
var PageFile = make([]byte, 16*1024)
