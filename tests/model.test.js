const test = require('node:test')
const assert = require('node:assert')
const Model = require('../Model.js')

function video(over) {
  return Object.assign({
    itemId: 'item1',
    videoId: 'vid1',
    title: 'A Video',
    channel: 'Some Channel',
    duration: '4:13',
    seconds: 253,
    thumb: '',
    position: 0,
    available: true
  }, over)
}

// --- cache ---------------------------------------------------------------

test('parseCache returns a renderable shape for junk input', () => {
  for (const input of ['', 'not json', '{', 'null', '[]', '3']) {
    const cache = Model.parseCache(input)
    assert.equal(cache.syncedAt, 0)
    assert.deepEqual(cache.playlists, [])
    assert.deepEqual(cache.items, {})
    assert.equal(cache.error, '')
  }
})

test('parseCache survives a file caught mid-write', () => {
  // FileView can read while the CLI is replacing the file. Truncated JSON
  // has to come back as an empty cache, not throw inside a binding.
  const cache = Model.parseCache('{"syncedAt":123,"playli')
  assert.equal(cache.syncedAt, 0)
})

test('parseCache keeps real fields', () => {
  const cache = Model.parseCache(JSON.stringify({
    syncedAt: 1757500000,
    authRequired: true,
    error: 'boom',
    channel: 'Me',
    playlists: [{ id: 'PL1', title: 'Watch', count: 3 }],
    items: { PL1: [video()] },
    itemsSyncedAt: { PL1: 1757500001 }
  }))
  assert.equal(cache.syncedAt, 1757500000)
  assert.equal(cache.authRequired, true)
  assert.equal(cache.error, 'boom')
  assert.equal(cache.channel, 'Me')
  assert.equal(cache.playlists.length, 1)
  assert.equal(cache.items.PL1.length, 1)
})

test('videosFor and hasItems separate "unopened" from "empty"', () => {
  const cache = Model.parseCache(JSON.stringify({
    items: { PL1: [], PL2: [video()] },
    itemsSyncedAt: { PL1: 1757500000 }
  }))
  // PL1 was fetched and is genuinely empty; PL3 was never fetched. Both
  // list zero rows, but only PL3 should spin.
  assert.deepEqual(Model.videosFor(cache, 'PL1'), [])
  assert.equal(Model.hasItems(cache, 'PL1'), true)
  assert.deepEqual(Model.videosFor(cache, 'PL3'), [])
  assert.equal(Model.hasItems(cache, 'PL3'), false)
})

test('staleMinutes floors to whole minutes and never goes negative', () => {
  const now = 1757500000 * 1000
  assert.equal(Model.staleMinutes(1757500000, now), 0)
  assert.equal(Model.staleMinutes(1757500000 - 90, now), 1)
  assert.equal(Model.staleMinutes(0, now), 0)
  // A clock that stepped backwards must not render "-3 minutes ago".
  assert.equal(Model.staleMinutes(1757500000 + 600, now), 0)
})

test('totalVideos tolerates missing counts', () => {
  assert.equal(Model.totalVideos([{ count: 3 }, { count: 4 }]), 7)
  assert.equal(Model.totalVideos([{ count: 3 }, {}]), 3)
  assert.equal(Model.totalVideos([]), 0)
})

// --- text ----------------------------------------------------------------

test('elide only cuts when it has to, and trims the seam', () => {
  assert.equal(Model.elide('short', 20), 'short')
  assert.equal(Model.elide('exactlyten', 10), 'exactlyten')
  assert.equal(Model.elide('a longer title here', 10), 'a longer…')
  assert.equal(Model.elide(null, 10), '')
})

test('playlistSubtitle names only the privacy worth naming', () => {
  assert.equal(Model.playlistSubtitle({ count: 1, privacy: 'public' }), '1 video')
  assert.equal(Model.playlistSubtitle({ count: 12, privacy: 'private' }), '12 videos · private')
  assert.equal(Model.playlistSubtitle({ count: 0, privacy: 'unlisted' }), '0 videos · unlisted')
})

test('videoSubtitle collapses to "unavailable" for dead rows', () => {
  assert.equal(Model.videoSubtitle(video()), 'Some Channel · 4:13')
  assert.equal(Model.videoSubtitle(video({ duration: '' })), 'Some Channel')
  assert.equal(Model.videoSubtitle(video({ available: false })), 'unavailable')
})

// --- search --------------------------------------------------------------

