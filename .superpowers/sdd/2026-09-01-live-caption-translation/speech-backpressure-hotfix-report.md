# Speech analyzer backpressure hotfix report

## Status

Implemented bounded async backpressure for the SpeechAnalyzer input path. The ReplayKit ingress path retains its existing synchronous bounded/drop behavior, so sustained analyzer slowness still propagates pressure to the existing ingress queue rather than creating unbounded work.

## Root cause

`SpeechPipelineRuntime` synchronously fed a capacity-8 `AsyncStream` queue. `AsyncStream.Continuation.yield` returns `.dropped` as soon as `bufferingOldest` is full, so a transient SpeechAnalyzer scheduling delay became `SpeechPipelineError.analyzerInputDropped` and terminated the broadcast. The queue had no producer suspension or consumption feedback.

## Implementation

- Replaced the internal `AsyncStream` buffering implementation of `BoundedAsyncQueue` with a lock-protected bounded async sequence.
- Preserved synchronous `yield` for ReplayKit ingress: it still throws `.dropped` when capacity is unavailable.
- Added async `send`: full queues suspend senders, consumption resumes them FIFO, cancellation removes the exact waiter, and `finish()` terminates blocked/future sends while draining accepted values.
- `finish()` also resumes blocked consumers with end-of-sequence and remains idempotent.
- Made SpeechPipeline append and converter-tail drain await analyzer capacity one buffer at a time.
- Serialized async append and termination through the existing `AsyncSerialExecutor`, preventing actor reentrancy from overlapping converter work or starting tail drain before an accepted append completes.
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
- finish waiting for an active async append before converter-tail drain.

## Verification

Simulator destination: `7EC5843E-3F68-4EDF-874A-B87EFE0106B9`; all test commands used `-parallel-testing-enabled NO`.

```text
BroadcastAudioSupportTests + AudioPCMConverterTests:
Executed 16 tests, with 0 failures (0 unexpected)

Full LiveTranslateTests:
Executed 45 tests, with 0 failures (0 unexpected)

iphoneos LiveTranslateBroadcast build, CODE_SIGNING_ALLOWED=NO:
** BUILD SUCCEEDED **
```

## Scoped files

- `ios/LiveTranslate/Shared/BroadcastAudioSupport.swift`
- `ios/LiveTranslate/LiveTranslateBroadcast/SpeechPipeline.swift`
- `ios/LiveTranslate/LiveTranslateTests/BroadcastAudioSupportTests.swift`
- this report

The pre-existing uncommitted Team/project and AppIcon changes were neither modified intentionally nor staged.

## Remaining concern

Automated coverage validates channel semantics, serialization, simulator integration, and iphoneos compilation. A follow-up device run is still required to confirm the original long-running ReplayKit/SpeechAnalyzer workload no longer terminates with `analyzerInputDropped` under real device scheduling.
