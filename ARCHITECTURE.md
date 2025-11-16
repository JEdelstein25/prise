# Server Architecture

1. **Main Thread**: Accepts connections and handles IPC requests, responses, and
   notifications. It checks each PTY and sends screen updates to connected
clients. It also writes to each PTY as needed (keyboard, mouse, etc).
2. **PTY Threads**: Each PTY runs in its own thread. This thread does blocking
   reads from the underlying PTY and processes VT sequences, persisting local
state. It also handles automatic responses to certain VT queries (e.g. Device
Attributes) by writing directly to the PTY.
