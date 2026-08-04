# WinNotifyKit

Desktop notifications on Windows, via the Windows App SDK's
`AppNotificationManager`. What `Packages/GNotifyKit` is on Linux and
`UNUserNotificationCenter` is on macOS.

## Why this exists

During a share, the app window is **behind the thing being shared**, and raising
it is itself visible to viewers. So every mid-share ask costs an interruption
the people watching can see.

Worse: "Require approval for new viewers" defaults **on**. A sharer who is not
looking at the app silently strands whoever tries to connect — nothing on screen
changes, and the viewer sits on a "waiting for approval" placard indefinitely.
A notification is the only surface that reaches somebody whose attention is on
the thing they are sharing.

## The split

| Where | What |
|---|---|
| `TailscreenProtocol` (`SharerNotice`) | *what* to say, *when*, how to dedupe, when to withdraw |
| `TailscreenProtocol` (`WindowsToastPayload`) | the toast XML, the activation string, the tag |
| this package | delivery only |

The middle row is the one that differs from Linux. On freedesktop a
notification is a method call with eight arguments; on Windows it is **one XML
document** handed to `AppNotification`, so composing that document correctly
*is* the delivery-shaped decision — and a document is a string, which is
testable on Linux CI with no Windows anywhere. That is why it lives in the
portable tier beside `WindowsHotkeyMapping` and `WindowsPointerMapping` rather
than in the shim.

## Why a C shim

Because **swift-winui does not project this API**. Its Swift surface covers
`Microsoft.UI.*` and `Microsoft.Windows.AppLifecycle`, but there is no
`AppNotificationManager` and no `ToastNotificationManager` in it. What it does
ship is the C ABI header —
`Sources/CWinRT/include/Microsoft.Windows.AppNotifications.h`, 1157 lines with
the vtables — and the shim is transcribed from that rather than from memory.

Only the **posting** half needs it — almost. A press comes back through
`AppInstance.Activated` and `ExtendedActivationKind.appNotification`, both
projected, so there is no COM handler object here, no event token and no
`ITypedEventHandler` — which is most of why this shim is 500 lines rather than
900. The last step is the exception: the event's `data` is an
`AppNotificationActivatedEventArgs`, from the same unprojected namespace, so it
arrives as an untyped `IInspectable` and the string saying *which button, about
whom* sits behind a `QueryInterface` Swift cannot spell.
`ts_winnotify_activation_argument` is that one call, and
`WindowsNotifier.decodeAction(fromActivationData:)` is its Swift face. The host
hands it `IUnknown.pUnk.borrow`, which swift-winui exposes publicly.

The IIDs are the one thing the header could not supply: it *declares* them
(`EXTERN_C const IID IID___x_ABI_…`) and leaves them to be resolved from the
Windows App SDK's own libraries, which this package does not link. They were
read out of the `GuidAttribute` rows of
`lib/uap10.0/Microsoft.Windows.AppNotifications.winmd` in
Microsoft.WindowsAppSDK **1.5.250108004** — the same package and the same
version `scripts/windows/stage-winappsdk.sh` stages. The ten interfaces in that
winmd are exactly the ten in swift-winui's header, name for name, which is the
cross-check that they were read correctly.

## The packaging fork, settled at runtime

`AppNotificationManager` works unpackaged, but needs `Register()` plus a COM
activator; from the MSIX it is simpler. We ship both a zip and an MSIX, and the
plan left it open whether both paths work or the zip knowingly ships without
toasts.

**Neither, as a build-time choice.** The shim calls `Register()` and reports
whether it succeeded; `init?` returns nil when it did not, and the host degrades
to its in-window prompts. That is not a compromise between the two answers — it
is the shape `DesktopNotifier.init?` already has on Linux, where no session bus
and no daemon are *normal* states rather than errors. A zip install that cannot
register is the same kind of fact as a desktop with no notification daemon.

One code path, no build flag, and the machine says so on the machine rather than
in the release notes.

**Expect the zip to land there today.** `stage-winappsdk.sh` follows Microsoft's
self-contained allowlist, which deliberately omits the Singleton package — and
the Singleton is exactly what the notification and push APIs need. So the
unpackaged build is likely to report "not registered" until that changes, which
is a deployment question, not a code one, and the honest answer on screen is
already wired.

## The three things that bite

