# Speech analyzer backpressure hotfix report

## Status

Implemented bounded async backpressure for the SpeechAnalyzer input path. The ReplayKit ingress path retains its existing synchronous bounded/drop behavior, so sustained analyzer slowness still propagates pressure to the existing ingress queue rather than creating unbounded work. Fix Round 1 makes termination close a blocked analyzer input before waiting for active append work. Fix Round 2 separates the analyzer's regular capacity from a bounded converter-tail reserve, so graceful finish can preserve every possible converter tail buffer even when the regular queue is full.

## Root cause

`SpeechPipelineRuntime` synchronously fed a capacity-8 `AsyncStream` queue. `AsyncStream.Continuation.yield` returns `.dropped` as soon as `bufferingOldest` is full, so a transient SpeechAnalyzer scheduling delay became `SpeechPipelineError.analyzerInputDropped` and terminated the broadcast. The queue had no producer suspension or consumption feedback. After Round 1 added async regular sends, graceful finish still synchronously placed converter tail into the same eight slots. A momentarily full regular queue therefore rejected tail immediately even though `AudioPCMConverter.finish()` has a finite, known maximum of 32 output buffers.

## Implementation

- Replaced the internal `AsyncStream` buffering implementation of `BoundedAsyncQueue` with a lock-protected bounded async sequence.
- Preserved synchronous `yield` for ReplayKit ingress: it still throws `.dropped` when capacity is unavailable.
- Added async `send`: full queues suspend senders, consumption resumes them FIFO, cancellation removes the exact waiter, and `finish()` terminates blocked/future sends while draining accepted values.
- `finish()` also resumes blocked consumers with end-of-sequence and remains idempotent.
- Made SpeechPipeline append await analyzer capacity one buffer at a time.
- Defined the converter's maximum tail output count once as `AudioPCMConverter.maximumTailOutputBufferCount = 32` and reused it as the finish-loop bound.
- Split SpeechAnalyzer buffering into regular capacity 8 and converter-tail reserve 32. Regular async sends cannot enter the reserve; tail drain uses bounded synchronous reserved yields. Total buffered capacity is therefore bounded at 40.
- Consumption promotes a blocked regular sender only after occupancy falls below the regular capacity, so regular traffic cannot invade tail reserve through the consumer path.
- Serialized converter work through the existing `AsyncSerialExecutor`. When finish observes active or pending append work, it closes analyzer input immediately to wake blocked sends, then waits for serialized append work to exit before analyzer cleanup. With no append in flight, normal tail drain still runs before input finish.
- Preserved analyzer finalization order and primary-error handling. Known queue errors still map to localized `SpeechPipelineError` cases.

## TDD evidence

Initial focused RED:

```text
Value of type 'BoundedAsyncQueue<Int>' has no member 'send'
** TEST FAILED **
```

Lifecycle RED after adding the async append/finish ordering test:

```text
Type 'ControlledSpeechPipelineOperations' does not conform to protocol 'SpeechPipelineLifecycleOperations'
candidate is 'async', but protocol requirement is not
** TEST FAILED **
```

Blocked-consumer mutation RED (consumer wake temporarily removed, then restored):

```text
SWIFT TASK CONTINUATION MISUSE: next() leaked its continuation without resuming it.
Asynchronous wait failed: Exceeded timeout of 1 seconds, with unfulfilled expectations: "next finished".
```

Focused GREEN after implementation:

```text
Executed 14 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

Focused tests cover:

- send suspension until capacity is released;
- FIFO producer resumption;
- finish termination of blocked/future sends plus accepted-element drain;
- finish wake-up of a blocked consumer;
- blocked-send cancellation without capacity leakage;
- finish closing analyzer input before waiting for an active async append;
- cleanup after an injected converter-tail drain failure.

## Fix Round 1 evidence

The queue-ordering, finish, and cancellation tests first replaced scheduler guesses with an exact callback emitted only after a sender enters the pending-sender list. The test-first compile failed before the callback existed:

```text
xcodebuild \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,id=7EC5843E-3F68-4EDF-874A-B87EFE0106B9' \
  -parallel-testing-enabled NO \
  -only-testing:LiveTranslateTests/BroadcastAudioSupportTests \
  test

error: extra argument 'onSendSuspended' in call
** TEST FAILED **
```

After the minimal suspension observer was added, the unchanged focused suite passed 14/14. The active-append termination regression was then added. Before the lifecycle fix, the same focused command produced the expected behavioral RED:

```text
Asynchronous wait failed: Exceeded timeout of 1 seconds, with unfulfilled expectations: "finish input observed".
Executed 15 tests, with 3 failures (0 unexpected)
** TEST FAILED **
```

After tracking pending append work, finishing analyzer input early, and making tail drain bounded and synchronous, the same focused command was GREEN:

```text
Executed 15 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

## Fix Round 2 evidence

The new reserve contract was introduced test-first. Before the shared limits and reserved-capacity API existed, the focused suite failed to compile:

```text
cannot find 'SpeechAnalyzerInputBufferLimits' in scope
extra argument 'reservedCapacity' in call
** TEST FAILED **
```

The tests require all of the following:

- regular async sends remain limited to eight values and cannot use tail reserve;
- 32 reserved tail values fit behind eight regular values, preserving FIFO and the total bound of 40;
- consuming a value while reserve remains occupied does not promote a blocked regular sender early;
- graceful finish preserves all 32 tail values when the regular eight-slot capacity is full;
- the Round 1 active-append termination path still closes input before waiting and skips tail drain.

As a mutation check, restoring the old unconditional sender promotion produced the expected behavioral RED:

```text
A regular send must remain blocked while tail reserve is occupied
Executed 1 test, with 1 failure
** TEST FAILED **
```

After restoring the regular-capacity promotion gate, the focused suite was GREEN:

```text
Executed 18 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

## Verification

Simulator destination: `7EC5843E-3F68-4EDF-874A-B87EFE0106B9`; all test commands used `-parallel-testing-enabled NO`.

```text
BroadcastAudioSupportTests + AudioPCMConverterTests:
Executed 20 tests, with 0 failures (0 unexpected)

Full LiveTranslateTests:
Executed 49 tests, with 0 failures (0 unexpected)

iphoneos LiveTranslateBroadcast build, CODE_SIGNING_ALLOWED=NO:
** BUILD SUCCEEDED **
```

## Scoped files

- `ios/LiveTranslate/Shared/BroadcastAudioSupport.swift`
- `ios/LiveTranslate/Shared/AudioPCMConverter.swift`
- `ios/LiveTranslate/LiveTranslateBroadcast/SpeechPipeline.swift`
- `ios/LiveTranslate/LiveTranslateTests/BroadcastAudioSupportTests.swift`
- this report

The pre-existing uncommitted Team/project and AppIcon changes were neither modified intentionally nor staged.

## Remaining concern

Automated coverage validates channel semantics, serialization, simulator integration, and iphoneos compilation. A follow-up device run is still required to confirm the original long-running ReplayKit/SpeechAnalyzer workload no longer terminates with `analyzerInputDropped` under real device scheduling.
