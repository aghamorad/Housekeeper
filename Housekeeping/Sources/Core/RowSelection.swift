// Housekeeping — click selection
//
// Native list behaviour: a plain click selects one row, Command-click adds or
// removes one, Shift-click selects the whole run between the last click and this
// one. Any list that lets a reader act on several rows should answer these three
// gestures, because that is what every Mac list has always done.

import AppKit

enum RowSelection {

    static var commandDown: Bool { NSEvent.modifierFlags.contains(.command) }
    static var shiftDown: Bool { NSEvent.modifierFlags.contains(.shift) }

    /// Applies one click to a selection. `order` is the visible order, which is
    /// what Shift-click ranges over — not the underlying data order.
    static func apply<ID: Hashable>(
        id: ID,
        order: [ID],
        selection: inout Set<ID>,
        anchor: inout ID?
    ) {
        if shiftDown, let anchor,
           let from = order.firstIndex(of: anchor),
           let to = order.firstIndex(of: id) {
            let bounds = from <= to ? from...to : to...from
            selection.formUnion(order[bounds])
            return
        }
        if commandDown {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            anchor = id
            return
        }
        selection = [id]
        anchor = id
    }
}
