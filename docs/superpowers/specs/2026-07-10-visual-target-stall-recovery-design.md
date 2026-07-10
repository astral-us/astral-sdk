# Visual Target Stall Recovery

## Problem

During a visual navigation mission, the app projects the first matching camera detection into a fixed world goal. If the target later leaves the camera view and the rover cannot make progress, `NavigationController` remains in `.driving` indefinitely and the Talk screen remains at `On it...`.

The device log also shows path-following in-place turns using wheel speeds near `0.10`, below the configured `0.25` minimum that reliably overcomes the WAVE ROVER's static friction.

## Behavior

- Continue normal navigation while the visual target is visible or the rover is making measurable progress.
- Apply the configured minimum rotate wheel speed to in-place turns produced by the path follower.
- Detect a stalled drive when commanded movement produces neither meaningful translation nor yaw change for approximately two seconds.
- For a stalled visual-target mission, cancel the stale fixed goal and use the existing visual scan routine.
- Scan in alternating 30-degree steps, pausing after each step so camera detection can update.
- Resume navigation from a newly detected target with confidence at or above 90 percent.
- If all scan steps are exhausted, stop the mission and return the UI to Ready instead of remaining in `On it...`.

## Boundaries

`NavigationController` owns generic movement-progress detection and reports a failed stalled state. `MissionAgent` owns visual-target recovery: it recognizes that failure, invokes target scanning, and either resumes with a fresh goal or ends the mission. `PursuitController` owns generation of a wheel command strong enough for in-place rotation.

This change does not treat every single missed camera frame as target loss. Detection may briefly disappear during ordinary turns, so scanning begins only after navigation is demonstrably stalled.

## Testing

- A path-following unit test verifies in-place wheel commands respect the minimum rotation speed.
- A navigation-controller test verifies no-progress movement transitions out of `.driving` with a stalled failure.
- A mission-agent test verifies a stalled visual mission performs alternating scan turns, reacquires the target, and resumes navigation.
- Existing visual scan, stop-command, obstacle, and communication tests remain green.
