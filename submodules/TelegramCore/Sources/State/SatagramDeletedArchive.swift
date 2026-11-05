import Foundation
import Postbox

public struct SatagramDeletedMessage: Codable {
    public let peerId: Int64
    public let chatTitle: String?
    public let messageId: Int32
    public let timestamp: Int32
    public let text: String
}

public enum SatagramDeletedArchive {
    private static let lock = NSLock()
    private static let limit = 500

    private static func key(_ accountPeerId: PeerId) -> String {
        return "SatagramDeletedMessages.\(accountPeerId.toInt64())"
    }

    private static func read(_ accountPeerId: PeerId) -> [SatagramDeletedMessage] {
        guard let data = UserDefaults.standard.data(forKey: key(accountPeerId)) else { return [] }
        return (try? JSONDecoder().decode([SatagramDeletedMessage].self, from: data)) ?? []
    }

    public static func messages(accountPeerId: PeerId) -> [SatagramDeletedMessage] {
        lock.lock()
        defer { lock.unlock() }
        return read(accountPeerId)
    }

    public static func clear(accountPeerId: PeerId) {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key(accountPeerId))
    }

    static func capture(transaction: Transaction, ids: [MessageId], accountPeerId: PeerId) {
        let captured: [SatagramDeletedMessage] = ids.compactMap { id in
            guard id.peerId.namespace == Namespaces.Peer.CloudUser || id.peerId.namespace == Namespaces.Peer.CloudGroup || id.peerId.namespace == Namespaces.Peer.CloudChannel,
                  let message = transaction.getMessage(id), message.flags.contains(.Incoming), !message.text.isEmpty,
                  !message.attributes.contains(where: { $0 is AutoremoveTimeoutMessageAttribute || $0 is AutoclearTimeoutMessageAttribute }) else { return nil }
            let chatTitle: String?
            if let user = message.peers[id.peerId] as? TelegramUser {
                chatTitle = [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
            } else if let group = message.peers[id.peerId] as? TelegramGroup {
                chatTitle = group.title
            } else if let channel = message.peers[id.peerId] as? TelegramChannel {
                chatTitle = channel.title
            } else {
                chatTitle = nil
            }
            return SatagramDeletedMessage(peerId: id.peerId.toInt64(), chatTitle: chatTitle, messageId: id.id, timestamp: message.timestamp, text: String(message.text.prefix(4096)))
        }
        if captured.isEmpty { return }
        lock.lock()
        defer { lock.unlock() }
        var messages = read(accountPeerId)
        var seen = Set(messages.map { "\($0.peerId):\($0.messageId)" })
        for message in captured {
            if seen.insert("\(message.peerId):\(message.messageId)").inserted {
                messages.append(message)
            }
        }
        if messages.count > limit { messages.removeFirst(messages.count - limit) }
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: key(accountPeerId))
        }
    }
}
