import Foundation

func printUsage() {
    print("""
    capture-harness — ScreenCaptureKit dual-track audio capture feasibility harness

    Usage:
      capture-harness record --bundle-id <id> | --all-system-audio [options]
      capture-harness inspect <timeline.jsonl> [--json]
      capture-harness probe-filter [options]
      capture-harness probe-interruptions [options]
      capture-harness fixture --scenario <name> --id <name> --devices "<hardware>" [options]
      capture-harness devices
      capture-harness permissions [--request]

    record options:
      --bundle-id <id>            Capture one running application's audio, resolved to its
                                  current process at start. Fails if it is not running.
      --all-system-audio          Capture every application's audio instead.
      --microphone-uid <uid>      Microphone to capture; defaults to the system input.
      --output <dir>              Session directory (default ./captures/<timestamp>).
      --duration <seconds>        Recording length; 0 runs until Ctrl-C (default 300).
      --sample-rate <hz>          System audio sample rate (default 48000).
      --channels <n>              System audio channel count (default 2).
      --screen-consumer none|minimal
                                  none registers no .screen output (default). minimal
                                  registers a 2x2, 1 fps output whose frames are discarded.
      --no-screen-fallback        Do not retry with a minimal screen output when no audio
                                  arrives without one.
      --start-timeout <seconds>   How long to wait for the first buffer (default 15).
      --segment-seconds <n>       Rotate CAF segments on this interval; 0 rotates only on a
                                  format change (default 0).
      --cpu-sample-seconds <n>    Resource sampling interval (default 5).
      --watch-process <name>      Additional process to sample CPU for (default replayd).

    probe-filter options:
      --targets <list>            Comma-separated application families to probe
                                  (zoom, safari, chrome, teams). Defaults to all four.
      --seconds <n>               Capture length per filter variant (default 20).
      --enumerate-only            List processes and filterable identifiers, capture nothing.
      --microphone-uid <uid>      Microphone to capture during the variants.
      --output <dir>              Probe directory (default ./captures/filter-probe <stamp>).

    probe-interruptions options:
      --bundle-id <id> | --all-system-audio
                                  Source to capture, as for record.
      --duration <seconds>        Run length (default 900).
      --microphone-uid <uid>      Microphone to capture.
      --output <dir>              Probe directory.

    fixture options:
      --scenario <name>           far-end-only, near-end-only, or double-talk.
      --id <name>                 Fixture directory name, e.g. usb-double-talk.
      --devices "<hardware>"      Playback and microphone hardware under test. Required.
      --bundle-id <id> | --all-system-audio
                                  Source to capture, as for record.
      --seconds <n>               Take length (default 15).
      --lead-in <n>               Countdown before recording starts (default 5).
      --format wav|flac           Committed file format (default wav, 16-bit).
      --fixtures-dir <dir>        Default Tests/Fixtures/real.
      --notes "<text>"            Free-text note stored in fixture.json.

    Screen frames are never saved. Microphone buffers arrive in the device's native format,
    independently of the system audio configuration.
    """)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "record":
    exit(await RecordCommand.run(Array(arguments.dropFirst())))
case "inspect":
    exit(InspectCommand.run(Array(arguments.dropFirst())))
case "probe-filter":
    exit(await ProbeFilterCommand.run(Array(arguments.dropFirst())))
case "probe-interruptions":
    exit(await ProbeInterruptionsCommand.run(Array(arguments.dropFirst())))
case "fixture":
    exit(await FixtureCommand.run(Array(arguments.dropFirst())))
case "devices":
    exit(await DevicesCommand.run())
case "permissions":
    exit(await PermissionsCommand.run(request: arguments.contains("--request")))
default:
    printUsage()
    exit(64)
}
