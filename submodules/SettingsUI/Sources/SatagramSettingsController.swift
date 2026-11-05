import Foundation
import UIKit
import Security
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext

private enum SatagramProvider: String {
    case openAI = "GPT"
    case anthropic = "Claude"
}

private struct SatagramSettingsState: Equatable {
    var ghostMode: Bool
    var provider: SatagramProvider
    var apiKey: String
    var keychainError: Bool
}

private func keychainQuery(_ provider: SatagramProvider) -> [String: Any] {
    return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Satagram.LLM", kSecAttrAccount as String: provider.rawValue]
}

private func readAPIKey(_ provider: SatagramProvider) -> (String, Bool) {
    var query = keychainQuery(provider)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return ("", false) }
    guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { return ("", true) }
    return (key, false)
}

private func saveAPIKey(_ key: String, provider: SatagramProvider) -> Bool {
    let query = keychainQuery(provider)
    if key.isEmpty {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    let data = Data(key.utf8)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return true }
    if status != errSecItemNotFound { return false }
    var attributes = query
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
}

private final class SatagramSettingsArguments {
    var openArchive: () -> Void = {}
    let updateGhostMode: (Bool) -> Void
    let selectProvider: (SatagramProvider) -> Void
    let updateAPIKey: (String) -> Void

    init(updateGhostMode: @escaping (Bool) -> Void, selectProvider: @escaping (SatagramProvider) -> Void, updateAPIKey: @escaping (String) -> Void) {
        self.updateGhostMode = updateGhostMode
        self.selectProvider = selectProvider
        self.updateAPIKey = updateAPIKey
    }
}

private enum SatagramSettingsEntry: ItemListNodeEntry {
    case ghostMode(Bool)
    case ghostModeInfo(String)
    case providerHeader(String)
    case provider(SatagramProvider, Bool)
    case apiKey(String, String)
    case keyInfo(String)
    case archiveLink(String)
    case archiveInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .ghostMode, .ghostModeInfo: return 0
        case .providerHeader, .provider, .apiKey, .keyInfo: return 1
        case .archiveLink, .archiveInfo: return 2
        }
    }
    var stableId: Int32 {
        switch self {
        case .ghostMode: return 0
        case .ghostModeInfo: return 1
        case .providerHeader: return 2
        case .provider(.openAI, _): return 3
        case .provider(.anthropic, _): return 4
        case .apiKey: return 5
        case .keyInfo: return 6
        case .archiveLink: return 7
        case .archiveInfo: return 8
        }
    }
    static func < (lhs: SatagramSettingsEntry, rhs: SatagramSettingsEntry) -> Bool { return lhs.stableId < rhs.stableId }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SatagramSettingsArguments
        switch self {
        case let .ghostMode(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Ghost Mode", value: value, sectionId: self.section, style: .blocks, updated: arguments.updateGhostMode)
        case let .ghostModeInfo(text), let .keyInfo(text), let .archiveInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .providerHeader(title):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: title, sectionId: self.section)
        case let .provider(provider, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: provider.rawValue, style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: { arguments.selectProvider(provider) })
        case let .apiKey(value, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: placeholder, type: .password, sectionId: self.section, textUpdated: arguments.updateAPIKey)
        case let .archiveLink(title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: "", sectionId: self.section, style: .blocks, action: arguments.openArchive)
        }
    }
}

