import Foundation

/// 便签里的一页。正文是 Markdown,只留在本机偏好设置里,不进采样。
struct StickyNote: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var updatedAt: Date
}

/// 便签的页。按数组顺序翻页,变更立刻写回 UserDefaults。
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published private(set) var notes: [StickyNote] = []

    private let defaultsKey = "stickyNotes"
    private let maxCount = 50
    private let maxLength = 20_000

    /// 卡面上的短标记。竖条装不下一页正文,只报页数。
    var cardToken: String { "\(notes.count)" }

    private init() { load() }

    /// 在末尾加一页空白,并返回它的 id。超出页数时丢掉最前面的页。
    @discardableResult
    func addPage() -> UUID {
        let note = StickyNote(id: UUID(), text: "", updatedAt: Date())
        var next = notes
        next.append(note)
        if next.count > maxCount { next.removeFirst(next.count - maxCount) }
        notes = next
        save()
        return note.id
    }

    func update(_ id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let clipped = String(text.prefix(maxLength))
        guard notes[index].text != clipped else { return }
        var next = notes
        next[index].text = clipped
        next[index].updatedAt = Date()
        notes = next
        save()
    }

    func remove(_ id: UUID) {
        let next = notes.filter { $0.id != id }
        guard next.count != notes.count else { return }
        notes = next
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([StickyNote].self, from: data),
           !decoded.isEmpty {
            notes = decoded
            return
        }
        // 进来就是一页可写的,不另做「新建」。
        notes = [StickyNote(id: UUID(), text: "", updatedAt: Date())]
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
