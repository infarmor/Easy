import Foundation

/// Everything a message row draws, worked out once per change of the history. Rows compare equal when nothing
/// about them changed, so SwiftUI skips redrawing them.
struct TranscriptRow: Equatable {
    var message: Message
    let showsSender: Bool
    /// The last message of a run from one sender: it gets the bubble's tail and the time.
    var endsGroup = true
    /// All messages of an album, drawn together in this row (the row's message is the album's last).
    var album: [Message] = []
    /// The quoted message, when it is loaded; looked up here so the row does not read the whole history.
    var reply: Message?
}

struct TranscriptDay: Identifiable, Equatable {
    let date: Date
    var rows: [TranscriptRow]

    var id: Date { date }
}

/// Groups the history into days, runs of one sender and albums. It keeps its state between changes, so a new
/// message extends the transcript and a changed one is patched in place: rebuilding a long history for every
/// message of a busy group, or every view count of a channel, cost about a millisecond per hundred messages.
struct TranscriptBuilder {
    /// The day being filled is the last one. There is a single copy of the rows: the model publishes this
    /// array itself, so a new message copies the day's rows at most once between two redraws.
    private(set) var days: [TranscriptDay] = []
    private var previous: Message?
    /// Message id → position in the history.
    private(set) var index: [Int64: Int] = [:]
    /// Message id → id of the row that shows it (album members point at the album's row).
    private(set) var rowIds: [Int64: Int64] = [:]
    /// Row id → day and row where it sits.
    private var locations: [Int64: (day: Int, row: Int)] = [:]
    /// Quoted message id → ids of the rows that show it as a quote. Without it every edit, reaction or view
    /// count of a message walked the whole history looking for the few rows that quote it.
    private var quoters: [Int64: [Int64]] = [:]
    private let calendar = Calendar.current

    init() {}

    /// The whole history at once.
    init(_ messages: [Message], replyPreviews: [Int64: Message]) {
        index.reserveCapacity(messages.count)
        rowIds.reserveCapacity(messages.count)
        append(messages, from: 0, replyPreviews: replyPreviews)
    }

    /// Adds `messages[start...]`, which must come after everything added so far.
    mutating func append(_ messages: [Message], from start: Int, replyPreviews: [Int64: Message]) {
        guard start < messages.count else { return }
        for position in start..<messages.count {
            let message = messages[position]
            index[message.id] = position
            let quoted = message.replyToId == 0 ? nil
                : (index[message.replyToId].map { messages[$0] } ?? replyPreviews[message.replyToId])
            add(message, quoted: quoted)
        }
    }

    private mutating func add(_ message: Message, quoted: Message?) {
        rowIds[message.id] = message.id
        let date = calendar.startOfDay(for: message.date)
        // A new section only for a later day. Imported history can carry an earlier date after a later one;
        // a second section with the same date would give two views one identity.
        if days.isEmpty || date > days[days.count - 1].date {
            days.append(TranscriptDay(date: date, rows: []))
            previous = nil
        }
        let day = days.count - 1

        let isService = message.isService
        // A service line ("вступил в группу") ends the run above it: the next bubble starts a new one.
        let continues = !isService
            && previous?.isService == false
            && previous?.senderKey == message.senderKey
            && previous?.isOutgoing == message.isOutgoing
            && message.date.timeIntervalSince(previous?.date ?? message.date) < 240
        // The next photo of an album joins the previous row instead of starting its own.
        if message.albumId != 0, let last = days[day].rows.last, last.message.albumId == message.albumId {
            var joined = TranscriptRow(message: message, showsSender: last.showsSender, endsGroup: true)
            joined.album = (last.album.isEmpty ? [last.message] : last.album) + [message]
            joined.reply = last.reply ?? quoted
            // The row is re-keyed onto its last message, so the quote index follows it.
            if let quotedId = joined.reply?.id {
                quoters[quotedId]?.removeAll { $0 == last.message.id }
                quoters[quotedId, default: []].append(message.id)
            }
            locations[last.message.id] = nil
            for member in joined.album { rowIds[member.id] = message.id }
            days[day].rows[days[day].rows.count - 1] = joined
            locations[message.id] = (day, days[day].rows.count - 1)
            previous = message
            return
        }
        if continues, !days[day].rows.isEmpty { days[day].rows[days[day].rows.count - 1].endsGroup = false }
        var row = TranscriptRow(message: message, showsSender: !continues && !isService)
        row.reply = quoted
        if let quotedId = quoted?.id { quoters[quotedId, default: []].append(message.id) }
        days[day].rows.append(row)
        locations[message.id] = (day, days[day].rows.count - 1)
        previous = message
    }

    /// Puts a changed copy of a message in its row, and in the quotes of rows that answer it. False when the
    /// change could move it into another run or day, which takes a full rebuild.
    mutating func replace(_ old: Message, with new: Message) -> Bool {
        guard old.id == new.id, old.senderKey == new.senderKey, old.date == new.date, old.isOutgoing == new.isOutgoing,
              old.albumId == new.albumId, old.isService == new.isService, old.replyToId == new.replyToId,
              let rowId = rowIds[new.id], let location = locations[rowId] else { return false }
        if days[location.day].rows[location.row].message.id == new.id {
            days[location.day].rows[location.row].message = new
        }
        if let member = days[location.day].rows[location.row].album.firstIndex(where: { $0.id == new.id }) {
            days[location.day].rows[location.row].album[member] = new
        }
        if previous?.id == new.id { previous = new }
        // Quotes of this message elsewhere show its new text too: the index says which rows those are, so an
        // edit costs a handful of rows instead of a walk over the whole history.
        for rowId in quoters[new.id] ?? [] {
            guard let location = locations[rowId], days[location.day].rows[location.row].reply?.id == new.id else { continue }
            days[location.day].rows[location.row].reply = new
        }
        return true
    }
}
