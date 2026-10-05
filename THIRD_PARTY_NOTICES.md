# Licenses and dependency notices

The first-party Swift application and general supporting code are MIT licensed.
`tools/WhatsAppBridge/` is a separately built executable, licensed GPL-3.0-or-later:
its whatsmeow dependency (MPL-2.0) links go.mau.fi/libsignal (GPL-3.0). Preserve
that helper's source, license, pinned go.mod/go.sum, and dependency notices when
distributing it. The source snapshot includes the helper's corresponding source;
third-party dependencies can be obtained at the locked revisions. This is not
an MIT-only binary distribution.

The bundled `Sources/Resources/ThirdPartyNotices.txt` contains the available
root license texts from the resolved Swift and Go dependencies. It is a release
input; rebuild/review it whenever dependency locks change. Bundled font licenses
are retained in `Sources/Resources/Fonts/` (SIL Open Font License). Do not remove
notices from binary frameworks or replace upstream licenses with the root MIT
license. TDLibKit's downloaded binary framework has its own upstream notices.

Major Swift dependencies: TDLibKit (MIT wrapper; TDLib Boost Software License),
GRDB (MIT), Sentry (MIT), Sparkle (upstream license notices), Clerk (MIT), and
SwiftEmbeddings (MIT), plus their transitive packages. The pinned revisions are
in `Pidgy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Go dependencies and versions are in `tools/WhatsAppBridge/go.mod` and `go.sum`.

Pidgy branding and third-party service marks are used to identify the project
and integrations. These license grants do not transfer trademark rights.
