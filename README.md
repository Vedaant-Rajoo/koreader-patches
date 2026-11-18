# Meguru duplicate skip

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

Every release remains manually openable. The patch does not change chapter IDs,
read flags, downloads, or page prefetch. Local CBZ, Kavita, and Komga navigation
is unchanged. Resume and first-unread are outside its scope and may open an
unread duplicate.

## Install and disable

Copy only `2-newedia-meguru-dupskip.lua` into KOReader's `patches` directory,
next to its existing user patches, and restart KOReader. Meguru must already be
installed. No additional runtime dependencies are needed.

To disable, remove the file or rename it to
`2-newedia-meguru-dupskip.lua.disabled`, then restart KOReader. Disable it for
series with chapter numbering that resets across volumes. There is no per-series
setting.

## Limits and connection requirements

- Chapter numbers and scanlators come from one read-only GraphQL request to
  `/api/graphql`. The API origin and reverse proxy prefix come from the canonical
  `/api/opds/v1.2/series/{id}/chapters` URL. Redirects and embedded URL credentials
  are refused. Use Meguru's normal username/password fields.
- Suwayomi `NONE` and `BASIC_AUTH` modes can support this request. OPDS working
  does not prove GraphQL access: `UI_LOGIN` needs a token and `SIMPLE_LOGIN` needs
  a cookie, which this patch does not acquire. Do not weaken server authentication
  to enable the patch. HTTP or GraphQL errors keep original navigation.
- Missing chapter metadata, an unsupported URL, or a feed containing `:remote`
  progress-conflict entries keeps original navigation. Conflict copies are not
  treated as scanlator releases.
- There is no volume metadata. Equal adjacent numbers can represent different
  content, including specials with ordinary numbers. This is not foolproof
  deduplication and does not infer official or unofficial releases.
- Meguru's six-page navigation limit (typically about 600 releases) still applies.
  Incomplete walks fail as before; the patch neither raises the limit nor hides
  the failure.
- One in-memory cache entry lasts 60 seconds and is isolated by API, manga,
  username, password, and feed IDs. Changing feed IDs refreshes it immediately;
  metadata edits and recovered connections can take up to 60 seconds to appear.
  Credentials stay private in memory and are not attached to items or logged.
- A cache miss adds one synchronous request with a 2-second socket block timeout,
  a 4-second response sink timeout, and a 1 MiB accepted-response limit. LuaSocket
  can buffer an HTTP chunk before the sink checks its size, so this is not a
  peak-memory bound. These are KOReader network limits, not a strict wall-clock
  deadline; DNS can take longer.

## Compatibility and tests

The automated suite uses real Meguru 1.8.7 modules at
`7a6e9b8033c228c187855af8fcd4c4580018ac4b`, including Feed, drivers, ordering, and
same-ID deduplication. HTTP, plugin lifecycle, and KOReader's timeout host are
mocked; JSON, URL parsing, and KOReader's Unicode helper use real libraries.
The reader source is checked for the shared manual/automatic navigation call
site. This does not replace a reader or device test.

Desktop integration passed in isolated Docker with KOReader v2026.07, actual
Meguru 1.8.7, and a synthetic HTTP OPDS/PSE and GraphQL server. Manual next and
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
the normalization regression tests do not replace another device test.

For a reader integration check, use a disposable Suwayomi-compatible fixture
with IDs `101:10/A, 102:10/B, 103:11/B, 104:11/A, 105:unknown, 106:12/A` in that
source order. Confirm unpatched next opens `102` from `101`; patched manual next
and auto-next open `104`, previous returns `101`, and next visits `105`, then
`106`. Manually open `102` and verify next selects `103`. Repeat with GraphQL
returning HTTP 401 and a GraphQL error; navigation must return to the original
sequence. Confirm no extra query within the cache interval and no changed read
flags or stored IDs. A series exceeding six OPDS pages must still report its
original incomplete-walk failure.

## License

AGPL-3.0-or-later; see [LICENSE](LICENSE). HTTP conventions are adapted from
Craftwork2720's Meguru `meguru/net.lua` (1.8.7), under the same license.