public func satagramSettingsController(context: AccountContext) -> ViewController {
    let provider = SatagramProvider(rawValue: UserDefaults.standard.string(forKey: "SatagramLLMProvider") ?? "") ?? .openAI
    let (key, keychainError) = readAPIKey(provider)
    let initialState = SatagramSettingsState(ghostMode: UserDefaults.standard.bool(forKey: "SatagramGhostMode"), provider: provider, apiKey: key, keychainError: keychainError)
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let updateState: (@escaping (SatagramSettingsState) -> SatagramSettingsState) -> Void = { update in
        statePromise.set(stateValue.modify { update($0) })
    }
    let arguments = SatagramSettingsArguments(updateGhostMode: { value in
        UserDefaults.standard.set(value, forKey: "SatagramGhostMode")
        NotificationCenter.default.post(name: Notification.Name("SatagramGhostModeChanged"), object: nil)
        updateState { state in var state = state; state.ghostMode = value; return state }
    }, selectProvider: { provider in
        UserDefaults.standard.set(provider.rawValue, forKey: "SatagramLLMProvider")
        let (key, error) = readAPIKey(provider)
        updateState { state in var state = state; state.provider = provider; state.apiKey = key; state.keychainError = error; return state }
    }, updateAPIKey: { value in
        updateState { state in
            var state = state
            state.apiKey = value
            state.keychainError = !saveAPIKey(value, provider: state.provider)
            return state
        }
    })

    let state = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, settings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let russian = presentationData.strings.baseLanguageCode == "ru"
        let ghostInfo = russian ? "Satagram не отправляет регулярный статус «в сети». Отправка сообщений и другие устройства всё ещё могут показать вашу активность." : "Satagram suppresses regular online status updates. Sending messages and other sessions may still show your activity."
        let keyInfo: String
        if settings.keychainError {
            keyInfo = russian ? "Не удалось сохранить или прочитать ключ в Keychain." : "Could not save or read the key in Keychain."
        } else {
            keyInfo = russian ? "Ключ хранится в Keychain на этом устройстве. Настройка ответов ИИ пока не подключена." : "The key is stored in this device's Keychain. AI replies are not connected yet."
        }
        let archiveInfo = russian ? "Сохраняются до 500 входящих текстов, уже загруженных на устройство. Медиа, секретные чаты и исчезающие сообщения не сохраняются." : "Keeps up to 500 incoming texts already loaded on this device. Media, secret chats and disappearing messages are not saved."
        let entries: [SatagramSettingsEntry] = [.ghostMode(settings.ghostMode), .ghostModeInfo(ghostInfo), .providerHeader(russian ? "ПРОВАЙДЕР ИИ" : "AI PROVIDER"), .provider(.openAI, settings.provider == .openAI), .provider(.anthropic, settings.provider == .anthropic), .apiKey(settings.apiKey, "API key"), .keyInfo(keyInfo), .archiveLink(russian ? "Удалённые сообщения" : "Deleted messages"), .archiveInfo(archiveInfo)]
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Satagram"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: state)
    arguments.openArchive = { [weak controller] in
        controller?.push(satagramDeletedMessagesController(context: context))
    }
    return controller
}

private enum SatagramDeletedEntry: ItemListNodeEntry {
    case text(Int32, String)

    var section: ItemListSectionId { return 0 }
    var stableId: Int32 {
        switch self { case let .text(id, _): return id }
    }
    static func < (lhs: SatagramDeletedEntry, rhs: SatagramDeletedEntry) -> Bool { return lhs.stableId < rhs.stableId }
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .text(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func satagramDeletedMessagesController(context: AccountContext) -> ViewController {
    let messages = SatagramDeletedArchive.messages(accountPeerId: context.account.peerId).reversed()
    let state = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let russian = presentationData.strings.baseLanguageCode == "ru"
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        var entries: [SatagramDeletedEntry] = []
        for (index, message) in messages.enumerated() {
            let date = formatter.string(from: Date(timeIntervalSince1970: Double(message.timestamp)))
            let chatTitle = message.chatTitle.flatMap { $0.isEmpty ? nil : $0 } ?? String(message.peerId)
            entries.append(.text(Int32(index), "\(date) · \(chatTitle)\n\(message.text)"))
        }
        if entries.isEmpty {
            entries.append(.text(0, russian ? "Пока нет сохранённых сообщений." : "No saved messages yet."))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(russian ? "Удалённые сообщения" : "Deleted messages"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, ()))
    }
    return ItemListController(context: context, state: state)
}
