# Meguru duplicate skip and completion sync

A single-file KOReader user patch for Suwayomi chapter navigation through
[Meguru](https://github.com/Craftwork2720/meguru). Next, previous, and automatic
next skip adjacent releases with the same chapter number. In the next group,
the patch prefers the current release's nonempty scanlator, otherwise the
nearest entry in Meguru's existing reading order.

Scanlator comparison uses KOReader's Unicode NFKC case folding, then trims and
collapses ASCII whitespace. For example, ` Group A ` matches `group a`, and
composed and decomposed accented names match. Normalized names stay private;
displayed names and server metadata are unchanged. Blank or invalid UTF-8 names
and names containing NUL have no preference. Group aliases and collaboration
credits are not inferred or split.

For example, next from `10 / Group A` in `10/A, 10/B, 11/B, 11/A, Special`
opens `11/A`. The following next opens `Special`. Chapter `0` and fractions
remain distinct. Unknown, malformed, or negative numbers are individual stops.
Leaving an unnumbered special still prefers its scanlator in the next or previous
numbered group. The patch never searches globally for a higher chapter number.

When you turn beyond the last page, the patch marks the completed release and
its adjacent duplicates read on Suwayomi in one bulk request. This also works
with automatic next disabled and at the end of the series. It never marks the
next chapter's alternatives merely because navigation chose a preferred release.
Opening a chapter or pressing manual Next/Previous does not mark duplicates read;
use the normal page turn beyond the end to trigger completion.

Every release remains manually openable. Chapter IDs, downloads, bookmarks, and
page counters are unchanged by the patch. Local CBZ, Kavita, and Komga are
unaffected. Resume and first-unread keep their existing selection logic, but
Suwayomi's unread feed excludes successfully marked releases. Previously skipped
chapters are not backfilled, and marking a chapter unread does not undo the bulk
read operation.

## Install and disable

Copy only `2-newedia-meguru-dupskip.lua` into KOReader's `patches` directory,
next to its existing user patches, and restart KOReader. Meguru must already be
installed. No additional runtime dependencies are needed.

To disable, remove the file or rename it to
`2-newedia-meguru-dupskip.lua.disabled`, then restart KOReader. Disable it for
series with chapter numbering that resets across volumes. There is no per-series
setting.

## Limits and connection requirements

- Navigation gets chapter numbers and scanlators from one read-only GraphQL request to
  `/api/graphql`. The API origin and reverse proxy prefix come from the canonical
  `/api/opds/v1.2/series/{id}/chapters` URL. Redirects and embedded URL credentials
  are refused. Use Meguru's normal username/password fields.
- Suwayomi `NONE` and `BASIC_AUTH` modes can support this request. OPDS working
  does not prove GraphQL access: `UI_LOGIN` needs a token and `SIMPLE_LOGIN` needs
  a cookie, which this patch does not acquire. Do not weaken server authentication
  to enable the patch. HTTP or GraphQL errors keep original navigation.
- Completion walks the canonical feed again and refreshes GraphQL metadata before
  writing, rather than using cached chapter numbers. Only the completed chapter's
  contiguous group in that feed is marked, including alternatives on either side
  of the current release. Filtered-out releases and nonadjacent equal numbers are
  not marked. Unknown chapter numbers and groups with no alternatives need no write.
- The bulk mutation sends only `isRead: true` and checks the returned chapter IDs
  and read flags. Suwayomi may propagate these changes through its own configured
  KOReaderSync integration. A confirmed sync runs once per reader instance.
  Offline, failed, or unconfirmed syncs leave the normal end action intact and log
  a fixed warning without credentials. Finish the chapter again to retry; there
  is no persistent queue or automatic retry after leaving the chapter.
- Missing chapter metadata, an unsupported URL, or a feed containing `:remote`
  progress-conflict entries keeps original navigation. Conflict copies are not
  treated as scanlator releases. These conditions also prevent completion writes.
- There is no volume metadata. Equal adjacent numbers can represent different
  content, including specials with ordinary numbers. This is not foolproof
  deduplication and does not infer official or unofficial releases. It can mark
  distinct content read when adjacent chapter numbers collide. Disable the patch
  for series that restart numbering across volumes or seasons.
- Meguru's six-page navigation limit (typically about 600 releases) still applies.
  Incomplete walks fail as before; the patch neither raises the limit nor hides
  the failure.
- One in-memory cache entry lasts 60 seconds and is isolated by API, manga,
  username, password, and feed IDs. Changing feed IDs refreshes it immediately;
  metadata edits and recovered connections can take up to 60 seconds to appear.
  Credentials stay private in memory and are not attached to items or logged.
- A navigation cache miss adds one synchronous request. Completion adds a fresh
  feed walk, a metadata query, and, for a duplicate group, one mutation. Each
  GraphQL request has a 2-second socket block timeout,
  a 4-second response sink timeout, and a 1 MiB accepted-response limit. LuaSocket
  can buffer an HTTP chunk before the sink checks its size, so this is not a
  peak-memory bound. These are KOReader network limits, not a strict wall-clock
  deadline; DNS can take longer.

## Compatibility and tests

The automated suite uses real Meguru 1.8.7 modules at
`7a6e9b8033c228c187855af8fcd4c4580018ac4b`, including Feed, drivers, ordering, and
same-ID deduplication. Completion tests also use the real plan builder and feed
walker. HTTP, ReaderUI/plugin lifecycle, and KOReader's timeout host are mocked;
JSON, URL parsing, and KOReader's Unicode helper use real libraries. Tests cover
completion groups across pages, last-chapter completion, repeated end events,
fresh metadata, failed writes and retries, account isolation, and refusals.
The reader source is checked for the shared manual/automatic navigation call
site. This does not replace a reader or device test.

Completion sync passed a separate local runtime catalog with KOReader v2026.07
and Meguru 1.8.7 in an isolated Docker container: 8 cases and 17 actions. These
checks drive real ReaderPaging end events and menu callbacks, decode fixture
images, and assert the exact mutation IDs against an HTTP mirror. They cover
manual navigation without writes, two consecutive completed chapters, repeated
end events with one write, auto-next disabled, the last chapter group, HTTP 401
and successful retry, the six-page refusal, and an unpatched control. This mirror
is kept outside the repository and does not verify writes against live Suwayomi.

Before completion sync was added, desktop integration passed in isolated Docker
with KOReader v2026.07, actual Meguru 1.8.7, and a synthetic HTTP OPDS/PSE and GraphQL server. Manual next and
auto-next selected `104` from `101`; previous returned to `101`; subsequent next
visited the unknown special `105`, then `107` with the special's scanlator,
skipping alternate `106`. The unpatched baseline selected
duplicate `102`. HTTP 401 and GraphQL errors preserved original navigation. This
verifies rendered reader behavior against a fixture.

A separate headless process on a Kindle with KOReader v2026.07.2 and Meguru 1.8.7
also used the installed LuaJIT, feed/parser and network modules against an
authenticated Suwayomi server. It walked 506 releases and exercised next/previous
selection without opening pages or changing reading progress. The test stubbed
the device host and plugin constructor to leave the active reader untouched;
it does not verify rendered Kindle UI or Kindle auto-next.

KOReader v2026.07.1 and v2026.07.2 have identical `userpatch.lua` and
`socketutil.lua` source for the APIs used here. Suwayomi v2.4.2366 and source
`d521528` expose the required chapter query without pagination when `first` and
`last` are omitted. Rendered Kindle behavior and other versions are not verified
by this suite.

Install LuaJIT, LuaSocket, dkjson, and the utf8proc development library for the
test host. Use KOReader's `koreader-base` source for its real Unicode helper:

```sh
luajit tests/dupskip.lua.test /path/to/meguru /path/to/koreader-base
```

Alternatively, use the pure Lua libraries from a KOReader installation:

```sh
luajit tests/dupskip.lua.test /path/to/meguru /path/to/koreader
```

Tests use `.lua.test` so Storefront does not expose them as installable patches.
CI runs the same suite against pinned Meguru and koreader-base sources.
The earlier desktop and Kindle checks above predate scanlator normalization;
the normalization regression tests do not replace another device test. Neither
historical check verifies completion writes on a physical Kindle or live Suwayomi.

For a reader integration check, use a disposable Suwayomi-compatible fixture
with IDs `101:10/A, 102:10/B, 103:11/B, 104:11/A, 105:unknown, 106:12/A` in that
source order. Confirm unpatched next opens `102` from `101`; patched manual next
and auto-next open `104`, previous returns `101`, and next visits `105`, then
`106`. Manually open `102` and verify next selects `103`. Repeat with GraphQL
returning HTTP 401 and a GraphQL error; navigation must return to the original
sequence. Manual navigation must not write read flags. Turn beyond the last page
of `101` and confirm that only `101` and `102` receive `isRead: true`; IDs, page
counters, and bookmarks must remain unchanged. Repeat with auto-next disabled,
the final chapter group, repeated end events, and a rejected mutation followed
by a successful retry. A series exceeding six OPDS pages must still report its
original incomplete-walk failure without any completion mutation.

## License

AGPL-3.0-or-later; see [LICENSE](LICENSE). HTTP conventions are adapted from
Craftwork2720's Meguru `meguru/net.lua` (1.8.7), under the same license.
