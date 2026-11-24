# rules_flutter_debug_agent

A Dart-only Flutter plugin that lets a script or a coding agent drive a running debug app: tap,
type, read text back, wait for a widget, press keys. Its plugin class registers
`ext.rules_flutter.*` service extensions before `main()`, on every launch and every hot restart,
in debug builds only. Nothing else talks to them: you call them through the stock `flutter`
tool's `--machine` protocol (`app.callServiceExtension`), or through any VM service client.

## Adding it

With Bazel, depend on it from the application, and name your app's `package:flutter` once in
`.bazelrc` (the agent imports Flutter, and Flutter comes from your pub hub):

```starlark
flutter_application(
    name = "app",
    deps = [
        "@rules_flutter//flutter/debug_agent",
        ...
    ],
    ...
)
```

```
# .bazelrc
build --@rules_flutter//flutter/debug_agent:flutter=@deps//:flutter
```

In a release or profile build its plugin class registers nothing. `e2e/stock_dev_loop` does
exactly this.

A project the stock tool resolves by itself takes it like any other package, as a dev dependency
with a `path:` to this directory or a `git:` dependency on the rules' repository
(`path: rules_flutter/flutter/debug_agent`).

## Driving an app from a script

Start the app with `flutter_dev` in machine mode, as an agent would, and keep it running for the
session:

```sh
bazel run @rules_flutter//tools/flutter_dev -- run --machine --bazel-target=//:app -d emulator-5554 \
  > /tmp/app.out 2> /tmp/app.err &
```

stdout is the stock tool's `--machine` protocol: one JSON array per line, `[{...}]`; any other line
is plain output. Requests go to the tool's stdin in the same shape. Wait for the `app.started`
event; the `appId` is in `app.start`, as is `deviceId`. `flutter_dev` holds `app.started` back
until its first hot restart is done, so the app runs the stock tool's compile from then on.

Every command is one request:

```json
[{"id":1,"method":"app.callServiceExtension","params":{"appId":"<appId>",
  "methodName":"ext.rules_flutter.tap","params":{"tooltip":"Increment"}}]
```

The reply is `{"id":1,"result":{...}}` with the command's fields in `result`, or
`{"id":1,"error":"<why>"}`. All parameter values are strings.

| Command | Parameters | Result |
|---|---|---|
| `ext.rules_flutter.tap`, `longPress`, `doubleTap` | a selector, or `x` and `y`; `pointer: "mouse"`; `requireHit` | `settled` |
| `ext.rules_flutter.drag` | a selector or `x`, `y`; `dx`, `dy`, `durationMs` | `settled` |
| `ext.rules_flutter.hover`, `hoverExit` | a selector or `x`, `y` (hover) | `cursor` |
| `ext.rules_flutter.enterText` | `text`; optionally a selector (not `text`), else the focused field | `enteredText`, `into` |
| `ext.rules_flutter.pressKey` | `code` (a DOM `KeyboardEvent.code`: `KeyA`, `Enter`, `ArrowDown`, `Tab`), `modifiers` (comma-separated codes: `ControlLeft`, `ShiftLeft`, `MetaLeft`, `AltLeft`), `text` (what the key types) | `handled`, `sent`, `textInput` |
| `ext.rules_flutter.getText` | a selector | `text`, `texts` |
| `ext.rules_flutter.getRect` | a selector | the rect in logical pixels |
| `ext.rules_flutter.waitFor`, `waitForAbsent` | a selector; `timeoutMs` (default 5000) | |
| `ext.rules_flutter.scrollIntoView` | a selector; `scrollableKey`, `dx`, `dy` | `reachable`, `iterations` |
| `ext.rules_flutter.pageBack` | | `popped` |
| `ext.rules_flutter.settle` | `timeoutMs` | `settled` |
| `ext.rules_flutter.setWindowActive` | `active`: `"true"` or `"false"` | `lifecycleState` |
| `ext.rules_flutter.renderState` | `timeoutMs` | `firstFrameBuilt`, `rendering`, `lifecycleState` |

A selector is exactly one of `key` (a `ValueKey<String>`'s value), `text` (the text a widget
shows), `tooltip`, `type` (the widget's runtime type name) or `semanticsLabel`. Put the key on the
widget you would point at, the button rather than its label. Input commands wait until the app is
idle before they answer (`timeoutMs`, default 10000) and say how that ended in `settled`: `yes`,
`no` (with `settleDetail`) or `skipped`. An app that animates forever never settles: pass
`"settle": "false"` and resynchronise with `waitFor`. A pointer command refuses a point that would
not reach the widget (scrolled away, covered); `scrollIntoView` first.

The rest is the stock protocol itself:

| What | Request |
|---|---|
| Hot reload | `app.restart` with `"fullRestart": false` |
| Hot restart | `app.restart` with `"fullRestart": true` |
| The widget tree | `app.callServiceExtension` with `ext.flutter.inspector.getRootWidgetTree` and `{"groupName":"agent","isSummaryTree":"true","withPreviews":"true"}` |
| A screenshot | `device.takeScreenshot` with `{"deviceId":"<deviceId>"}`: the PNG, base64-encoded, on Android and iOS (the stock tool has none for desktop devices) |
| The app's output | the `app.log` events |
| Stop | `app.stop` with the `appId`, then `daemon.shutdown` |

`//tools/flutter_dev:agent_e2e` is a complete client: it runs every command above against
`e2e/stock_dev_loop`, before and after a hot restart and a hot reload.

For a coding agent, put the routine in the file it reads at startup (`CLAUDE.md`, `AGENTS.md`):
start the app once in the background; after an edit, hot reload with `app.restart` and read
`code` (0 is success) from the reply; check what changed with `getText` or a screenshot rather
than trusting the code; read the `app.log` events for exceptions; stop the app at the end.