1. **A daemon-shaped assumption does not transfer: nothing here fails loudly.**
   An unescaped `&` in a peer's hostname makes the payload fail to parse and
   posts nothing *for that peer only*. An over-64-character tag is refused
   rather than truncated, so both the post and the later withdraw silently miss.
   `scenario="urgent"` on Windows 10 is a schema violation, not an ignored hint.
   Three different mistakes, one symptom: the toast that never appeared, on
   somebody else's machine. All three are pinned by `WindowsToastPayloadTests`.
2. **`AppNotificationSetting` is the read-back, and posting succeeds without
   it.** A user who turned notifications off still gets a successful `Show` —
   the toast just goes nowhere. `canBeSeen` is the Windows equivalent of macOS's
   `getNotificationSettings` and Linux's `GetCapabilities`, and a host that does
   not ask is a host whose approval prompts quietly stop arriving. It is re-read
   on every access, because a user can turn them off mid-share.
3. **A notice's life is tied to the thing it is about.** A banner reading
   "someone is waiting to be let in", with an Accept button, is actively wrong
   once they have been admitted from the app window. `withdraw` is why that
   method is part of the API rather than a detail left to expiry — and the tag
   it takes is a pure function of the identity, folded through FNV-1a rather
   than `Hasher`, which is salted per launch and would never withdraw what the
   previous run left on screen.

`init?` returning nil is a **normal state**, not an error to report. The host
keeps its in-window prompts and says nothing.

## What is proven

| Claim | Proven by | Where |
|---|---|---|
| the payload escapes what would make it unparseable | `WindowsToastPayloadTests` | Linux CI (`linux-notify`) |
| the tag never exceeds 64 chars, and collides on nothing | Same | Linux CI |
| the tag is stable across process launches | Same — pinned as a literal digest | Linux CI |
| a button press round-trips through the activation string | Same | Linux CI |
| Windows 10 downgrades `urgent` instead of posting nothing | Same + `WindowsNotifierTests` | Linux CI |
| only mid-share asks get urgency and high priority | `WindowsNotifierTests` | Linux CI |
| an unregistered notifier degrades quietly | Same | Linux CI |
| a toast body click is not read as a denial | `SharerNoticeTextTests` (`action(forKey:)`) | Linux CI |
| a press routes back to the right kind AND peer | `SharerNoticeTests` (`decodeID`) | Linux CI |
| the app **compiles** with the wiring in | `swift build --package-path Apps/windows` | Linux CI (`linux-app`) |
| the package **links** against runtimeobject/user32 | `winnotify-probe` | Windows CI |
| `Register()` is reached and answers | `winnotify-probe` (run, not just built) | Windows CI |
| a real toast is **posted, seen, or pressed** | **nothing** | — |
| what any of it LOOKS like | **nothing** | — |

**The last two rows are the honest ones, and they are worse than Linux's.**
They also cover the *activation* path end to end: which button was pressed is
tested, but that a press arrives at all is not, and cannot be.
`linux-notify` runs a real dunst on a private session bus and presses a real
button with `dunstctl action`, because a notification daemon is an ordinary
D-Bus service. Windows has no equivalent: the notification platform is part of
the OS, there is no CLI that presses a toast button, and a GitHub Windows runner
has no interactive session to render one into. Nothing in this repository
posts a toast that anyone or anything then observes. If you change the posting
path, `winnotify-probe --post` on a real desktop is the gate, and it is a person.

Every Linux-CI row above was verified by breaking it — see the mutation list in
the commit that added them; all 22 mutants turned a test red.

## Running the gate

```bash
export PKG_CONFIG_PATH="$PWD/Packages/TailscaleKit"
swift test  --package-path Packages/WinNotifyKit           # decisions + syntax, anywhere
swift build --package-path Packages/WinNotifyKit --product winnotify-probe
swift run   --package-path Packages/WinNotifyKit winnotify-probe            # Windows: register + report
swift run   --package-path Packages/WinNotifyKit winnotify-probe --post     # Windows: manual gate
swift run   --package-path Packages/WinNotifyKit winnotify-probe --withdraw # Windows: post, then take it back
```

Off Windows the probe prints `SKIP` and exits 0 — it is there to be typechecked
and linked, not to judge a platform it is not running on. On Windows it also
prints `SKIP` when registration was refused, which is deliberate: turning the
zip build's honest degradation into a red gate would be asserting the opposite
of the design.

Nothing to install — the Windows App SDK is resolved at runtime, which is
exactly why a machine without it degrades instead of failing to start.