test('filterVideos matches title and channel, case-insensitively', () => {
  const list = [
    video({ itemId: 'a', title: 'Rust in 100 Seconds', channel: 'Fireship' }),
    video({ itemId: 'b', title: 'Go Concurrency', channel: 'GopherCon' })
  ]
  assert.equal(Model.filterVideos(list, 'rust').length, 1)
  assert.equal(Model.filterVideos(list, 'FIRESHIP').length, 1)
  // Only video b matches: its title and channel both hit, but it is one row.
  assert.equal(Model.filterVideos(list, 'go').length, 1)
  assert.equal(Model.filterVideos(list, 'zzz').length, 0)
  assert.equal(Model.filterVideos(list, '   ').length, 2)
})

test('filterPlaylists ignores surrounding whitespace', () => {
  const lists = [{ title: 'Music' }, { title: 'Talks' }]
  assert.equal(Model.filterPlaylists(lists, '  mus  ').length, 1)
  assert.equal(Model.filterPlaylists(lists, '').length, 2)
})

// --- bar label -----------------------------------------------------------

test('cycleBarLabel wraps and recovers from an unknown mode', () => {
  assert.equal(Model.cycleBarLabel('Icon'), 'Playlists')
  assert.equal(Model.cycleBarLabel('Playlists'), 'Videos')
  assert.equal(Model.cycleBarLabel('Videos'), 'Icon')
  assert.equal(Model.cycleBarLabel('nonsense'), 'Playlists')
})

test('barLabel is empty when there is nothing to count', () => {
  const cache = Model.parseCache(JSON.stringify({
    playlists: [{ count: 2 }, { count: 3 }]
  }))
  assert.equal(Model.barLabel('Icon', cache), '')
  assert.equal(Model.barLabel('Playlists', cache), '2')
  assert.equal(Model.barLabel('Videos', cache), '5')
  // A signed-out bar shows the glyph alone rather than a bare "0".
  assert.equal(Model.barLabel('Playlists', Model.emptyCache()), '')
  assert.equal(Model.barLabel('Videos', Model.emptyCache()), '')
})

test('syncIntervalSeconds maps every option, and 0 means manual', () => {
  assert.equal(Model.syncIntervalSeconds('15 minutes'), 900)
  assert.equal(Model.syncIntervalSeconds('30 minutes'), 1800)
  assert.equal(Model.syncIntervalSeconds('1 hour'), 3600)
  assert.equal(Model.syncIntervalSeconds('Only when opened'), 0)
  assert.equal(Model.syncIntervalSeconds(undefined), 1800)
})

// --- commands ------------------------------------------------------------

test('playArgs passes the player through, and the command only for custom', () => {
  assert.deepEqual(
    Model.playArgs(video(), 'mpv', '', true),
    ['play', 'vid1', '--player', 'mpv', '--cookies', 'skip']
  )
  assert.deepEqual(
    Model.playArgs(video(), 'custom', 'freetube {url}', true),
    ['play', 'vid1', '--player', 'custom', '--command', 'freetube {url}']
  )
  // A stale command left over from a previous choice must not ride along.
  assert.deepEqual(
    Model.playArgs(video(), 'browser', 'freetube {url}', true),
    ['play', 'vid1', '--player', 'browser']
  )
})

test('--cookies rides along only for mpv, which is the only reader of them', () => {
  // Passing it to a browser or a custom command would be a flag the CLI
  // accepts and then has nothing to do with.
  for (const player of ['browser', 'custom']) {
    assert.equal(Model.playArgs(video(), player, 'x', true).indexOf('--cookies'), -1)
  }
  assert.deepEqual(Model.playerArgs('mpv', '', true).slice(-2), ['--cookies', 'skip'])
  assert.deepEqual(Model.playerArgs('mpv', '', false).slice(-2), ['--cookies', 'auto'])
  // Anything other than an explicit false is the fast default, so a missing
  // setting on a freshly-added widget does not silently cost five seconds.
  assert.deepEqual(Model.playerArgs('mpv', '', undefined).slice(-2), ['--cookies', 'skip'])
})

test('playPlaylistArgs carries the same player tail as a single video', () => {
  assert.deepEqual(
    Model.playPlaylistArgs({ id: 'PL1' }, 'mpv', '', true),
    ['play', '--playlist', 'PL1', '--player', 'mpv', '--cookies', 'skip']
  )
})

test('command builders refuse incomplete rows instead of running junk', () => {
  assert.equal(Model.playArgs(video({ videoId: '' }), 'mpv', ''), null)
  assert.equal(Model.playArgs(null, 'mpv', ''), null)
  assert.equal(Model.removeArgs(video({ itemId: '' })), null)
  assert.equal(Model.openArgs(video({ videoId: '' })), null)
  assert.equal(Model.itemsArgs('', 0, 0), null)
  assert.equal(Model.playPlaylistArgs({ id: '' }, 'mpv', ''), null)
})

