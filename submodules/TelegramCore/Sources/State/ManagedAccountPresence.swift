import Foundation
internal import TelegramApi
import Postbox
import SwiftSignalKit
import MtProtoKit

private typealias SignalKitTimer = SwiftSignalKit.Timer


private final class AccountPresenceManagerImpl {
    private let queue: Queue
    private let network: Network
    let isPerformingUpdate = ValuePromise<Bool>(false, ignoreRepeated: true)
    
    private var shouldKeepOnlinePresenceDisposable: Disposable?
    private let currentRequestDisposable = MetaDisposable()
    private var onlineTimer: SignalKitTimer?
    
    private var wasOnline: Bool = false
    private var wantsOnline: Bool = false
    private var ghostModeObserver: NSObjectProtocol?
    
    init(queue: Queue, shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        self.queue = queue
        self.network = network
        
        self.shouldKeepOnlinePresenceDisposable = (shouldKeepOnlinePresence
        |> distinctUntilChanged
        |> deliverOn(self.queue)).start(next: { [weak self] value in
            guard let `self` = self else {
                return
            }
            self.wantsOnline = value
            self.applyPresence()
        })
        self.ghostModeObserver = NotificationCenter.default.addObserver(forName: Notification.Name("SatagramGhostModeChanged"), object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                if UserDefaults.standard.bool(forKey: "SatagramGhostMode") {
                    self.wasOnline = false
                    self.updatePresence(false)
                } else {
                    self.applyPresence()
                }
            }
        }
        if UserDefaults.standard.bool(forKey: "SatagramGhostMode") {
            self.updatePresence(false)
        }
    }
    
    deinit {
        assert(self.queue.isCurrent())
        if let observer = self.ghostModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        self.shouldKeepOnlinePresenceDisposable?.dispose()
        self.currentRequestDisposable.dispose()
        self.onlineTimer?.invalidate()
    }
    
    private func applyPresence() {
        let isOnline = self.wantsOnline && !UserDefaults.standard.bool(forKey: "SatagramGhostMode")
        if self.wasOnline != isOnline {
            self.wasOnline = isOnline
            self.updatePresence(isOnline)
        }
    }

    private func updatePresence(_ isOnline: Bool) {
        let request: Signal<Api.Bool, MTRpcError>
        if isOnline {
            let timer = SignalKitTimer(timeout: 30.0, repeat: false, completion: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updatePresence(true)
            }, queue: self.queue)
            self.onlineTimer = timer
            timer.start()
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolFalse))
        } else {
            self.onlineTimer?.invalidate()
            self.onlineTimer = nil
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
        }
        self.isPerformingUpdate.set(true)
        self.currentRequestDisposable.set((request
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .single(.boolFalse)
        }
        |> deliverOn(self.queue)).start(completed: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isPerformingUpdate.set(false)
        }))
    }
}

final class AccountPresenceManager {
    private let queue = Queue()
    private let impl: QueueLocalObject<AccountPresenceManagerImpl>
    
    init(shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: self.queue, generate: {
            return AccountPresenceManagerImpl(queue: queue, shouldKeepOnlinePresence: shouldKeepOnlinePresence, network: network)
        })
    }
    
    func isPerformingUpdate() -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.isPerformingUpdate.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
}
