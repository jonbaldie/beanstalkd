# Exploratory testing — beanstalkd

Date: 2026-09-12

Build and starting state

- Repository: `jonbaldie/beanstalkd`, commit `bebc2c3` (`v1.0.2`)
- Image: `jonbaldie/beanstalkd:latest`, built with `make build`
- Docker Server: 29.4.0 (OrbStack, aarch64)
- Service version from `stats`: beanstalkd 1.13
- The repository integration suite passed with `make test`.
- Live tests used fresh uniquely named containers and loopback-only random host ports. Temporary containers and named volumes were cleaned up after each run.

## Journeys exercised

### 1. Protocol parser and boundary fuzzing
Goal: systematically fuzz all protocol commands with valid, boundary, and malformed inputs:
- Numeric overflow (> UINT32_MAX, > UINT64_MAX, > INT32_MAX)
- Negative numeric values
- Trailing non-numeric garbage and unexpected extra arguments
- Delimiter boundaries (missing spaces, multiple spaces, tab characters)
- Tube name boundaries (1, 200, 201 chars, invalid characters, leading hyphens)
- Command line length boundaries (up to 224 bytes, 225 bytes, and oversized lines)
- Large job body payloads (65535 boundary vs 65536)

### 2. Runtime-instrumented execution
Goal: compile and run beanstalkd with AddressSanitizer and UndefinedBehaviorSanitizer to detect memory errors or undefined operations under malformed and edge-case inputs.

### 3. Stateful action sequences & property-based tests
Goal: verify state machine integrity:
- Priority queue ordering invariant
- Buried job FIFO kick ordering
- Zero-TTR automatic upward adjustment to 1 second
- Persistence recovery across container stop/recreate cycle

## Confirmed bugs

### 1. Beanstalkd accepts malformed `reserve-with-timeout` bounds and mutates the queue
Beanstalkd accepts malformed `reserve-with-timeout` arguments with trailing characters (e.g. `reserve-with-timeout 1garbage`, `reserve-with-timeout 0garbage`, `reserve-with-timeout 0 foo`) instead of returning `BAD_FORMAT`. When a job is ready in the queue, `reserve-with-timeout 1garbage\r\n` immediately reserves the job and mutates the queue (transitions job from Ready to Reserved), rather than rejecting the command and leaving the queue untouched.

Evidence: [2026-09-12-reserve-with-timeout-bound.txt](evidence/2026-09-12-reserve-with-timeout-bound.txt)

### 2. Beanstalkd hangs when command lines split `\r\n` across the 224-byte read buffer boundary
When a client sends a 225-byte command line (223 characters followed by `\r\n`), the `\r` lands at byte 224 (the exact `LINE_BUF_SIZE` boundary) and `\n` at byte 225. Beanstalkd discards the `\r`, fails to detect the line terminator on the next byte `\n`, and hangs indefinitely in `STATE_WANT_ENDLINE` waiting for a line terminator that was already transmitted. Subsequent commands on that connection are desynchronized.

Evidence: [2026-09-12-split-endline-hang.txt](evidence/2026-09-12-split-endline-hang.txt)

### 3. Beanstalkd accepts `pause-tube` commands without space delimiter
`pause-tubedefault 5\r\n` is accepted without a space delimiter between the command word and the tube argument. The tube `default` is paused for 5 seconds and the server replies `PAUSED\r\n` instead of returning `UNKNOWN_COMMAND\r\n`.

Evidence: [2026-09-12-pause-tube-delimiter.txt](evidence/2026-09-12-pause-tube-delimiter.txt)
