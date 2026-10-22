import Foundation

/// A fixed-capacity set that keeps the most recently inserted elements.
///
/// Used to remember tracks Music has already reported without artwork: the
/// marker has to expire, otherwise a track whose thumbnail was evicted would
/// fall back to the printed label forever. The small limit keeps the linear
/// recency bookkeeping cheap and the memory bounded.
struct RecentSet<Element: Hashable> {
    let limit: Int
    private var order: [Element] = []
    private var members: Set<Element> = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int { order.count }

    func contains(_ element: Element) -> Bool {
        members.contains(element)
    }

    /// Marks an element as present and makes it the most recent. Inserting an
    /// element that is already tracked refreshes its position instead of
    /// duplicating it.
    mutating func insert(_ element: Element) {
        if members.contains(element) {
            order.removeAll { $0 == element }
        }
        members.insert(element)
        order.append(element)
        while order.count > limit {
            members.remove(order.removeFirst())
        }
    }

    mutating func removeAll() {
        order.removeAll()
        members.removeAll()
    }
}
