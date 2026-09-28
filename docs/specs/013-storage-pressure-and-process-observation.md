# 013 Storage Pressure and Process Observation

Protect the Mac when the Data volume is nearly full and make swap growth or
detached compiler work visible without unsafe automatic process termination.

## Scope

- Read `/System/Volumes/Data` usage during every five-minute health check.
- Enter guarded cleanup below the configured free-space threshold (default 20 GiB).
- Allow users to view and change the threshold in whole GiB without restarting
  monitoring; invalid or unreadable settings stop pressure-triggered cleanup.
- Reuse the existing fail-closed build cleanup categories and retention rules.
- Apply the configured cleanup cooldown (default one hour) and clear the pressure state after recovery.
- Read global macOS swap usage and correlate sustained growth with the largest
  observed application RSS values.
- Observe current-user `cargo`, `rustc`, `clang`, `cmake`, `ninja`, `make`,
  `xcodebuild`, and `xctest` processes whose parent is PID 1.
- Notify after the configured number of spaced observations (default three).
- Store process identity and measurements, never command-line arguments.

## Safety boundaries

- The threshold never authorizes arbitrary path deletion.
- Active or unverifiable build output remains protected by the existing cleanup
  rules.
- Swap is global; a related RSS process is not declared the cause of swap.
- Detached build alerts do not stop processes.
- `StorageManagementService`, `ApplicationsStorageExtension`, `WindowServer`,
  `kernel_task`, and other system processes remain observation-only.
- User-confirmed process actions are a separate future feature and must
  revalidate the exact PID and process group immediately before acting.

## Acceptance scenarios

### BDD-01 Trigger guarded cleanup

Given the Data volume has less space available than the configured threshold
and the existing cleanup lock is available,

When a full health check runs,

Then canaryd runs the existing guarded build cleanup, records reclaimed bytes
and skip reasons, and never broadens cleanup to arbitrary caches or source.

### BDD-02 Avoid repeated cleanup

Given a pressure-triggered cleanup has just completed,

When later checks still observe pressure,

Then canaryd does not start another cleanup during the configured cooldown
(one hour by default), including when free space briefly recovers and drops
below the threshold again.

### BDD-03 Report sustained swap growth

Given global swap is at least 2 GB and grows by at least 512 MB across three
five-minute observations,

When the application memory scan is available,

Then canaryd sends one warning listing related high-RSS applications while
stating that the list is not proof of causation.

### BDD-04 Report detached build processes

Given a current-user compiler process has parent PID 1,

When it remains present across three five-minute observations,

Then canaryd sends a warning with its tool name and PID and does not terminate
it or remove its active build output.

### BDD-05 Change the cleanup threshold

Given the default threshold is 20 GiB,

When the user sets `canaryd config storage-threshold 30G`,

Then subsequent health checks use 30 GiB for warnings, cleanup entry, and
recovery without restarting the launchd jobs. Invalid or unreadable settings
prevent pressure-triggered cleanup until corrected.
