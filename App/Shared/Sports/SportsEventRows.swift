import SwiftUI

/// `sports.eventRows` (engine/sportsEvent.ts): the event screen's Stats and Lineups rows. The
/// engine ports the upstream data logic; these views draw it with SwiftUI shapes on upstream's
/// percentages (bp-sports-live-*.tsx, bp-sports-extra-pitch/-players.tsx, bp-sports-event-rows.tsx).
struct SportsEventRows: Decodable {
    struct Seat: Decodable { var jersey: String; var name: String; var left: Double; var top: Double }
    struct Court: Decodable { var homeName: String; var awayName: String; var home: [Seat]; var away: [Seat] }
    struct Diamond: Decodable { var bases: [Bool]; var balls: Int?; var strikes: Int?; var outs: Int?; var batter: String; var pitcher: String; var runners: String }
    struct Owner: Decodable { var name: String; var abbr: String; var logo: String }
    struct Field: Decodable { var down: Int?; var distance: Int?; var owner: Owner?; var marker: Double; var yardLine: String }
    struct Situation: Decodable { var kind: String; var caption: String; var diamond: Diamond?; var field: Field?; var court: Court? }
    struct Play: Decodable { var id: String; var time: String; var text: String; var participant: String; var icon: String; var loud: Bool }
    struct Plays: Decodable { var caption: String; var total: Int; var rows: [Play] }
    struct Line: Decodable { var label: String; var awayValue: String; var homeValue: String; var bar: Bool; var share: Double }
    struct Team: Decodable { var caption: String; var paired: Int; var lines: [Line] }
    struct Stats: Decodable { var title: String; var situation: Situation?; var plays: Plays?; var team: Team? }

    struct Spot: Decodable { var home: Bool; var jersey: String; var name: String; var left: Double; var top: Double; var goals: Int; var out: Bool }
    struct Pitch: Decodable { var homeName: String; var awayName: String; var homeFormation: String; var awayFormation: String; var spots: [Spot]; var bench: [String] }
    struct Member: Decodable { var id: String; var name: String; var jersey: String; var position: String; var starter: Bool }
    struct LineupSide: Decodable { var name: String; var formation: String; var players: [Member]; var starters: Int }
    struct TableRow: Decodable { var id: String; var name: String; var image: String?; var values: [String] }
    struct Table: Decodable { var key: String; var heading: String; var summary: String; var labels: [String]; var rows: [TableRow]; var trimmed: Int }
    struct Lineups: Decodable { var title: String; var pitch: Pitch?; var away: LineupSide?; var home: LineupSide?; var players: [Table] }

    var stats: Stats?
    var lineups: Lineups?
}