test('removeArgs uses the playlistItem id, never the video id', () => {
  // Deleting by videoId would be a 404 at best; at worst it targets the
  // wrong row, since one video can sit in many playlists.
  assert.deepEqual(Model.removeArgs(video()), ['remove', 'item1'])
})

test('itemsArgs only adds flags it was given', () => {
  assert.deepEqual(Model.itemsArgs('PL1', 0, 0), ['items', 'PL1'])
  assert.deepEqual(Model.itemsArgs('PL1', 60, 0), ['items', 'PL1', '--max-age', '60'])
  assert.deepEqual(
    Model.itemsArgs('PL1', 60, 40),
    ['items', 'PL1', '--max-age', '60', '--limit', '40']
  )
})

// --- run bounds ----------------------------------------------------------

test('every command gets a deadline, and a sign-in gets the long one', () => {
  assert.equal(Model.deadlineSeconds(['login', '--client-file', '/x']), 420)
  assert.equal(Model.deadlineSeconds(['sync']), 90)
  assert.equal(Model.deadlineSeconds(['items', 'PL1']), 90)
  assert.equal(Model.deadlineSeconds(['play', 'vid1']), 45)
  assert.equal(Model.deadlineSeconds(['open', 'vid1']), 45)
  assert.equal(Model.deadlineSeconds(['remove', 'item1']), 30)
  // Nothing runs without one, whatever it was asked to do.
  for (const args of [[], null, undefined, ['nonsense']])
    assert.ok(Model.deadlineSeconds(args) > 0)
})

test('the passed-through environment names a session, never a program', () => {
  const names = Model.envPassthrough()
  assert.ok(names.includes('WAYLAND_DISPLAY') && names.includes('HOME'))
  // PATH is built by the CLI, and BROWSER would let the environment pick
  // the program xdg-open runs.
  for (const name of ['PATH', 'BROWSER', 'LD_PRELOAD', 'LD_LIBRARY_PATH',
                      'PYTHONPATH', 'PYTHONSTARTUP', 'SHELL', 'IFS'])
    assert.equal(names.includes(name), false, name + ' must not be passed through')
  assert.equal(new Set(names).size, names.length)
})

// --- removal undo --------------------------------------------------------

function held(key, deadline, title) {
  return { key: key, deadline: deadline, title: title || 'A Video', args: ['remove', key] }
}

test('undoSecondsLeft counts down and clamps at zero', () => {
  assert.equal(Model.undoSecondsLeft(10000, 4000), 6)
  assert.equal(Model.undoSecondsLeft(10000, 9500), 1)
  assert.equal(Model.undoSecondsLeft(10000, 10000), 0)
  assert.equal(Model.undoSecondsLeft(10000, 99999), 0)
  assert.equal(Model.undoSecondsLeft(0, 5000), 0)
})

test('expirePending sends only what is due, keeping order', () => {
  const pending = [held('a', 100), held('b', 200), held('c', 300)]
  const split = Model.expirePending(pending, 200)
  assert.deepEqual(split.due.map(e => e.key), ['a', 'b'])
  assert.deepEqual(split.remaining.map(e => e.key), ['c'])
})

test('undo takes back the most recent removal', () => {
  const pending = [held('a', 100), held('b', 200)]
  assert.equal(Model.topPending(pending).key, 'b')
  assert.deepEqual(Model.dropTopPending(pending).map(e => e.key), ['a'])
  assert.equal(Model.topPending([]), null)
  assert.deepEqual(Model.dropTopPending([]), [])
})

test('undoLabel names one video but counts several', () => {
  assert.equal(Model.undoLabel([]), '')
  assert.equal(Model.undoLabel([held('a', 1, 'Short')]), 'Removed Short')
  assert.equal(Model.undoLabel([held('a', 1), held('b', 2)]), 'Removed 2 videos')
})

test('isPending marks the held row so undo has something to restore', () => {
  const pending = [held('item1', 100)]
  assert.equal(Model.isPending(pending, video()), true)
  assert.equal(Model.isPending(pending, video({ itemId: 'other' })), false)
  assert.equal(Model.isPending([], video()), false)
  assert.equal(Model.isPending(pending, null), false)
})

test('visibleVideos caps the popup but 0 means unlimited', () => {
  const list = [video({ itemId: '1' }), video({ itemId: '2' }), video({ itemId: '3' })]
  assert.equal(Model.visibleVideos(list, [], 2).length, 2)
  assert.equal(Model.visibleVideos(list, [], 0).length, 3)
  assert.equal(Model.visibleVideos([], [], 5).length, 0)
})
