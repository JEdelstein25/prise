# Server Architecture

1. **Main Thread**: Accepts connections and handles IPC requests, responses, and
   notifications. It checks each PTY and sends screen updates to connected
clients. It also writes to each PTY as needed (keyboard, mouse, etc).
2. **PTY Threads**: Each PTY runs in its own thread. This thread does blocking
   reads from the underlying PTY and processes VT sequences, persisting local
state. It also handles automatic responses to certain VT queries (e.g. Device
Attributes) by writing directly to the PTY.
3. **Event-Oriented Frame Scheduler**:
   - **Per-Pty Pipe**: Each `Pty` owns a non-blocking pipe pair. The
   read end is registered with the main thread's event loop; the write end is
   used by the PTY thread.
   - **Producer (PTY Thread)**: After updating the terminal state, it writes a
   single byte to the pipe. `EAGAIN` is ignored (signal already pending).
   - **Consumer (Main Thread)**:
     - **On Signal**: Drains the pipe. If enough time has passed since
     `last_render_time`, renders immediately. Otherwise, if no timer is pending,
     schedules one for the remaining duration.
     - **On Timer**: Renders immediately and updates `last_render_time`.
