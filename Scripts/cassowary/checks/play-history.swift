// Checks for PlayInfo.merged(with:), run by Scripts/cassowary/check-play-history.sh.

import Foundation
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { exit(1) } }
let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 2000)
// Un-favoriting wins when it is newer.
var phone = PlayInfo(); phone.setFavorite(true, at: t0)
var tv = phone; tv.setFavorite(false, at: t1)
check(phone.merged(with: tv).favorite == false && tv.merged(with: phone).favorite == false, "a newer un-favorite wins, either way round")
// Plays on both devices add up.
var a = PlayInfo(); a.recordPlay(on: "phone", at: t0); a.recordPlay(on: "phone", at: t0)
var b = PlayInfo(); b.recordPlay(on: "tv", at: t1)
let m = a.merged(with: b)
check(m.playCount == 3 && m.lastPlayedAt == t1, "plays on two devices add up (3), latest play kept")
check(m.merged(with: a) == m && m.merged(with: b) == m && a.merged(with: b) == b.merged(with: a), "merging again changes nothing, and order does not matter")
// Old records: legacy counts are not double counted after both upgrade.
let old = PlayInfo(lastPlayedAt: t0, playCount: 5, favorite: true)
var up1 = old; up1.recordPlay(on: "phone", at: t1)
var up2 = old; up2.recordPlay(on: "tv", at: t1)
check(up1.merged(with: up2).playCount == 7, "5 earlier plays + 1 on each device = 7, not 12")
check(old.merged(with: old) == old, "two old records merge as before")
// JSON from an older app still decodes.
let legacy = #"{"playCount":4,"favorite":true,"lastPlayedAt":"2026-01-01T00:00:00Z"}"#
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
check((try? dec.decode(PlayInfo.self, from: Data(legacy.utf8)))?.playCount == 4, "an older app's play history still reads")
